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

## 4. El arreglo (corregido tras un fallo real)

La primera version de este parche tenia **tabla curada + 32 semillas nuevas**. El
build de esa version moria a los 4 segundos:

```
[critical] [FATAL] Unresolved branch from 0x825EB99C to 0x825EB758
```

### Por que fallo

Dos errores, el mismo de fondo: **creer que se puede saber donde acaba una funcion
sin la tabla de excepciones**.

1. **Sembrar `0x825EB770` partio una funcion.** Esa direccion tiene pinta de inicio
   de funcion (mflr r12 / stw r12,-8(r1) / stwu r1,-N(r1)) y le precede un `blr`,
   pero estaba **dentro** de una funcion mas grande. Al declararla inicio, la
   funcion original quedo truncada y un salto interno suyo (`0x825EB99C` ->
   `0x825EB758`) paso a cruzar una frontera que antes no existia: irresoluble, y
   el juego muere.
2. **La tabla curada tenia 16 de 42 entradas mal.** Se calcularon buscando "el
   primer `blr` despues del candidato" para saber donde acaba la funcion. **Ese
   criterio es falso: MSVC fusiona epilogos**, asi que un `blr` puede aparecer en
   medio de una funcion. Ejemplo: `0x825EBAC8` se mapeo a `0x825EB770`, cuya
   funcion termina en `0x825EB7B8`, 0x310 bytes antes de la entrada.

### Como queda

**Solo deteccion en runtime.** Cuando una llamada cae en el trap, se busca hacia
atras el inicio de la funcion que la contiene y se ejecuta entera, con tres
controles: prologo valido, terminador antes, y que la funcion contenga la
direccion. Si algo no cuadra, no-op (como antes).

Por que es seguro, y por que se quitaron las semillas:

- **No crea fronteras de funcion.** Es lo que rompio el build anterior: sembrar
  parte funciones. Detectar en el momento de la llamada no toca el codegen.
- **No necesita saber donde acaba la funcion** para nada que pueda romper el
  arranque: peor caso, no encuentra candidato y devuelve no-op.
- Y como consecuencia: **las entradas interiores no deben estar sembradas**. Si
  `0x825A73F8` esta en la tabla, la llamada resuelve al cuerpo mal compilado y el
  detector no llega a ejecutarse nunca. Por eso se quitaron y se sembraron los
  inicios reales (`0x825A73D8`, `0x821E82A8`), verificados como autocontenidos
  (acaban en `blr` y les sigue relleno).

```
NS3FB-ALIAS-AUTO 0x825A73F8 -> 0x825A73D8 (contenida en una funcion: se ejecuta entera)
```

**A/B sin recompilar:** `Documents/alias_off.txt` desactiva el detector.


## 4b. v3 — el detector de la v2 fallaba EN SILENCIO

Log del 2026-10-28, build de esta rama (`01:01:47 → 01:07:41`, 5m54s):

```
01:02:43  NS3FB-TRAP 0x821E82C8 ... (calls=1)
01:06:58  NS3FB-TRAP 0x825A73F8 ... (calls=1)
01:07:22  NS3FB-TRAP 0x825A73F8 ... (calls=600)     <-- 25 llamadas/s, cada frame
01:07:38  NS3FB-TRAP 0x825A7378 ... (calls=1)
```

**Cero `NS3FB-ALIAS-AUTO`.** Las semillas estaban bien (las tres interiores vuelven a
saltar como trap, o sea que ya no estan en la tabla), y el motor siguio dibujando
(`NS3FB-PASS ends=511200` en la ultima linea). Pero la redireccion no ocurrio ni una
vez, y el usuario lo vio como "se volvio a quedar parado".

### Por que

Dos defectos del detector de la v2, los dos silenciosos:

1. **El criterio de contencion era falso.** Se exigia que "el primer `blr` despues del
   candidato no quede antes de la direccion". Ese criterio asume que una funcion tiene
   un solo `blr` final, y **MSVC fusiona epilogos**: puede haber un `blr` en medio. Si
   lo hay antes de la direccion, se descarta el candidato bueno y se devuelve 0.
2. **No se comprobaba lo unico que importa.** Un candidato sirve para algo solo si
   **esta en la tabla de funciones compiladas**. La v2 pedia el candidato por
   `GetFunction()` y, si devolvia null, se rendia sin decir nada. Y es lo mas probable
   aqui: si la direccion cae dentro de una funcion que el codegen ya conocia por
   `.pdata`, sembrarla no crea una funcion nueva — el `GetFunction()` del inicio
   sembrado devuelve null.

### Como queda (v3)

- **Criterio unico y comprobable**: se recorre hacia atras y se devuelve el primer
  candidato con pinta de prologo y terminador delante **que este compilado**
  (`GetFunction` no nulo). Si no lo esta, se sigue buscando en vez de rendirse.
- **Ya no se usa "primer blr" para nada**, asi que los epilogos fusionados dejan de
  importar.
- **Si no redirige, lo dice**: `NS3FB-ALIAS-MISS <addr> (<n> candidatas, ninguna
  compilada) base=ok/null disp=ok/null`.

Verificado contra el `.text` real: las tres direcciones resuelven **a la primera
candidata** (`probes=1`) a `0x825A73D8`, `0x821E82A8` y `0x825A72E8`.

Con esto, el proximo log es concluyente por si mismo: o sale `NS3FB-ALIAS-AUTO` con
la funcion elegida, o sale `NS3FB-ALIAS-MISS` diciendo cuantas candidatas se probaron
y si llegaron `base` y `dispatcher`.

## 5. Las direcciones conocidas

Ya no hay tabla: el detector las resuelve. Las verificadas contra el `.text` real
son las de la §8. Las que la tabla curada tenia mal (`0x82261C68`, `0x82575E68`,
`0x825E3278`, `0x825EBAC8`, `0x826057F8`, `0x8269D310`, `0x8269ECF8`, `0x82768360`,
`0x8276D788`, `0x827D9BA8`, `0x827DD430`, `0x828DE618`, y las cuatro `0x82261Cxx`)
se dejan al detector, que las calcula con la comprobacion de contencion.

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
