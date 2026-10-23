# metal-tile-resolve

Banco de pruebas aislado. **No forma parte del port** y no lo toca: es una app
aparte, con su propio bundle ID, que solo mide una cosa.

## La pregunta que responde

El port gasta ~30 ms por frame de GPU en `Compute`, y son los shaders
`resolve_*_cs` de Xenia: las copias de render target al cambiar de layout. La
única razón para escribir un backend Metal nativo (≈25.000 líneas) sería que
Metal pueda resolver el MSAA **dentro del tile**, sin que el buffer multisample
llegue nunca a memoria.

Este banco lo mide a 1280x720 con 4x MSAA, con el mismo rasterizado en ambos
caminos:

| Camino | Cómo resuelve |
|---|---|
| **A** | MSAA en `MTLStorageModeMemoryless` + `MTLStoreActionMultisampleResolve` (resolve en el tile) |
| **B** | MSAA en memoria privada + store, y un kernel `resolve4x` que lee los 4 samples (lo que hace Xenia hoy) |

5 frames de calentamiento + 20 medidos, `GPUStartTime`/`GPUEndTime` del command
buffer.

## Cómo se lee el resultado

Sin Mac no hay consola de Xcode, así que el resultado se escribe en **dos**
sitios:

- en pantalla, en tipografía grande (vale una captura)
- en `Documents/spike_result.txt`, visible desde la app Archivos

```
device: Apple A13 GPU
render: 1280x720, 4x MSAA, 20 frames, overdraw 4

A  tile resolve (memoryless + MultisampleResolve): 0.412 ms/frame
B  compute resolve (store + resolve4x kernel)    : 26.140 ms/frame
delta B-A: 25.728 ms/frame

B es 63.4x el coste de A

VEREDICTO: el resolve por compute cuesta ms de verdad...
```

## Interpretación

- **`delta` grande (> 5 ms)**: el backend Metal nativo tiene razón económica. Es
  la única vía para recuperar esos milisegundos, porque Vulkan no puede expresar
  "este attachment no sale del tile".
- **`delta` pequeño**: un backend nativo no arreglaría el rendimiento. El coste
  estaría en otro sitio y escribir 25.000 líneas no lo movería.

Ojo: el banco mide **el resolve**, no la emulación de Xenos entera. Un backend
real seguiría teniendo que resolver el mismo trabajo de rasterizado; lo que
ahorra es la copia a memoria.

## Compilar

```bash
bash spike/build-ipa.sh        # produce MetalSpike.ipa en la raíz
```

O en Codemagic: workflow **`ios-metal-spike`**. No compila el SDK, así que tarda
~1-2 minutos.

## Instalar

Igual que el juego: `MetalSpike.ipa` con tu servicio de firma. Bundle ID
`com.creao.metalspike` (cámbialo en `spike/ios/Info.plist` si tu servicio lo
requiere).

Al abrir: espera ~3 segundos, lee la pantalla, y luego mira
`En mi iPhone / Metal Spike / spike_result.txt`.
