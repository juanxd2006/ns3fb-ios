# Banco de medición A/B

Cómo saber cuál de las palancas de rendimiento funciona **antes** de escribir
nada nuevo, y cuánto gana cada una.

Los números que ya tenemos (iPhone 11 / A13, `fbo`, escena de selección) dicen
dónde está el coste:

| Bucket | ms | % |
|---|---|---|
| Compute (`resolve_*_cs`) | 30,34 | 44 % |
| Fragment | 25,54 | 37 % |
| Blit | 5,51 | 8 % |
| Vertex | 3,14 | 5 % |
| **Total** | **63,07** | |

Este banco existe para responder cuatro preguntas concretas, con el mismo
escenario y midiendo los mismos cuatro buckets:

1. ¿Cuánto de ese `Compute` es el resolve de 4x MSAA?
2. ¿Cuánto de ese `Fragment` es resolución interna?
3. ¿Cuánto ahorra mantener el render pass abierto?
4. ¿La ruta `fsi` reparte mejor el trabajo en Metal?

## Uso

```bash
./scripts/perf-matrix.sh init     # genera perf/matrix/<caso>/
./scripts/perf-matrix.sh list     # qué mide cada caso
./scripts/perf-matrix.sh pack     # un .zip por caso
# ... medir en el iPhone (ver protocolo en perf/matrix/README.md) ...
./scripts/perf-matrix.sh report   # perf/results/ -> summary.md + summary.csv
```

El parser se puede usar suelto, y se autoverifica:

```bash
python3 scripts/perf_parse.py --selftest
python3 scripts/perf_parse.py perf/results/01-msaa2
```

## Los casos

| Caso | `msaa_override` | Resolución | Ruta | keep pass open |
|---|---|---|---|---|
| `00-baseline` | 0 (invitado, 4x) | 1280×720 | fbo | no |
| `01-msaa2` | 2 | 1280×720 | fbo | no |
| `02-msaa1` | 1 | 1280×720 | fbo | no |
| `03-540p` | 0 | 960×540 | fbo | no |
| `04-msaa2-540p` | 2 | 960×540 | fbo | no |
| `05-msaa1-540p` | 1 | 960×540 | fbo | no |
| `06-kpo` | 0 | 1280×720 | fbo | sí |
| `07-kpo-msaa2` | 2 | 1280×720 | fbo | sí |
| `08-fsi` | 0 | 1280×720 | fsi | no |

Cada caso aísla **una** variable respecto de `00-baseline`, salvo los que se
declaran como combinación.

## El parche de MSAA

`ci/rexglue-msaa-override.patch` añade el cvar `msaa_override` (0/1/2/4) y lo
aplica en la **única** lectura de `RB_SURFACE_INFO`, de la que derivan a la vez
el render pass del host, la clave de las pipelines y la elección del shader de
resolve. Todo el camino queda coherente: no puede quedar un target a 1x con un
resolve compilado para 4x.

Sustituye al antiguo `rexglue-force-1x-msaa.patch`, que forzaba 1x siempre,
corrompía la imagen y no se podía desactivar sin recompilar, así que nunca se
llegó a medir.

Se puede fijar de dos maneras:

- `msaa_override = 2` en `ns3fb.toml` (lo que usa la matriz).
- Marcador vacío `msaa2.txt` en `Documents/` (para A/B rápido desde el móvil).

> **Los marcadores pisan el TOML.** Si queda un `msaaN.txt` en `Documents`, el
> caso que crees medir no es el que se está ejecutando. El log lo delata y el
> parser lo marca: `msaa aplicado 4 != esperado 2`.

## Auditoría de enlazado del parche

El parche añade código en una **cabecera pública** (`register_file.h`) que se
compila dentro de dos binarios distintos, así que conviene saber por qué usa
`rex::cvar::Query` y no `REXCVAR_GET`.

### Quién define y quién consume

| Pieza | Dónde vive | Visibilidad |
|---|---|---|
| `cvar.cpp` (registro + `Query`) | `rexcore` → **`rexruntime`** | exportada (sin `VISIBILITY_PRESET`; `WINDOWS_EXPORT_ALL_SYMBOLS` en Windows) |
| `flags.cpp` (`msaa_override`) | **`rexgpu-xenos`** | `CXX_VISIBILITY_PRESET hidden` |
| `register_file.h` | 18 TUs, **todas dentro de `rexgpu-xenos`** | — |

`src/graphics/CMakeLists.txt` lo deja explícito:

> *"Never link the OBJECT libraries (rexcore/rexui) here; rexruntime already
> contains those objects and relinking them would duplicate global state."*

Es decir: hay **un solo** registro de cvars, el de `rexruntime`, y el plugin lo
usa a través de la dylib. Por eso `Query("msaa_override")` enlaza desde
cualquier target.

### `REXCVAR_GET` funcionaría hoy, pero es frágil

`REXCVAR_GET(msaa_override)` expande a `FLAGS_msaa_override_storage_()`, que se
define en `flags.cpp` **dentro del plugin y con visibilidad oculta**. Hoy
enlazaría porque todos los usuarios de `register_file.h` están en el mismo
binario, pero se rompe en cuanto:

- una TU de `rexruntime` instancie `Get<reg::RB_SURFACE_INFO>` (p. ej.
  `xboxkrnl_video.cpp`, que ya incluye la cabecera);
- la app incluya `register_file.h`;
- alguien intente leer el cvar desde fuera del plugin.

En los tres casos el símbolo está oculto y el enlace falla. `Query` no tiene ese
problema porque vive en `rexruntime` y está exportado. La propia cabecera
recomienda `REXCVAR_QUERY` para acceso entre módulos.

### Sin dependencia circular

`register_file.h` → `cvar.h` (solo STL y `rex/string/numeric.h`) y
`logging.h` (tipos + spdlog, que `rexruntime` ya declara `PUBLIC`). Ninguno de
los dos incluye cabeceras de `graphics`, así que no hay ciclo.

### Y un fallo que salió en la auditoría

Los marcadores se aplicaban en `OnConfigurePaths`, pero **casi todos apuntan a
cvars del plugin** (`async_shader_compilation`, `render_target_path_vulkan`,
`vulkan_async_skip_incomplete_frames`, `msaa_override`), que se registran al
cargar el plugin en `SetupPresentation() → LoadGpuPlugin()`, *después* de ese
hook. `SetFlagFromSource` devuelve `kRejected` para un cvar que aún no existe y
**no lo guarda** para más tarde (los valores de `ns3fb.toml` sí van a
`GetPendingValuesStorage`). Resultado: `rtt_fsi.txt`, `async_on.txt` y
`no_async_present.txt` nunca se aplicaron; el log decía
`cvar override failed`.

Ahora se aplican en `OnPreLaunchModule()`, que corre después de cargar el
plugin. Si el log vuelve a decir `cvar override failed`, el marcador no sirve y
hay que usar `ns3fb.toml`.

## Resultados medidos (iPhone 11 / A13, 1280x720, fbo)

Medido con el Metal Performance HUD + `NS3FB-PASS` del log, mismo escenario.

| Caso | Escena | GPU | Compute | Fragment | FPS | Imagen |
|---|---|---|---|---|---|---|
| `00-baseline` | menú | 61,09 ms | 32,56 | 20,21 | 15,75 | correcta |
| `01-msaa2` | menú | 26,91 ms | 14,43 | 8,20 | 22,30 | **corrupta** |
| `01-msaa2` | juego | 23,12 ms | 14,17 | 5,14 | 30,02 | **corrupta** |
| `07-kpo-msaa2` | juego | 21,33 ms | 12,83 | 5,10 | 27,90 | **corrupta** |

### Conclusión sobre `msaa_override`

**Gana rendimiento y rompe la imagen.** Reduce la GPU un 27–56 % y llega a 30 fps
en juego, pero aparecen bloques cian y texturas desaparecidas, también en el menú.

No es cuestión del número de muestras (1x y 2x fallan igual): la EDRAM emulada
está atada al layout de 4x del invitado, así que al cambiar las muestras del host
los `resolve_*_cs` y los shaders que usan cobertura leen datos con otra geometría.
Arreglarlo exige reescribir la ruta de resolve, no mover el punto donde se
sobrescribe el registro.

Por eso `msaa_override` se queda en **0** por defecto y se documenta como
instrumento de medida: sirvió para demostrar que el resolve de MSAA es ~45 % del
frame, que es un dato que no teníamos.

### Conclusión sobre `keep_pass_open`

Solo evitó el **7 %** de los cierres de render pass (`kept_open=1760` de
`ends=25200`): dos de cada tres cierres los fuerza una barrera que toca un
adjunto, y esos son inevitables. No compensa el riesgo de artefactos, que es
justo lo que advierte el propio parche.

### `03-540p`: la que se queda (medido)

960x540, MSAA 4x intacto, `fbo`. iPhone 11 / A13.

| Escena | FPS | GPU | Compute | Fragment | Imagen |
|---|---|---|---|---|---|
| menú | 27,57 – 28,33 | 22,65 – 29,38 ms | 8,68 – 12,19 | 8,92 – 10,80 | **correcta** |
| transición | 29,89 | 17,09 ms | 7,26 | 6,05 | correcta |

Contra el baseline de 1280x720 (15,75 fps / 61,09 ms): **+79 % de FPS y −57 %
de GPU**, con la imagen correcta.

El `Command Buffer CPU` bajó de 37,61 ms a 0,51–6,86 ms: menos píxeles también
es menos trabajo de encoding.

La GPU baja más que proporcionalmente a los píxeles (0,56x píxeles → 0,43x
tiempo) porque el tráfico de EDRAM y el resolve de MSAA no escalan lineal. Es
la razón de que 720p no entrara y 540p sobre tanto.

Por eso `video_mode_width/height` quedan en 960x540 como **valor por defecto en
el código** (`ns3fb_app.h`), y `ns3fb.toml` puede subirlos si un dispositivo
tiene margen.

### Siguiente palanca

`03-540p`: 960x540 sin tocar MSAA. 0,56x píxeles sobre el 87 % del frame, sin
cambiar semántica, así que no puede corromper nada.

## Cómo leer el resultado

El CSV (`perf/summary.csv`) trae, por caso:

| Columna | Qué es |
|---|---|
| `frame_ms` / `fps` | intervalo de frame medio (MoltenVK) y su inversa |
| `vertex` / `fragment` / `compute` / `blit` | los cuatro buckets, en ms |
| `gpu_exec` | tiempo de ejecución del `MTLCommandBuffer` según MoltenVK |
| `pass_ends_delta` | cierres de render pass durante el tramo medido |
| `kept_open_delta` | cierres evitados por el parche (debe subir en 06/07) |
| `barrier_ratio` | fracción de cierres causados por barreras |
| `note` | avisos: caso mal aplicado, buckets ausentes, etc. |

### Criterios de decisión

| Observación | Conclusión |
|---|---|
| `01-msaa2` recorta `compute` ~50 % y llega a ≤33 ms **sin artefactos** | Activar 2x por defecto: es la mejor relación ganancia/riesgo |
| `01-msaa2` no mueve `compute` | El resolve no es MSAA-bound; el coste está en cambiar de render target, no en las muestras |
| `02-msaa1` baja mucho pero aparecen artefactos en pelo/humo/transparencias | Descartar 1x; es cobertura por muestra, no antialiasing |
| `03-540p` baja `fragment` ~40 % | Palanca independiente: se puede sumar a la de MSAA |
| `06-kpo` con `kept_open_delta > 0` y `pass_ends_delta` menor | El parche hace su trabajo; cuantificar el ahorro en `compute`/`blit` |
| `06-kpo` con `kept_open_delta = 0` | El gate no deja pasar nada; el parche no está actuando |
| `08-fsi` sube `fragment` y baja `compute` | Reparto distinto; comparar el total, no un bucket suelto |
| El mismo caso repetido al final da peor | Throttling térmico: la comparación no es válida |

## Límites del banco

- Mide **GPU**. No mide draw calls, ni CPU del invitado, ni el spin-wait
  `db16cyc` (ver `docs/TROUBLESHOOTING.md` §7.3).
- Los buckets vienen de MoltenVK y del HUD de Metal. Si tu build no los escribe,
  la columna sale vacía y el parser avisa; rellénala a mano desde el HUD.
- Un caso por sesión: cambiar de caso reinicia la app y vuelve a compilar
  pipelines.
