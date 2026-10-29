# Techo de RAM de iOS: extension + `xpc_shmem` (implementado, sin probar en dispositivo)

Estado: **implementado y empaquetado, apagado por defecto**. Este documento
explica el problema, el diseno, como se activa y que hay que verificar en el
primer build. Tecnica portada de **MeloNX 2.7**
(`starforgejo.dev/projects/MeloNX`, `MLXRamDonor` + `MeloNXRamDonor`).

## El problema

iOS aplica un limite de memoria por proceso (jetsam, `per-process-limit`). En un
iPhone 11 (3 GB) el app se queda en ~1,3-1,5 GB. El invitado de la 360 necesita
512 MB, pero el proceso entero ronda **1,33 GB** con el juego a 30 fps y 540p
(medido en el HUD). No lo estamos tocando: el techo lo alcanza el juego solo.

Los entitlements `com.apple.developer.kernel.increased-memory-limit` y
`extended-virtual-addressing` suben ese techo, pero **solo los concede una cuenta
de pago o TrollStore**; con Apple ID gratis y Sideloadly no llegan a la firma.
`ns3fb.entitlements` ya lleva el segundo (lo necesita la reserva de 4,5 GB).

## La tecnica

Una **NSExtension** corre en su propio proceso, con su propio presupuesto de
jetsam. Si esa extension reserva memoria y el app la mapea, las paginas cuentan
contra el presupuesto de la extension (o como memoria compartida), no contra el
`phys_footprint` del app.

1. La app arranca la extension con `NSExtension` (API privada), pasandole un
   `NSXPCListenerEndpoint` en `NSExtensionItem.userInfo`.
2. La extension conecta de vuelta por XPC y se queda viva (nunca completa la
   peticion; si la completara, iOS podria desmontar el proceso).
3. La app pide trozos de 64 MB. La extension reserva cada trozo con
   `mach_vm_allocate(VM_FLAGS_PURGABLE)`, lo publica con `xpc_shmem_create()` y
   devuelve el descriptor.
4. La app lo mapea con `xpc_shmem_map()` y lo **recoloca** con
   `mach_vm_remap(VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE)` encima de sus propias
   vistas del invitado.
5. Los donantes se matan despues de mapear (las paginas ya estan en la app), para
   que iOS no los mate por su cuenta a mitad de partida.

## Por que el paso 4 es el que tiene truco aqui

Un emulador de Xbox 360 no tiene *un* mapeo de RAM: tiene **cinco vistas que
aliasean el mismo rango fisico**. `Memory::MapViewsMac()` (en
`src/system/xmemory.cpp` del SDK) reserva 4,5 GB contiguos y mapea el mismo
fichero en varias direcciones, para que el invitado vea la RAM fisica en
`0xA0000000`, `0xC0000000`, `0xE0000000` y `0x100000000`, y la GPU en
`0x7F000000` (GPU writeback):

| Vista (host) | Tamano | Offset de fichero | Uso |
| --- | --- | --- | --- |
| `0x7F000000` | 16 MB | `0x100000000` | GPU writeback (primeros 16 MB fisicos) |
| `0xA0000000` | 512 MB | `0x100000000` | fisico, paginas 64 KB |
| `0xC0000000` | 512 MB | `0x100000000` | fisico, paginas 16 MB |
| `0xE0000000` | 512 MB | `0x100000000`* | fisico, paginas 4 KB |
| `0x100000000` | 512 MB | `0x100000000` | fisico crudo |

\* el SDK redondea el offset a la granularidad (16 KB en arm64) y luego suma
`PhysicalHostOffset()` = 0x1000 al traducir, porque ese heap empieza 4 KB
despues. La implementacion replica ese mismo calculo.

Si solo se recolocara una de las cinco, el invitado y la GPU dejarian de ver la
misma memoria y el juego se corrompe desde el primer frame. Por eso
`ns3fb_ram_donor.mm` recorre, para cada trozo, todas las vistas que caen dentro
del rango y hace un `mach_vm_remap` por vista.

## Que hay en el repo

| Fichero | Que hace |
| --- | --- |
| `app/platform/ios/memext/NS3FBRamDonorProtocol.h` | Claves XPC y constantes, compartido por los dos lados |
| `app/platform/ios/memext/NS3FBMemExtension.mm` | La extension: reserva, publica y atiende `create`/`release`/`available`/`physmem` |
| `app/platform/ios/memext/Info.plist` | Share Extension con `FALSEPREDICATE` (invisible, solo instanciable desde la app) |
| `app/src/ios/ns3fb_ram_donor.h` / `.mm` | Lado app: arranque de donantes, `xpc_shmem_map`, recolocacion en las 5 vistas |
| `app/CMakeLists.txt` | Target `ns3fb-mem` (`.appex`) y copia a `ns3fb.app/PlugIns/` |
| `scripts/make-ipa.sh` | Firma anidada: dylibs -> `.appex` -> app |

## Como se activa

El build **siempre** trae la extension (salvo `-DNS3FB_MEM_EXTENSION=OFF`), pero
la app **no la usa** si no existe el marcador, asi que el comportamiento por
defecto es exactamente el de antes:

| Marcador en `Documents/` | Efecto |
| --- | --- |
| *(ninguno)* | No se arranca ningun donante |
| `ramext_on.txt` | Arranca donante y respalda los 512 MB fisicos |
| `ramext_keepdonors.txt` | Ademas, deja los donantes vivos (para medir su footprint) |

En el log (prefijo `NS3FB-RAM` y `[NS3FB-MEM]` en la consola de Xcode):

```
NS3FB-RAM extension donante: com.example.ns3fb.mem
NS3FB-RAM donante 1 con 2100 MB libres; se usaran hasta 1972 MB
NS3FB-RAM 512 MB de 512 MB respaldados por la extension; footprint app 1330 MB -> 826 MB (-504 MB)
```

Si algo falla, el log lo dice y el juego sigue con la memoria de siempre:

```
NS3FB-RAM sin extension donante en este build (PlugIns/ vacio)
NS3FB-RAM no arranco ningun donante: iOS rechazo la peticion
NS3FB-RAM nada respaldado (los donantes solo cubrieron 128 MB de 512 MB)
```

## Que hay que verificar en el primer build (no se ha podido compilar aqui)

No hay macOS en el entorno donde se escribio esto: **nada de esto se ha
compilado ni ejecutado**. Por orden de probabilidad de fallo:

1. **Enlazado de `xpc_shmem_*`.** El codigo las declara a mano si el SDK no trae
   `<xpc/shmem.h>`. Si el enlazado falla, se ve en el build, no en el iPhone.
2. **Target `.appex` en CMake.** `add_library(... MODULE)` + `BUNDLE TRUE` +
   `BUNDLE_EXTENSION appex` es la forma estandar, pero no se ha probado con el
   toolchain de este proyecto. El build debe dejar
   `ns3fb.app/PlugIns/ns3fb-mem.appex/ns3fb-mem`.
3. **Firma anidada.** Es el riesgo real: un `.appex` mal firmado invalida la
   instalacion **entera**. Por eso `-DNS3FB_MEM_EXTENSION=OFF` existe: si el IPA
   no instala, se compila sin extension y se compara.
4. **`com.apple.share-services` con `FALSEPREDICATE`.** iOS puede rechazar
   instanciar la extension si el perfil de firma no la incluye. El log dira
   "iOS rechazo la peticion" y el juego seguira funcionando.
5. **Que el footprint baje de verdad.** Es el unico numero que importa: el
   `NS3FB-RAM ... footprint app X MB -> Y MB` del log. Si baja ~500 MB, la
   tecnica funciona en este iOS.

## Por que no se activa solo

Aunque la tecnica funcione, cambia donde vive la memoria del invitado: si la
extension muere cuando no debe, el juego se queda sin RAM en mitad de una
partida. Con el marcador se puede volver atras **sin recompilar**, que es la
unica forma razonable de probarlo a 45-60 minutos por build.

## Alternativas que siguen disponibles

1. **Ajustar el toml** si hay presion de memoria:
   `texture_cache_memory_limit_hard = 512`, `texture_cache_memory_limit_soft = 256`.
2. **Entitlement** con cuenta de pago o TrollStore: descomentar en
   `ns3fb.entitlements` y re-firmar. Es la via limpia si algun dia hay cuenta de
   pago; esta tecnica es la via sin cuenta.
