# NS3FB iOS — v0.2.0

Segunda entrega pública. **Solo correcciones**: no hay funciones nuevas, no cambia
el rendimiento ni la resolución. Objetivo de la entrega: que el modo historia se
pueda jugar de verdad.

Base: iPhone 11 (A13), iOS 27, 960×540, ~30 fps estables.

---

## 🐛 Corregido

### 1. Modo historia: el personaje no se movía

El juego llamaba por puntero a tres funciones que el codegen no conocía. Se
ejecutaban como **no-op**, así que la comprobación de acción devolvía «no» y el
personaje se quedaba clavado con el motor funcionando a 30 fps.

| Dirección | Qué es |
|---|---|
| `0x821E82C8` | constructor de `ccAdvMobObj` (objetos del modo aventura) |
| `0x825A73F8` | comprobación de si la acción se puede ejecutar |
| `0x825A7378` | retorno de otra de esas comprobaciones |

Se sembraron en `ci/entrypoint_seeds.txt`, junto con **19 thunks de vtable** de
16 bytes que tampoco estaban declarados. Resultado: el personaje vuelve a
moverse y el juego deja de quedarse parado en el modo historia.

### 2. Crash al entrar en ciertas pantallas del modo historia

Una build intermedia intentaba redirigir esas llamadas a la función que «parecía»
contenerlas. Eligió una función que no tenía nada que ver y el juego murió con
`Unhandled guest access violation: read of guest 0x00000004`.

Se **desactivó por completo** ese detector. Ahora ninguna ruta del port puede
redirigir una llamada a una función equivocada: si algo no se resuelve, se
ejecuta como no-op y el juego sigue, en vez de morir.

### 3. Cuatro ramas condicionales sin resolver en el codegen

El propio codegen las listaba al recompilar:

```
Unresolved conditional branch to 0x82261E40, 0x82296DF0, 0x82353E10, 0x827D5CBC
```

Las cuatro eran código interior de funciones que el analizador no había
descubierto. Se sembró el **inicio real** de cada una:

| Destino | Función sembrada |
|---|---|
| `0x82261E40` | `0x82261BA0` |
| `0x82296DF0` | `0x82296C68` |
| `0x82353E10` | `0x82353D90` |
| `0x827D5CBC` | `0x827D5BD8` |

### 4. `setjmp` / `longjmp` declarados en el manifiesto

El proyecto no los declaraba, y sin ellos el codegen compila `longjmp` como una
llamada normal que retorna: el epílogo ya lo omitió el compilador, así que `r1` y
los registros callee-saved quedan corruptos.

Se identificó la pareja del CRT por su firma (guardan y restauran los no
volátiles con **el mismo reparto de offsets**) y `scripts/02b-set-jumptargets.py`
las escribe en cada build:

```toml
[entrypoint]
setjmp_address  = 0x828A7F20
longjmp_address = 0x828A81F0
```

> Nota honesta: esto elimina una clase de corrupción, pero **no** arregla el bug
> del combo que se describe abajo. Se verificó con datos.

---

## ⚠️ Conocido: el combo de mob battle no avanza

En las **mob battles** (varias oleadas de enemigos) aparece en pantalla un botón
—`A`, `B`…— que hay que pulsar para encadenar el ataque especial. En este port el
prompt **se queda ahí y no avanza**.

Lo que ya está descartado, con mediciones del propio juego:

| Comprobación | Resultado |
|---|---|
| ¿Llega la pulsación al juego? | **Sí**: 260 pulsaciones de `B` vistas por el invitado |
| ¿La lógica corre más rápido que la imagen? | **No**: 30,0 frames/s de lógica y 30,0 de presentación |
| ¿Se pierden eventos de botón? | El juego sondea estado; no usa eventos, y el estado llega |
| ¿Es un entrypoint que falta? | Los traps son fragmentos de epílogo, no funciones |

Síntoma asociado: el logro de capítulo se dispara **varias veces seguidas**, lo
que apunta a una secuencia que se reejecuta en bucle. Se sigue investigando.

---

## 🔧 Diagnóstico que se queda en el build

Útil para reportar bugs, y **no molesta**: 2–3 líneas por segundo.

```
NS3FB-BUILD compilado <fecha> <hora>        qué binario generó el log
NS3FB-INPUT keydown vk=0x5801 flags=0x0001  pulsaciones que llegan al invitado
NS3FB-INPUT-FRAMES polls=30.0/s ...         tasa de sondeo del mando
NS3FB-GUEST-FRAMES swaps=30.0/s ...         frames que pide el juego
```

Para silenciarlo: crear `Documents/input_trace_off.txt` y reabrir el juego.

---

## 📦 Instalación

Igual que siempre: `.ipa` **sin firmar**, se firma con SideStore, AltStore,
Sideloadly o certificado propio. Requisitos y pasos en el
[README](../README.es.md). Necesitas tu propio `default.xex` NTSC-U
(SHA-1 `f7ad65e2…55e9f`); si el hash no coincide, el port no arranca.

**Cambiar de versión requiere desinstalar antes de reinstalar** si el icono o el
bundle ID cambian de caché en iOS.

---

## Estado general

| Parte | Estado |
|---|---|
| Arranque, menús, selección de personaje | ✅ |
| VS Battle, práctica, HUD, partículas, audio | ✅ |
| Modo historia (movimiento, eventos, capítulos) | ✅ |
| **Combo de mob battle** | ⚠️ pendiente |
| 1280×720 | ❌ ~18 fps — techo del SDK |
| 60 fps | ❌ el juego está bloqueado a 30 por diseño |

Historial técnico completo de estos arreglos en
[`docs/INTERIOR_ENTRIES.md`](INTERIOR_ENTRIES.md) y
[`docs/INPUT_TRACE.md`](INPUT_TRACE.md).
