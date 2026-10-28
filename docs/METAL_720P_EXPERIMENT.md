# Experimento: ¿llega un backend Metal nativo a 720p a 30 fps?

Documento vivo de la rama `experiment/metal-720p`. Responde **con una medición**
a la pregunta de si merece la pena portar el backend Metal, antes de escribir
una sola línea del port.

## 1. La pregunta, en números

`docs/METAL_BACKEND.md` concluye que un backend Metal nativo no arregla el
rendimiento. Esa conclusión está bien fundada en el coste **por copia**, pero no
responde a la pregunta que importa: ¿cuántas copias quedan por frame?

Frame medido en iPhone 11 / A13, 1280×720, `fbo`, escena de selección
(`docs/PERF_MATRIX.md`):

| Componente | ms | ¿Lo cambia un backend Metal? |
|---|---|---|
| Compute (`resolve_*_cs`) | 30,34 | **sí** — objetivo del experimento |
| Fragment | 25,54 | no (salvo que el fill use menos ancho de banda) |
| Blit | 5,51 | no |
| Vertex | 3,14 | no |
| **Total** | **63,07** | |

De ahí salen ~**25 resolves por frame** (30,34 / 1,21 ms por copia).

Y el presupuesto:

- 30 fps → **33,33 ms** por frame
- 60 fps → **16,67 ms** por frame

**Dato incómodo que sale de la propia tabla:** «todo lo que no es resolve» son
25,54 + 5,51 + 3,14 = **34,19 ms**. Eso ya está *por encima* del presupuesto de
30 fps en un A13. Es decir, en este móvil 720p30 **no depende del resolve**: ni
quitando todas las copias a cero se baja de 34,19 ms.

Lo único que puede cambiar ese veredicto es que el fill con *tile memory* sea más
barato que con memoria privada, porque entonces también se encoge el fragment.
Eso es exactamente lo que mide el banco.

## 2. Qué mide el banco (`spike/metal-720p`)

Una app de ~1 minuto de build, sin SDK ni ejecutable del juego. Cuatro medidas a
1280×720 con 4x MSAA y overdraw 4:

| # | Medida | Qué representa |
|---|---|---|
| 1 | `p_priv` | pasada MSAA en memoria privada, sin guardar — hoy |
| 2 | `p_mem` | pasada MSAA **memoryless**, sin guardar — con tile memory |
| 3 | `r_compute` | ms por copia con el kernel compute — camino Vulkan actual |
| 4 | `r_tile` | ms por copia con `MultisampleResolve` en el tile |

Y proyecta el frame completo. **El banco no reproduce el resolve del port** (el
del port convierte formato, hace downscale y encadena varios targets), así que lo
que se transfiere no es el coste absoluto sino la **proporción** `tile/compute`,
anclada en el coste real por copia del port:

```
portPorCopia = 30,34 / 25 = 1,2136 ms

baseline  = 34,19 + 25 * portPorCopia              (debe rondar los 63,07 medidos)
tile      = 34,19 + 25 * portPorCopia * proporción
directo   = 34,19 +  1 * portPorCopia              (resolve directo)
dir+tile  = 34,19 +  1 * portPorCopia * proporción (lo mejor que puede dar Metal)
```

La línea `dir+tile` es la que decide: si esa no cabe en 33,33 ms, ningún backend
Metal llega a 720p30 en ese móvil. Y si el fill con memoryless sale más barato
que con memoria privada, la app lo descuenta del fragment y saca una línea extra
`dir+tile con fill memoryless`.

La línea `control del modelo` compara el `baseline` proyectado con los 63,07 ms
medidos en el port: si se parecen, el modelo está bien anclado.

## 3. Cómo se ejecuta

**En Codemagic** (sin Mac): el workflow `ios-metal-720p` de `codemagic.yaml`
dispara solo con esta rama y produce `Metal720p.ipa` en ~1–2 min.

```
Codemagic → tu app → Start new build → workflow "Metal 720p (budget)" → branch experiment/metal-720p
```

**En un Mac**, si lo tienes:

```bash
./spike/metal-720p/build-ipa.sh     # -> Metal720p.ipa
```

Instálalo, ábrelo y espera unos segundos. El resultado sale en pantalla en
tipografía monoespaciada, en `Documents/spike_metal_720p.txt` (visible en la app
Archivos) y por `NSLog` con el prefijo `[metal-720p]`.

## 4. Cómo se lee

La app termina con un veredicto, pero el número que hay que mirar es
`dir+tile` frente a 33,33 ms:

| Resultado | Qué significa | Qué hacer |
|---|---|---|
| `dir+tile` ≤ 33,33 ms | 720p30 alcanzable en ese móvil | Merece la pena el port. Empezar por el hito 1 de `METAL_BACKEND.md`. |
| 33,33 < `dir+tile` ≤ 38 ms | en el límite; un chip más nuevo lo pasa | Port solo si el objetivo es iPhone 15/16 en adelante. |
| `dir+tile` > 38 ms | 720p30 no sale en ese móvil | No portar el backend. Quedarse en 540p30 y cerrar el tema. |
| `p_mem` < `p_priv` − 10 % | el tile memory también ahorra fill | Súmale ese ahorro al modelo: puede cambiar el veredicto. |
| `r_tile` ≈ `r_compute` | el resolve en tile no ahorra nada aquí | Confirma `spike/RESULTS.md`; el único argumento que queda es el resolve directo. |

## 5. Qué NO prueba este banco

- No renderiza el juego: el `fs_main` es una carga de ALU aproximada, no el
  fragment shading real de Storm 3. La constante de «OTROS» viene del port, no de
  esta app; el banco solo mide la parte que un backend cambiaría.
- No mide el coste de **codificar** 25 pases distintos con estado distinto
  (barreras, pipelines, attachments). Los cierres de encoder son el otro coste
  grande de este port (`split_by_attachment` altísimo) y un backend nativo los
  reduce, pero eso no está en el modelo: el veredicto es, si acaso, pesimista.
- No dice nada sobre 60 fps. Para 60 harían falta 16,67 ms y ya solo «OTROS» son
  34,19 ms en un A13: **60 fps a 720p no es alcanzable con ninguna arquitectura
  que conserve el modelo de emulación de EDRAM actual.**

## 6. Si el veredicto es «adelante»

El orden correcto, del documento de decisión:

0. Esta medición. ✅
1. `gpu_plugin = "metal"` que carga y hace un clear (~1.500 líneas).
2. PM4 + estado de registros hasta el primer triángulo (~6.000).
3. Texture cache con conversión de formato (~3.500).
4. Render target cache sobre tile memory (~6.000).
5. Paridad de estado: blend, depth, MSAA, queries (~5.000).

Referencia que **sí existe** y que `METAL_BACKEND.md` daba por inexistente:
`src/xenia/gpu/metal/` de XeniOS / Xenia-Edge, 33.092 líneas en 38 archivos
(BSD-3), incluido `metal_direct_host_resolve.cc` — el resolve directo que el
camino Vulkan de ReXGlue tiene como stub.
