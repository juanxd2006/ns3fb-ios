# Entradas interiores: por qué se quedan pegadas acciones sueltas

Documento de la rama `fix/entradas-interiores`. Explica un fallo **sistémico**
encontrado el 2026-10-28 y el parche que lo corrige.

## 1. El síntoma

Modo historia, después de arreglar los callbacks de evento: el juego va bien,
el personaje se mueve, la música sigue, el motor dibuja a 30 fps… y **la A no
hace nada** delante de un punto de interacción. El personaje se anima en idle,
el juego responde al mando, pero la acción no se dispara.

En el log no hay ni un `NS3FB-TRAP`: no faltaba ningún entrypoint. El fallo era
otro, y no dejaba rastro.

## 2. La causa

El invitado llama **por puntero a direcciones que caen DENTRO de una función**,
no en su inicio. Son colas compartidas (lógica final + epílogo) que el compilador
original reutiliza para varias funciones. Ejemplo real, `0x825A73F8`:

```asm
0x825A73E0  std   r31, -0x10(r1)     ; prologo de la funcion 0x825A73D8
0x825A73E4  stwu  r1, -0x60(r1)
0x825A73E8  lwz   r11, 0(r3)
0x825A73EC  mr    r31, r3            ; r31 = this
0x825A73F0  lwz   r11, 0x42c(r11)
0x825A73F4  mtctr r11
0x825A73F8  bctrl                    ; <-- la direccion que llamaba el juego
0x825A73FC  cmplwi r3, 0
0x825A7400  beq   -> return 0
0x825A7408  lwz   r3, 0x7bc(r31)     ; r31 aqui ya no vale
0x825A740C  bl    sub_82573040
0x825A7420  addi  r1, r1, 0x60       ; desapila un frame que nunca apilo
0x825A7424  lwz   r12, -8(r1)        ; direccion de retorno de OTRA pila
0x825A742C  ld    r31, -0x10(r1)
0x825A7430  blr
```

Al sembrarla en `ci/entrypoint_seeds.txt`, el codegen compilaba **el cuerpo desde
el `bctrl`**: sin `mr r31, r3`, sin frame. Resultado: lee un `this` basura en
`0x7bc(r31)`, la comprobación devuelve 0 y, al volver, restaura `r1` y `lr` de
una pila ajena. No revienta: **devuelve un valor arbitrario y corrompe estado**.
La acción se rechaza y el juego sigue tan feliz. Es exactamente «la A no hace
nada».

El otro caso de la sesión es peor: `0x821E82C8` es el punto medio del
**constructor** de `ccAdvMobObj` (`0x821E82A8`), justo después de `mr r31, r3` y
`lis r11, ...`. Compilado desde ahí, escribe el puntero de vtable en
`0(r31)` con `r31` basura: **escritura en memoria aleatoria** del invitado.

## 3. La auditoría

Se revisaron las 193 semillas que había antes de este cambio. Prueba: una
dirección es inicio de función si la instrucción **anterior** es un terminador
(`blr`, `b`, `bctr`, relleno). Resultado:

| Categoría | N |
|---|---|
| Thunks de vtable de 16 bytes (legítimos, autónomos) | 145 |
| Inicios de función reales | 3 |
| `blr` suelto (equivale a no-op, inocuo) | 1 |
| **Entradas interiores** | **45** |
| — de ellas, **peligrosas** (tocan `r1` o registros callee-saved que no han puesto) | **40** |
| — de ellas, hojas sin marco de pila (funcionan tal cual, se dejan como están) | 5 |

Las 5 inocuas: `0x827D92A8`, `0x828401D8`, `0x828401A8`, `0x828401C0`, `0x8276EB48`.

Es decir: **40 call sites llevan desde el 2026-10-22 ejecutando cuerpos que no
son funciones completas**, cada uno con su corrupción silenciosa. No es un bug;
es una clase de bug.

## 4. El arreglo: dos niveles

`ci/rexglue-alias-interior.patch` actúa en `src/system/function_dispatcher.cpp` con
dos mecanismos, del más determinista al más general:

### Nivel 1 — tabla curada

Mapa de las 42 entradas ya identificadas a la función que las contiene. Se aplica
en `ResolveIndirectFunction`, **antes** de buscar en la tabla de funciones, así que
el cuerpo mal compilado no se ejecuta nunca. Coste cero, comportamiento fijo.

```
NS3FB-ALIAS 0x825A73F8 -> 0x825A73D8 (entrada interior: se ejecuta la funcion completa)
```

### Nivel 2 — detección en runtime

Cuando una llamada **cae en el trap** (nadie la resolvió), antes de devolver el
no-op se busca hacia atrás el inicio de la función que contiene la dirección y se
ejecuta entera. El escaneo exige tres cosas para no redirigir a tontas:

1. patrón de prólogo (`mflr r12` + `stw r12,-8(r1)`, o `stwu r1,-N(r1)`),
2. que la instrucción anterior sea un terminador (`blr`/`b`/`bctr`/relleno),
3. que la función encontrada **contenga** la dirección (su primer `blr` no puede
   quedar antes).

```
NS3FB-ALIAS-AUTO 0x825A7AB8 -> 0x825A7A88 (contenida en una funcion: se ejecuta entera)
```

Este nivel es el que hace innecesario jugar para descubrir direcciones nuevas: se
aplica a cualquier dirección que el juego genere en runtime, hoy y en el futuro.

**A/B sin recompilar:** `Documents/alias_off.txt` desactiva los dos niveles y
vuelve al comportamiento anterior.

Y `ci/entrypoint_seeds.txt` gana **32 semillas**: los inicios de las funciones de
la tabla curada. Sin ellas, la redirección del nivel 1 caería en el trap.

## 5. La tabla completa (42 entradas)

| Entrada | Función que la contiene | Desfase | Registros que usa sin poner |
|---|---|---|---|
| `0x821E82C8` | `0x821E82A8` | +0x20 | esta sesion: constructor de ccAdvMobObj |
| `0x82261C68` | `0x82261BA0` | +0xC8 | r1,r29,r31 |
| `0x82261C78` | `0x82261BA0` | +0xD8 | r1,r29,r31 |
| `0x82261C98` | `0x82261BA0` | +0xF8 | r1,r29,r31 |
| `0x82261CA8` | `0x82261BA0` | +0x108 | r1 |
| `0x82264BD0` | `0x82264BB8` | +0x18 | r1,r31 |
| `0x82264BE0` | `0x82264BB8` | +0x28 | r1,r31 |
| `0x8226C750` | `0x8226C748` | +0x8 | r1 |
| `0x8226C790` | `0x8226C748` | +0x48 | r1 |
| `0x82272648` | `0x822725F0` | +0x58 | r1,r31 |
| `0x82272CF8` | `0x82272CD0` | +0x28 | r1,r30,r31 |
| `0x82296CB0` | `0x82296C68` | +0x48 | r1,r30,r31 |
| `0x8239B2D8` | `0x8239B2A8` | +0x30 | r1 |
| `0x82526C88` | `0x82526C10` | +0x78 | r1,r31 |
| `0x82575E68` | `0x82575D68` | +0x100 | r1,r29,r30,r31 |
| `0x82575F78` | `0x82575D68` | +0x210 | r1,r28,r29,r30,r31 |
| `0x825A7258` | `0x825A7218` | +0x40 | r1,r31 |
| `0x825A7278` | `0x825A7218` | +0x60 | r1,r31 |
| `0x825A72F8` | `0x825A72E8` | +0x10 | r1 |
| `0x825A7308` | `0x825A72E8` | +0x20 | r1 |
| `0x825A7348` | `0x825A72E8` | +0x60 | r1 |
| `0x825A73A8` | `0x825A7380` | +0x28 | r1,r31 |
| `0x825A73F8` | `0x825A73D8` | +0x20 | esta sesion: comprobacion de accion (vtbl+0x42C) |
| `0x825E3278` | `0x825E30D0` | +0x1A8 | r1,r28,r29,r30,r31 |
| `0x825EBAC8` | `0x825EB770` | +0x358 | r1,r28,r31 |
| `0x826057F8` | `0x82605478` | +0x380 | r1,r28,r30 |
| `0x8262C590` | `0x8262C528` | +0x68 | r1,r31 |
| `0x8269D310` | `0x8269D1E0` | +0x130 | r1 |
| `0x8269ECF8` | `0x8269E8F0` | +0x408 | r1,r28,r31 |
| `0x826E4C20` | `0x826E4BE0` | +0x40 | r1 |
| `0x826EC2E8` | `0x826EC220` | +0xC8 | r1,r31 |
| `0x82723138` | `0x82723078` | +0xC0 | r1,r31 |
| `0x82768360` | `0x82768268` | +0xF8 | r1,r30 |
| `0x8276D788` | `0x8276CA78` | +0xD10 | r1 |
| `0x8276F2A0` | `0x8276F268` | +0x38 | r1 |
| `0x827D9BA8` | `0x827D9B18` | +0x90 | r1,r29,r30,r31 |
| `0x827DD430` | `0x827DD370` | +0xC0 | r1 |
| `0x828401F0` | `0x828401E8` | +0x8 | r1 |
| `0x82840208` | `0x828401E8` | +0x20 | r1 |
| `0x828628F8` | `0x828628B8` | +0x40 | r1,r30,r31 |
| `0x82868BA0` | `0x82868B78` | +0x28 | r1,r31 |
| `0x828DE618` | `0x828DE598` | +0x80 | r1,r31 |

Las 5 interiores **no** redirigidas por ser hojas sin marco de pila:
`0x827D92A8`, `0x828401D8`, `0x828401A8`, `0x828401C0`, `0x8276EB48`.

## 6. Riesgo asumido

Si alguna de estas direcciones fuera un **punto de reanudación de corrutina**
(CC2 usa fibras para los eventos de guion) donde el prólogo *no* debe volver a
ejecutarse, la redirección sería incorrecta. Contra eso:

- `Documents/alias_off.txt` revierte el comportamiento sin recompilar.
- El log dice exactamente qué entrada se usó, así que un síntoma nuevo se
  correlaciona en un minuto.
- Ejecutar el cuerpo desde el medio **tampoco funcionaba**: devolvía basura.
  No se pierde nada que estuviera bien.

## 7. Verificación en el dispositivo

1. Punto de interacción del modo historia → **la A debe responder**.
2. En el log deben aparecer líneas `NS3FB-ALIAS` (y **ninguna** `NS3FB-TRAP`).
3. Si algo se rompe, duplicar `alias_off.txt` en `Documents/` y comparar.

## 8. ¿Se puede hacer sin entrar al juego?

Sí, y la respuesta corta es que **la cosecha manual ya no hace falta**. Tres números:

### Lo que sí se extrae del `.xex`

`tools/xex/harvest_interior.py` (nuevo) recorre la imagen, busca rachas de punteros
a `.text` en las tablas de datos y clasifica cada uno. Resultado en este ejecutable:

| Clasificación | N |
|---|---|
| Inicios de función | 13.857 |
| Thunks de vtable | 9 |
| **Entradas interiores con función contenedora** | **5.373** |

Cinco mil trescientas setenta y tres. **Es imposible validarlas jugando**, y por eso
la solución no puede ser una tabla a mano: tiene que resolverlo el runtime (nivel 2).

### Lo que NO se extrae del `.xex`

La familia de callbacks `0x825A7xxx` — la que costó semanas de sesiones — **no está
en la imagen como datos**. Comprobado: de 27 direcciones que el dispositivo reveló a
lo largo del proyecto, el escaneo estático encuentra **1**. Las demás las construye
el juego en runtime, así que ningún escaneo del `.xex` las va a ver nunca. Tampoco
hace falta: el detector las resuelve cuando aparecen.

### Validación del detector

Probado contra el `.text` real del ejecutable, con los 8 casos que el dispositivo
había descubierto y 5 inicios de función que no deben moverse:

```
OK  0x825A73F8 -> 0x825A73D8   comprobacion de accion (la A)
OK  0x821E82C8 -> 0x821E82A8   constructor de ccAdvMobObj
OK  0x825A7378 -> 0x825A72E8   blr final
OK  0x825A73A8 -> 0x825A7380   sesion larga 02:42
OK  0x82272CF8 -> 0x82272CD0   sesion larga 02:40
OK  0x8262C590 -> 0x8262C528   trampolin de retorno
OK  0x825A7308 -> 0x825A72E8   evento de combate
OK  0x82264BE0 -> 0x82264BB8   inicio del jutsu definitivo

inicios de funcion: 0x825A73D8, 0x821E82A8, 0x825A72E8, 0x821B0000, 0x825A7438
  -> todos sin tocar
```

8/8 aciertos y 5/5 sin falsos positivos. Y el código compila con `-Wall -Wextra`
con los mismos tipos que el SDK (`PPCFunc` como tipo función).

### El flujo nuevo

```
python3 tools/xex/unxex.py ci/game/default.xex /tmp/image.bin
python3 tools/xex/harvest_interior.py /tmp/image.bin      # auditoria, sin dispositivo
python3 tools/xex/harvest_interior.py /tmp/image.bin --cpp  # tabla para el parche
```

Para las direcciones nuevas: **no hay que hacer nada**. Sale `NS3FB-ALIAS-AUTO` en
el log y sigue. Solo se mira el log si algo se comporta raro.
