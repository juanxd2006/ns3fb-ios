# ns3fb-mem — extension para el techo de RAM de iOS

Tecnica "RAM limit workaround": una **NSExtension** que reserva memoria en su
propio proceso y se la pasa al app por XPC con `xpc_shmem`, para que esas
paginas cuenten contra el presupuesto de jetsam de la extension y no contra el
del app.

**Apagada por defecto.** Se construye con:

```bash
./scripts/03-build-app.sh -DNS3FB_MEM_EXTENSION=ON
```

Sin ese flag este directorio no se compila y `src/memext_client.mm` compila a un
stub que devuelve un bloque vacio: el build es identico al de siempre.

| Fichero | Que hace |
|---|---|
| `NS3FBMemExtension.mm` | servicio mach + `xpc_shmem_create`, y la entrada de la extension que no completa la peticion para seguir viva |
| `Info.plist` | `MachServices` con el nombre al que se conecta el app, punto de extension `share-services` |

Diseno completo, riesgos y lo que falta por verificar: `docs/RAM_EXTENSION_PLAN.md`.

## Aviso

Un `.appex` mal firmado invalida la instalacion entera del IPA, y `xpc_shmem` es
API no publica. No activar a ciegas sobre el build que hoy funciona.
