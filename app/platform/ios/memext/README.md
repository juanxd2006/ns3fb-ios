# ns3fb-mem — extension para el techo de RAM de iOS (NO se compila)

Esta carpeta contiene el andamiaje de la tecnica "RAM limit workaround":
una **NSExtension** que reserva memoria en su propio proceso y se la pasa al
app por XPC con `xpc_shmem`, para que esas paginas cuenten contra el
presupuesto de jetsam de la extension y no contra el del app.

**No esta en el build.** CMake no la mira y `scripts/make-ipa.sh` no la empaqueta.
El diseno completo, los pasos para activarla y los motivos para no subirla a
ciegas estan en `docs/RAM_EXTENSION_PLAN.md`.
