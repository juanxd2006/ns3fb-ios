# Techo de RAM de iOS: plan para la variante NSExtension + xpc_shmem

Estado: **implementado, apagado por defecto**. El codigo existe y se compila con
`-DNS3FB_MEM_EXTENSION=ON`; sin ese flag el build es identico al de antes y el
cliente compila a un stub vacio.

Implementado:

| Pieza | Fichero |
|---|---|
| Target `.appex` + empaquetado en `PlugIns/` | `app/CMakeLists.txt` |
| Extension (servicio mach + `xpc_shmem_create`) | `app/platform/ios/memext/NS3FBMemExtension.mm` |
| `MachServices` + punto de extension | `app/platform/ios/memext/Info.plist` |
| Cliente del app (`xpc_shmem_map`, con fallback) | `app/src/memext_client.{h,mm}` |

**Sin validar.** Los dos puntos que siguen sin comprobarse son los mismos que
antes, y no se pueden comprobar sin un Mac y un dispositivo:

1. Que `xpc_shmem_create` / `xpc_shmem_map` enlacen en el SDK de iOS del build.
   Si no existen, el flag ON no compila (`#error` explicito en el cliente).
2. Que la firma anidada del `.appex` sobreviva al sideload. Un appex mal firmado
   invalida la **instalacion entera**.

## El problema

iOS aplica un limite de memoria por proceso (jetsam, `per-process-limit`). En un
iPhone 11 (3 GB) el app se queda en ~1,3-1,5 GB. El invitado de la 360 necesita
512 MB, pero el proceso entero ronda **1,33 GB** con el juego a 30 fps y 540p
(medido en el HUD). No lo estamos tocando.

Los entitlements `com.apple.developer.kernel.increased-memory-limit` y
`extended-virtual-addressing` suben ese techo, pero **solo los concede una cuenta
de pago o TrollStore**; con Apple ID gratis y Sideloadly no llegan a la firma.
`ns3fb.entitlements` ya lleva el segundo (lo necesita la reserva de 4,5 GB).

## La tecnica

Una **NSExtension** corre en su propio proceso, con su propio presupuesto de
jetsam. Si esa extension reserva memoria y el app la mapea, las paginas cuentan
en el proceso de la extension:

1. El app arranca la extension (share-services, `FALSEPREDICATE` para que no
   aparezca en la hoja de compartir).
2. La extension crea la region con `xpc_shmem_create(NULL, bytes)`.
3. El descriptor viaja al app por XPC y el app la mapea con `xpc_shmem_map()`
   usando esa region como backing de `rex::memory::Memory` en lugar de la
   entrada Mach que usa hoy.
4. La extension se queda viva mientras dure la sesion (`beginRequest` sin
   completar hasta que el app termine), reteniendo la region.

## Lo que falta para activarlo

| Paso | Donde | Riesgo |
|---|---|---|
| Target CMake del `.appex` | `app/CMakeLists.txt` (bloque nuevo, `NS3FB_MEM_EXTENSION`, OFF) | bajo, pero no se puede validar sin `cmake` de iOS |
| Empaquetado en `PlugIns/` y firma anidada | `scripts/make-ipa.sh` + Sideloadly | **alto**: un `.appex` mal firmado invalida la instalacion entera |
| Protocolo XPC app↔extension y keep-alive | `app/src/` | medio |
| Backing de la memoria del invitado | `rex::memory::Memory` (interna del SDK) | alto: toca la reserva contigua |
| Comprobar `xpc_shmem_*` en el SDK de iOS | `#include <xpc/shmem.h>` | **alto**: API no publica |

## Por que no esta activo

El `.appex` cambia la firma del IPA completo y `xpc_shmem` es API no publica. Sin
un Mac no se puede: compilar el target, comprobar que `xpc_shmem_create` enlaza
en iOS, ni verificar que la firma anidada sobrevive al sideload. Subirlo a ciegas
arriesga **romper la instalacion del build que hoy funciona**, que es lo unico
que no nos podemos permitir a 45-60 minutos por intento.

## Alternativas que si funcionan hoy

1. **Ajustar el toml** si algun dia hay presion de memoria:
   `texture_cache_memory_limit_hard = 512`, `texture_cache_memory_limit_soft = 256`.
2. **Entitlement** con cuenta de pago o TrollStore: descomentar en
   `ns3fb.entitlements` y re-firmar.
3. Bajar resolucion (720p usa bastante mas EDRAM y recursos que 540p).

## Cuando haya un Mac

1. Crear el target `.appex` con `add_library(ns3fb-mem MODULE ...)` y
   `set_target_properties(... BUNDLE TRUE BUNDLE_EXTENSION appex
   MACOSX_BUNDLE_INFO_PLIST ...)`; `install` en `ns3fb.app/PlugIns/`.
2. Compilar y comprobar en el log de enlazado que `_xpc_shmem_create` y
   `_xpc_shmem_map` resuelven contra `libxpc.tbd`.
3. En el app, detras de un cvar (`ns3fb_mem_extension`, default off), arrancar la
   extension, mapear y sustituir el backing; si algo falla, caer al camino Mach
   actual sin abortar.
4. Medir con el HUD: `App` antes/despues y comprobar que el juego sigue a 30 fps
   con el mismo rendimiento (mapear memoria compartida no debe costar fps).
