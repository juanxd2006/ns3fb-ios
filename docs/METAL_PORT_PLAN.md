# Backend Metal: el andamio y la ruta más corta

Documento de la rama `experiment/metal-backend`. Aquí está el **paso 1 real** de un
backend Metal nativo: no la emulación, sino la prueba de que el plugin compila, se
carga y es seleccionable. Todo lo que sigue se apoya en esto.

## 0. Estado del arte (investigado el 2026-10-28)

Antes de invertir semanas, esto es lo que dicen las fuentes:

### Los mantenedores de ReXGlue descartan el backend Metal, y por una razón

Issue **#235 "Mac Support"** (`rexglue/rexglue-sdk`), abierta y cerrada por un
mantenedor (Graine25), deja el soporte macOS resuelto **con MoltenVK** y pone
explícitamente en *Out of Scope*:

> *Native Metal backend: Metal 4 lacks support for a lot of features that D3D12
> supplies for the gpu backend*

Es decir: no es que nadie lo haya intentado en ReXGlue; es que quien mantiene el
runtime que usamos considera que **Metal no da las características que la emulación
de Xenos necesita**. Eso no invalida a XeniOS, pero sí explica por qué nadie lo ha
hecho aquí.

### Los dos backends Metal de Xenia que existen son jóvenes y con fallos de resolve

- **XeniOS / Xenia-Edge** (`src/xenia/gpu/metal/`, 33.092 líneas, BSD-3).
- **xenia-mac** (wmarti), desde enero 2026: ARM64 + Metal, autor lo describe como
  "extremely early", muchos juegos no arrancan.

De la lista de compatibilidad de xenia-mac, un fallo que nos toca de cerca:

> *4E4D083D (Soul Calibur 5): **Metal backend resolve failures***

Resolve es justo el punto donde este port sufre (el `TryResolveCopyDirectly` que en
Vulkan es un stub). Empezar por ahí con un backend cuyo resolve ya falla en otros
títulos es empezar por el sitio más frágil.

### El camino de shaders exige un componente propietario de Apple

El backend Metal **no** traduce microcódigo Xenos a MSL directamente. La cadena es:

```
ucode Xenos -> DXBC -> DXIL -> Metal IR (Apple Metal Shader Converter) -> MTLLibrary
```

`libmetalirconverter.dylib` es de Apple, y su EULA permite distribuirlo
**"solely for shader conversion"** y solo en hardware Apple. Es una dependencia más
que viajaría dentro del `.ipa`, con su licencia.

Y el autor de xenia-mac dice de esa ruta, que eligió por ser la más fácil, que trae
**"a big performance penalty"**. O sea: el backend nativo no garantiza ser más rápido
en el trabajo de shaders; la ganancia tendría que venir de tile memory y barreras,
no del sombreado.

## 0.1 Veredicto

Con esto sobre la mesa, el orden correcto **no** es empezar el backend:

1. **El andamio ya está hecho** (§1). Vale como documentación y como prueba de que
   el enganche existe. Está OFF.
2. **Antes de escribir emulación, medir la hipótesis gratis**: instalar **XeniOS**
   (que ya lleva Metal nativo) y ver Storm 3 en el mismo iPhone. Si ahí va peor que
   este port, el backend Metal no tiene caso y te has ahorrado meses. Si va mejor,
   hay una razón medida para seguir.
3. **Y el banco de 720p** sigue siendo la puerta dura: solo el fill + blit + vertex
   ya son 34,19 ms en un A13, por encima de los 33,33 ms de 30 fps. Ningún backend
   arregla eso.

## 1. Lo que ya está hecho (y lo que no)

`ci/rexglue-metal-scaffold.patch` añade al SDK:

| Fichero | Qué hace |
|---|---|
| `include/rex/graphics/metal/graphics_system.h` | Declara `MetalGraphicsSystem : GraphicsSystem` |
| `src/graphics/metal/graphics_system.mm` | Crea el `MTLDevice`, escribe su nombre en el log, deja constancia de lo que falta |
| `src/graphics/plugin_main.cpp` | Rama nueva en la fábrica: `backend == "metal"` |
| `CMakeLists.txt` (raíz) | `option(REXGLUE_USE_METAL ... OFF)` + validación + línea de estado |
| `src/graphics/CMakeLists.txt` | Fuentes, `REX_HAS_METAL=1` y los `-framework` de Metal |

**Está OFF por defecto.** Mientras no se active, el build del juego es exactamente el
de ahora: cero riesgo.

Y lo que hace el esqueleto, exactamente: leer el nombre de la GPU en el log. Nada
más. `IsAvailable()` devuelve `false` a propósito, para que `backend = "any"` no lo
elija por accidente.

## 2. Por qué este paso y no otro

La fábrica del plugin es una sola y ya existe:

```cpp
// src/graphics/plugin_main.cpp
extern "C" REX_GPU_PLUGIN_EXPORT rex::system::IGraphicsSystem* rex_gpu_create(
    uint32_t abi_version, const rex::system::GpuCreateInfo* info);
```

`GpuCreateInfo` solo lleva `struct_size` y `backend` (`"d3d12"`, `"vulkan"`, `"any"`).
Es decir: **un backend nuevo no necesita plugin nuevo**, solo una rama en la fábrica
y una clase que implemente `IGraphicsSystem`.

Y `GraphicsSystem` (la base de Vulkan y D3D12) ya resuelve el 90 % del pegamento:
registros MMIO, worker de vsync, interrupciones, pausa, guardado de estado. Un
backend solo tiene que implementar **dos** cosas:

```cpp
protected:
  void CreateProvider(bool with_presentation) override;                    // ui::GraphicsProvider
  std::unique_ptr<CommandProcessor> CreateCommandProcessor() override;     // PM4 + estado
```

Eso es el mapa completo del trabajo que queda.

## 3. El mapa real: qué se trae y qué hay que reescribir

Referencia: `src/xenia/gpu/metal/` de XeniOS / Xenia-Edge, **33.092 líneas en 38
ficheros, BSD-3** (con atribución obligatoria → `CREDITS.md`).

| XeniOS | Líneas | Destino en ReXGlue | Dificultad |
|---|---|---|---|
| `metal_command_processor.cc` | 8.459 | `metal/command_processor.mm` | **Alta**: reconcilia la base `CommandProcessor` de ReXGlue (refactorizada) |
| `metal_render_target_cache.cc` | 8.075 | `metal/render_target_cache.mm` | Alta, pero es **la que da el rendimiento** |
| `metal_texture_cache.cc` | 4.646 | `metal/texture_cache.mm` | Media: mucha conversión de formato, poco acoplamiento |
| `metal_pipeline_cache.cc` | 2.970 | `metal/pipeline_cache.mm` | Media |
| `metal_direct_host_resolve.cc` | 1.000 | igual | Baja: casi autocontenido |
| `metal_shader_converter` + `dxbc_to_dxil` | ~1.000 | `metal/shader_converter.mm` | Media |
| `metal_primitive_processor` + `metal_geometry_shader` | 217 | igual | **Baja y crítica**: Metal no tiene geometry shaders y Storm 3 los usa para partículas |
| resto (heap pool, upload pool, zpd, telemetría) | ~3.700 | igual | Baja |
| `metal_graphics_system.cc` | 48 | ya hecho en el andamio | — |

Lo que **no** viene de XeniOS y hay que escribir aquí: `MetalProvider` y
`MetalPresenter` (`rex::ui::GraphicsProvider` / `Presenter`), que en ReXGlue son la
abstracción de superficie y ventana. Es la parte con más incógnitas porque depende
de cómo el SDK monta la vista en iOS.

Estimación honrada: **60–70 % del código se porta casi tal cual**, y el 30 % restante
(lo que toca clases base) es reescritura. Semanas, no días.

## 4. Cómo se itera (esto decide el proyecto)

Sin Mac, cada ciclo del juego completo es:

```
código → Codemagic (45–60 min frío) → firmar → instalar → probar en el móvil
```

Un backend necesita **cientos** de ciclos. A una hora por ciclo, no se llega.

La buena noticia: **el plugin se compila solo**, sin el juego y sin codegen.

```bash
# en Codemagic, como script de un workflow:
cmake --preset ios-arm64-release -DREXGLUE_USE_METAL=ON
cmake --build out/ios-arm64 --target rexgpu-xenos -j
```

Eso valida en **minutos** (caché caliente) todo lo que es "compila y enlaza", que es
donde se va el 80 % del tiempo en un port así. El móvil solo hace falta para "se ve
bien".

Y el runner de Codemagic (`mac_mini_m2`) tiene **GPU real**: se puede montar un
harness que ejercite el render target cache en Metal y compare píxeles contra
referencias, sin iPhone. Eso es lo que convierte el proyecto en viable.

## 5. Orden, con puertas de decisión

| # | Paso | Qué lo valida | Coste |
|---|---|---|---|
| 0 | Banco 720p (`experiment/metal-720p`) | ¿Cabe 720p30? Si no, no seguir | 2 min CI |
| 1 | **Andamio** (este parche) | `REXGLUE_USE_METAL=ON` compila y el plugin loguea la GPU | 1 build SDK |
| 2 | `MetalProvider` + `MetalPresenter` con clear | Pantalla de color en el iPhone | semanas |
| 3 | `MetalCommandProcessor`: PM4 + estado | Un triángulo | semanas |
| 4 | `MetalPrimitiveProcessor` (GS) + texture cache | Una escena con texturas y partículas | semanas |
| 5 | `MetalRenderTargetCache` sobre tile memory + resolve directo | El frame completo | semanas |

Si el paso 0 dice que 720p30 no cabe, los pasos 2–5 no tienen sentido: el objetivo
realista del backend es **720p a 30 estables**, no 60 fps.

## 6. Qué se gana de verdad

- **Render targets `memoryless`**: el resolve de MSAA ocurre en el tile y el buffer
  multisample nunca se escribe a memoria. Es lo único que ataca los ~30 ms de compute.
- **Resolve directo**: `metal_direct_host_resolve.cc` hace lo que en Vulkan es un stub
  (`TryResolveCopyDirectly` → `DumpRenderTargets`).
- **Barreras explícitas**: la sesión de Storm 3 cierra **518.600 render passes**. Un
  backend nativo puede mantener más abiertos porque controla las barreras.
- Lo que **no** se gana: CPU de encoding (ya no es el cuello: 0,73 ms con `fsi`), ni
  60 fps.

## 7. Licencia

El código de XeniOS / Xenia-Edge es **BSD-3**. Al portarlo hay que conservar el aviso
de copyright en los ficheros derivados y añadirlo a `CREDITS.md` (que ya existe en
este repo). El `NOTICE.md` puede recoger el linaje ReXGlue → Xenia → XeniOS.
