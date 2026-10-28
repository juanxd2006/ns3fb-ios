# Traza de entrada y de frames del invitado

Diagnóstico para el bug del **combo de mob battle**: aparece el botón en pantalla
(`B`), se pulsa y no avanza.

## Activar

Crear un fichero **vacío** en la app Archivos:

```
Documents/input_trace.txt
```

Sin ese marcador los dos parches no escriben **nada**. Se puede quitar en caliente
(se comprueba una vez por proceso: para desactivar, cerrar y abrir el juego).

## Qué escribe

```
NS3FB-INPUT keydown vk=0x5801 flags=0x0001
NS3FB-INPUT keyup   vk=0x5801 flags=0x0002
NS3FB-INPUT state 0x0000 -> 0x1000 (visto por estado, sin keystroke)
NS3FB-INPUT-FRAMES polls=59.8/s keystrokes=0.4/s keydowns_total=7 buttons=0x0000
NS3FB-GUEST-FRAMES swaps=59.7/s total=1204 (compara con los fps del HUD)
```

| Línea | Qué mide |
|---|---|
| `NS3FB-INPUT keydown` | flanco de bajada que **llega al invitado** |
| `NS3FB-INPUT keyup` | flanco de subida |
| `NS3FB-INPUT state` | el botón cambia en una consulta de estado, **sin** keystroke |
| `NS3FB-INPUT-FRAMES polls/s` | veces por segundo que el invitado **sondea** el mando |
| `NS3FB-GUEST-FRAMES swaps/s` | frames que el juego **pide presentar** |

## Cómo se lee

Reproduce el bug pulsando B en el QTE y busca en el log:

| Lo que sale | Conclusión | Dónde se arregla |
|---|---|---|
| `keydown vk=0x5801` al pulsar, y el combo no avanza | la pulsación **llega**; el juego la descarta por tiempo | ventana del QTE / pacing del invitado |
| **Ningún** `NS3FB-INPUT` al pulsar | la pulsación **no llega** | driver de entrada |
| Solo `state`, nunca `keydown` | el juego ve el botón por estado y no por evento | generación de keystrokes |
| `keydown` con un `vk` que no es B | mapeo de botones | tabla de VirtualKey |
| `swaps/s` ≈ doble que los fps del HUD | la **lógica corre al doble** que la presentación | pacing: la ventana del QTE dura la mitad |

Las teclas de Xbox 360 que emite el port: `A=0x5800`, `B=0x5801`, `X=0x5802`,
`Y=0x5803`.

## Por qué importa lo de swaps/s

En el port de PC de este mismo juego hay reportes de que los QTE se vuelven casi
imposibles **a 60 fps**: la ventana se mide en frames del bucle del juego. Si aquí
`swaps/s` es ~60 mientras el HUD marca 30, pasa lo mismo: la ventana dura la mitad
en tiempo real. Es la primera cosa que hay que mirar en este log.
