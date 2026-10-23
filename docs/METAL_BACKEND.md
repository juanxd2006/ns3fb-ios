# Backend Metal nativo — alcance, coste y por qué NO se empieza por ahí

Documento de decisión. No es una promesa: es el análisis que hay que leer antes de
gastar semanas, con los números medidos en este port.

## 1. El dato que decide todo

Medición en dispositivo (iPhone 11 / A13, `render_target_path_vulkan = "fbo"`,
escena de selección de personaje, overlay de MoltenVK):

| Bucket GPU | ms | % |
|---|---|---|
| Compute | 30,34 | 44,1 % |
| Fragment | 25,54 | 37,1 % |
| Blit | 5,51 | 8,0 % |
| Vertex | 3,14 | 4,6 % |
| **Total** | **63,07** | |

Ese `Compute` de ~30 ms **no es MoltenVK**. Son los shaders `resolve_*_cs` de
Xenia/ReXGlue (`src/graphics/vulkan/render_target_cache.cpp`, 52 referencias), que
hacen las copias de render targets cuando cambia el layout del EDRAM. Se ejecutan
en *cualquier* backend: son código del emulador, no del driver.

Y la prueba de que ese es el cuello está en nuestros contadores: de 174.000
rupturas de render pass, 168.430 fueron forzadas por barreras que tocan un
adjunto del pase. El juego cambia de render target constantemente.

**Conclusión incómoda: portar la misma arquitectura a Metal da los mismos 30 ms.**
Un backend nativo solo gana si cambia el *algoritmo* de resolve, no el lenguaje.

## 2. Tamaño real de la obra

Referencia: la implementación Vulkan existente, que ya está escrita y depurada.

| Métrica | Valor |
|---|---|
| Ficheros | 18 |
| Líneas | **24.658** |
| `command_processor.cpp` | 6.958 |
| `render_target_cache.cpp` | 6.155 |
| `pipeline_cache.cpp` | 3.707 |
| `texture_cache.cpp` | 3.261 |

Y eso sin contar MoltenVK, que hoy te da gratis la traducción Vulkan→Metal.

Un backend Metal sería comparable en tamaño, pero **sin referencia que copiar**:
Xenia tiene D3D12 y Vulkan; ReXGlue, lo mismo. No existe un backend Metal de
Xenia en ningún sitio. Serías el primero, sin código del que aprender los casos
raros que ya están resueltos en las otras dos implementaciones.

## 3. Lo único que un backend Metal haría mejor

Tres cosas concretas, y solo una importa de verdad:

1. **Tile memory (la que importa).** En las GPU Apple toda la rasterización vive
   en memoria on-chip por tiles. Un backend nativo puede declarar los render
   targets `memoryless` y hacer el resolve de MSAA *dentro del tile*, sin escribir
   nunca el buffer multisample a memoria. Eso es exactamente lo que los shaders
   `resolve_*_cs` no pueden hacer: para Vulkan, el EDRAM es memoria global.
   Si algo puede matar esos 30 ms, es esto.
2. **Sin capa de objetos Vulkan.** Ahorra CPU de encoding, que ya no es el cuello
   (`Command Buffer CPU` bajó a 0,73 ms con `fsi`).
3. **Barreras explícitas.** Menos cierres de encoder. Menor, y no ataca el coste
   dominante.

## 4. El experimento barato que decide si vale la pena

No se escriben 25.000 líneas para averiguar si (1) es cierto. Se escriben ~200.

**Spike `metal-tile-resolve`:** una app mínima de Metal que, a 1280×720 con 4x
MSAA, compara dos formas de resolver:

- A: render a textura multisample + `MTLStoreActionMultisampleResolve` (tile memory).
- B: render a multisample con store, y resolve con un compute shader que lee los
  4 samples y escribe (lo que hace Xenia hoy).

Si A sale ~100× más rápido que B, el backend nativo tiene una razón económica.
Si A y B salen parecidos, el backend nativo **no arregla el problema** y la
decisión correcta es no escribirlo.

Coste: un target de ~200 líneas, un build y una instalación. Unas horas, no meses.

## 5. Escalera de hitos (si el spike sale bien)

| # | Hito | Tamaño | Verificable por |
|---|---|---|---|
| 0 | Spike tile-resolve | 200 líneas | ms de A vs B |
| 1 | Plugin que carga y presenta un clear | ~1.500 | `gpu_plugin = "metal"` y pantalla de color |
| 2 | PM4 + estado de registros hasta el primer triángulo | ~6.000 | un triángulo con shader Xenos traducido |
| 3 | Texture cache con conversión de formato | ~3.500 | una escena con texturas correctas |
| 4 | Render target cache sobre tile memory | ~6.000 | el frame completo sin resolves a memoria |
| 5 | Paridad de estado (blend, depth, MSAA, queries) | ~5.000 | el juego jugable |

Del hito 2 en adelante, cada uno es de semanas y necesita compilar y probar en
dispositivo en cada iteración.

## 6. Veredicto

**No empezar por el hito 1.** El orden correcto es:

1. Hito 0 (spike). Barato, y puede matar la idea antes de gastar nada.
2. Si el spike sale bien, hito 1 y 2 en paralelo con el mantenimiento del port
   actual, porque el port Vulkan seguirá siendo el que uses durante meses.
3. Si el spike sale mal, cerrar el tema del rendimiento: el techo del A13 con
   esta arquitectura está donde está, y la vía es jugar por streaming.
