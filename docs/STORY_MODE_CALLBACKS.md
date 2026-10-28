# Modo historia: el personaje no se mueve — diagnóstico y arreglo

Sesión analizada: `2026-10-27 23:12:34 → 23:17:52` (5m18s), iPhone A13, iOS 27.0,
960×540, `rt_path=fbo`, `msaa=0`, 29,6 fps estables.

## 1. Qué dice el log (y qué no)

El log **no tiene ni un solo error**. Los contadores de render no paran en toda la
sesión (`NS3FB-PASS` llega a `ends=458400` en la última línea), el audio envía, y
los logros van cayendo:

| Hora | Evento |
|---|---|
| 23:13:18 | logro id=1 |
| 23:13:22 | **NS3FB-TRAP `0x821E82C8`** |
| 23:13:32 | logro id=1 |
| 23:13:48 | mando Xbox conectado (a mitad de sesión) |
| 23:15:12 | logro id=43 |
| 23:15:53 | logro id=1 |
| 23:17:05 | se crean pipelines nuevos (cambio de escena/evento) |
| 23:17:06 | **NS3FB-TRAP `0x825A73F8`** |
| 23:17:36 | **NS3FB-TRAP `0x825A7378`** |
| 23:17:40 | logro id=47 |

Dos conclusiones directas:

- **No es el mando ni el input.** Los logros siguen saltando hasta 4 segundos
  *después* del último trap: el juego estaba recibiendo entradas y progresando.
- **No es un cuelgue del motor.** 29,6 fps, GPU 27,37 ms, frame interval 33,78 ms:
  el invitado sigue corriendo. Lo que no ocurre es la **lógica del evento**.

## 2. La causa: tres funciones del invitado ejecutadas como no-op

`NS3FB-TRAP … unregistered guest function, continuing as no-op` significa que el
juego llamó por puntero a una dirección que el codegen no conoce. El parche
`ci/rexglue-trap-continue.patch` no aborta: registra la dirección **una sola vez**
(`trap_reported` es un `unordered_set`) y sigue como stub vacío.

Ese detalle importa: **el log no dice cuántas veces se llamó**. Puede ser un
callback de un solo uso o una ruta que se ejecuta 30 veces por segundo. La
dirección solo se imprime la primera vez.

Las tres direcciones de esta sesión, verificadas contra el `default.xex` del repo
(SHA-1 `f7ad65e2…55e9f`, el correcto):

| Dirección | Qué es realmente |
|---|---|
| `0x821E82C8` | Método virtual de **`ccAdvMobObj`** (modo aventura). Su única referencia estática está en la tabla de `.rdata` de `0x820053E8`, junto a las cadenas `ccAdvMobObjD…`. |
| `0x825A73F8` | **Entrada interior** de `sub_825A73E0` (+0x18): es el `bctrl` que despacha el slot virtual `0x42C`, y luego comprueba el resultado y llama a `sub_82573040(this+0x7BC, 2)`. |
| `0x825A7378` | **Entrada interior**: el `blr` final de otra función (8 bytes `blr` + relleno). |

Y el contexto temporal encaja: a las 23:17:05 se compilan pipelines **nuevas**
(`VS 4666C5A9092B03DD, PS 7ABDFEFBCADB4BF9`), un segundo después salta el trap de
`0x825A73F8`, y 34 segundos después el de `0x825A7378`. Eso es la entrada a una
escena/evento de historia cuya llamada de control nunca se ejecutó: el escenario
se carga y se dibuja (de ahí la captura: sala de piedra, personaje en idle, HUD
completo), pero la lógica que mueve al personaje se quedó en un stub vacío.

**No es un bug nuevo.** Es el mismo patrón ya documentado en `ci/entrypoint_seeds.txt`
el 2026-10-24 02:01: *«modo historia: al pulsar A se queda "corriendo" (esperando
callback)»*, que se resolvió sembrando `0x825A7638`, `0x825A7808`, etc. La familia
`0x825A7xxx` son **callbacks de evento que la tabla construye en runtime**, así que
no aparecen en `.pdata` ni como datos estáticos y se descubren de uno en uno.

## 3. Arreglo: 22 semillas nuevas, en un solo build

Dos archivos listos para dejar caer en el repo:

| Archivo | Destino |
|---|---|
| `entrypoint_seeds.txt` | `ci/entrypoint_seeds.txt` (reemplaza) |
| `rexglue-trap-continue.patch` | `ci/rexglue-trap-continue.patch` (reemplaza) |
| `seed_missing_thunks.py` | `tools/xex/seed_missing_thunks.py` (nuevo) |

### 3.1 Las 3 direcciones de esta sesión

`0x821E82C8`, `0x825A73F8`, `0x825A7378`, con el comentario de qué es cada una y a
qué hora apareció, siguiendo el estilo del archivo.

### 3.2 Y los 19 thunks que faltaban de toda la familia

`tools/xex/find_callback_thunks.py` solo recorría `0x825A7000-0x825A8000`.
Recorriendo **todo** `.text` salen **164 thunks**; 145 ya estaban sembrados y
**faltaban 19** (`0x82261E68`, `0x82264DD0`, `0x82296EA0`, `0x822EB130`,
`0x82353E38`, `0x825F3278`, `0x8269D648`, `0x826ACB68`…).

Sembrarlos ahora evita repetir el ciclo «juego 3 minutos → trap nuevo → build de
40 minutos» cada vez que se entre en otra pantalla que use uno de ellos. Cada uno
lleva anotado el slot virtual que despacha (`# slot 0x2C`, `# slot 0x6CC`…).

### 3.3 Contador de llamadas en el trap (opcional pero recomendado)

El parche pasa de `unordered_set` (una línea por dirección) a
`unordered_map<dirección, llamadas>` y escribe el log la primera vez y luego una
de cada 600:

```
NS3FB-TRAP 0x825A73F8 unregistered guest function, no-op (calls=600)
NS3FB-TRAP 0x825A73F8 unregistered guest function, no-op (calls=1200)
```

Con la marca de tiempo de cada línea se sabe de un vistazo si el callback es de un
solo uso o si se ejecuta en cada frame. Es la información que hoy falta para
cerrar el diagnóstico sin adivinar. Verificado: aplica limpio sobre el SDK.

## 4. Cómo aplicarlo

```bash
cd ns3fb-ios
cp /ruta/entrypoint_seeds.txt            ci/entrypoint_seeds.txt
cp /ruta/rexglue-trap-continue.patch     ci/rexglue-trap-continue.patch
cp /ruta/seed_missing_thunks.py          tools/xex/seed_missing_thunks.py

# comprobación rápida: deben salir 215 semillas, 0 inválidas, 0 duplicadas
grep -c '^0x' ci/entrypoint_seeds.txt

./scripts/01-codegen.sh     # siembra + recompila (~20-30 min)
./scripts/03-build-app.sh
./scripts/make-ipa.sh
```

Y para que no vuelva a pasar, antes de cada codegen:

```bash
python3 tools/xex/seed_missing_thunks.py ci/game/default.xex --dry-run
```

Si dice `faltan: 0`, la familia está cubierta entera.

## 5. Cómo verificar que el arreglo es el correcto

1. Entra al mismo punto del modo historia.
2. En el log **no debe aparecer** ninguna de las tres direcciones.
3. Si el personaje **sí** se mueve → cerrado.
4. Si **no** se mueve y aparecen direcciones nuevas → el sistema va sacando
   callbacks uno por uno; con el contador de 3.3 verás si son de un solo uso o
   de cada frame. Pásame el log nuevo y seguimos.

## 6. Si sigue sin moverse: dos comprobaciones que no cuestan un build

- **Probar con los controles táctiles** en vez del mando. Si con tacto tampoco se
  mueve, el fallo está en el invitado (esta vía); si con tacto sí se mueve, el
  problema es del camino del mando conectado a mitad de sesión, y es otro bug.
- **Crear `Documents/keep_pass_open.txt`** no tiene nada que ver con esto, pero
  sí confirma que los marcadores de `Documents/` se están leyendo en este build:
  con el marcador puesto, `NS3FB-PASS … kept_open=` debe dejar de ser 0. En este
  log `kept_open=0`, o sea que el marcador no estaba puesto (normal, no afecta a
  la lógica del personaje).
