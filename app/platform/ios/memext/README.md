# ns3fb-mem — extension para el techo de RAM de iOS

Implementacion del "RAM limit workaround" de MeloNX 2.7: una **NSExtension** que
reserva memoria en su propio proceso (con su propio presupuesto de jetsam) y se
la pasa al app por XPC con `xpc_shmem`, para que las paginas de la RAM del
invitado no cuenten contra el `phys_footprint` del app.

El diseno completo, la geometria de las cinco vistas del invitado, los marcadores
de activacion y lo que falta por verificar estan en
[`docs/RAM_EXTENSION_PLAN.md`](../../../docs/RAM_EXTENSION_PLAN.md).

## Ficheros

| Fichero | Que es |
| --- | --- |
| `NS3FBRamDonorProtocol.h` | Claves XPC y constantes. Lo compilan los dos lados |
| `NS3FBMemExtension.mm` | La extension: `mach_vm_allocate` purgable + `xpc_shmem_create` |
| `Info.plist` | Share Extension con `FALSEPREDICATE`: invisible en la hoja de compartir, solo se instancia desde la app |

El lado app vive en `app/src/ios/ns3fb_ram_donor.{h,mm}`.

## Build

`app/CMakeLists.txt` crea el target `ns3fb-mem` y copia el `.appex` a
`ns3fb.app/PlugIns/`. `scripts/make-ipa.sh` lo firma antes que la app (firma
anidada). Para compilar un IPA **sin** la extension:

```
cmake ... -DNS3FB_MEM_EXTENSION=OFF
```

## Activacion en el dispositivo

La extension va empaquetada siempre, pero no se usa hasta que existe
`Documents/ramext_on.txt` en la app Archivos. `Documents/ramext_keepdonors.txt`
deja los donantes vivos despues de mapear (para medir su footprint).
