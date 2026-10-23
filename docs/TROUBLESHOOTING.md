# Solución de problemas

El juego no va a arrancar a la primera. Así se depura, en orden.

## Dónde mirar

| Fuente | Qué contiene |
|---|---|
| `NS3FB/userdata/logs/` en la app Archivos | El log del runtime en el dispositivo |
| Consola de Xcode (Devices → Open Console) | Log en vivo + crash reports |
| Salida del codegen | Funciones no resueltas, warnings de instrucciones |
| `~/Library/Logs/DiagnosticReports/` | Crash reports con backtrace simbólico |

El sistema de logs del SDK escribe **también** en `userdata/logs/`, así que si la
app arranca y muere ya tienes algo que leer. Si ni siquiera llega a escribir,
el fallo es de firma, entitlements o dyld (mira la consola).

## Fallos por fase

### 1. No instala / no abre nada
- Firma caducada (Apple ID gratis = 7 días). Re-firma con AltStore/SideStore.
- `NS3FB_IOS_SDK_LIB_DIR` mal: las tres dylibs (`librexruntime`, `librexgpu-xenos`,
  `libMoltenVK`) tienen que estar en `ns3fb.app/Frameworks/`. Si falta una, dyld
  mata el proceso antes de main.
- Bundle ID sin provisionar: usa uno que tu perfil cubra.

### 2. Abre y cierra inmediatamente
- `game/default.xex` no está directamente dentro de `game/` (no dentro de otra
  subcarpeta).
- Hash del xex distinto.
- `dyld: Library not loaded` → dylib sin firmar. Re-ejecuta `make-ipa.sh`.

### 3. "not enough free address space" al arrancar
Es el entitlement `com.apple.developer.kernel.extended-virtual-addressing`. Sin
él, el mapa de memoria del invitado (~4.5 GB contiguos) no cabe en un iPhone de
3 GB. Solo lo conceden TrollStore, jailbreak o cuenta de pago. En un iPhone de
6/8 GB puede funcionar sin él.

### 4. Tela negra o cuelgue en el primer frame
Casi siempre es el entrypoint del manifest:

- El codegen arranca el análisis en `mainCRTStartup`; si el juego entra por otro
  lado, se queda colgado o revienta. Busca el punto de entrada real en el xex.
- `setjmp_address` / `longjmp_address` mal puestos o ausentes: `longjmp` se
  recompila como una llamada normal que retorna, el epílogo ya lo omitió el
  compilador, y `r1` + registros callee-saved quedan corruptos. Síntoma típico:
  crash al cargar la primera textura PNG/JPEG o al inicializar el filesystem.

### 5. Crashes con "invalid or unregistered function"
El juego saltó a una dirección que el analizador no descubrió. Es lo normal en
las primeras ejecuciones:

1. Apunta la dirección del log.
2. Añádela a `[entrypoint.functions]` del `ns3fb_manifest.toml`:
   ```toml
   0x82ABCDEF = { name = "sub_82ABCDEF" }
   ```
3. Re-ejecuta `./scripts/01-codegen.sh` y prueba otra vez.

Atajo: `[entrypoint.functions]` también acepta los punteros a función que el
escáner de secciones de datos encuentra (`--scan-code-pointers-to`). En el
proyecto de Minecraft eso resolvió 35 800 vtables y callbacks de golpe; sin ello
aparecen como traps uno por ejecución.

### 6. Gráficos raros, texturas negras, bandas
- Prueba `render_target_path_vulkan = "fsi"` y `"fbo"` alternando: algunos
  efectos (EDRAM, MSAA) se comportan distinto en cada ruta.
- `fsi_sample_mask_from_sample_id = true` es obligatorio en MoltenVK si usas
  `fsi`; sin ello la cobertura del sample 0 no existe y cada dos píxeles se queda
  con el frame anterior.
- Shaders que XenosRecomp no cubre: mira los warnings del traductor y las
  pipelines que fallan al compilar en el log.

### 7. Va a tirones / se calienta

#### 7.1 Lo primero es saber quién trabaja: GPU o CPU

Crea en `Documents/` (app Archivos) el archivo vacío **`mvk_perf_log.txt`**. Al
arrancar, MoltenVK escribe en el log, por frame: `FPS`, `GPU`, `Frame interval`,
y el desglose `Vertex / Fragment / Compute / Blit GPU`, además de
`Command Buffer CPU`.

| Lo que veas | Veredicto | Qué tocar |
|---|---|---|
| GPU ≈ frame interval | Limitado por GPU | sección 7.2 |
| `Command Buffer CPU` ≈ frame interval | CPU esperando a la GPU | es lo mismo, consecuencia |
| GPU y CPU muy por debajo del frame | Nadie trabaja | sección 7.3 |

Medición real de referencia (iPhone 11 / A13): **pantalla negra, 30,18 ms de GPU**
con 13,3 ms de compute, 12,5 de fragment y 1,95 de blit. Si una pantalla en negro
cuesta 30 ms, el coste no está en dibujar: está en el camino de render targets.

#### 7.2 El render pass partido (la causa gorda en Storm 3)

En las GPU Apple (TBDR) el renderizado ocurre por tiles en memoria on-chip.
**Cerrar un render pass obliga a volcar esos tiles a memoria y recargarlos al
abrirlo de nuevo.** Xenia cierra el pass en cada barrera pendiente salvo que se
le diga lo contrario, y Storm 3 genera muchas.

El parche `ci/rexglue-keep-pass-open-v2.patch` lo evita. **Hay que activarlo en
el dispositivo**: crear el archivo vacío `Documents/keep_pass_open.txt`. Sin ese
archivo el comportamiento es el de siempre.

Cómo se comprueba: el log imprime cada 300 cierres de pass

```
NS3FB-PASS ends=… begins=… barrier_ends=… kept_open=… barriers_in_pass=… split_by_attachment=…
```

- `barrier_ends` alto frente a `ends` → la mayoría de los cierres son por barrera.
- `kept_open` **debe subir** con el marcador puesto. Si se queda en 0, el gate no
  está dejando pasar nada y el parche no está haciendo su trabajo.
- `split_by_attachment` cuenta los cierres inevitables: barreras que tocan un
  adjunto del pase (transición a/desde layout de attachment). Esos son legales e
  inevitables.

Referencia medida sin el parche (iPhone 11, menú): 722 pass cerrados/s y 2.582
barreras/s, es decir **~35–48 render passes cerrados por frame y ~110–170
barreras por frame**, con `kept_open = 0`.

Si al activarlo aparecen artefactos o basura gráfica, el gate es demasiado
permisivo: quita el marcador y avisa. No se pierde nada, vuelve al
comportamiento anterior sin recompilar.

#### 7.3 Los milisegundos que no aparecen en ningún contador

Si `GPU` y `Command Buffer CPU` suman bastante menos que `Frame interval`, el
invitado (el juego recompilado) está esperando. El sospechoso número uno es el
spin-wait de Direct3D: en la consola `db16cyc` pausaba el hilo de hardware, y
recompilado no hace nada, así que un núcleo gira al 100 %, calienta y el móvil
hace throttling. El parche está escrito y desactivado en `app/src/main.cpp`
(`#if 0`) porque necesita la dirección de la función, que se saca con
`rexglue analyze --scan-calls` sobre tu `default.xex`.

#### 7.4 Otros ajustes

- `framerate_limit = 30` (ya viene así); a 60 la lógica del juego corre al doble.
- `clear_memory_page_state = false` (ya viene así). Si lo activas, se re-sube
  todo a la GPU cada frame.
- `async_shader_compilation` está en `false` a propósito: con `true` los frames
  que usan un pipeline de relleno **no se presentan** y salen en negro. En el log
  se ve como `Skipping Vulkan frame presentation due to async placeholder draw
  usage in this frame`. Para el A/B sin recompilar: `Documents/async_on.txt`.
  La solución de verdad es precompilar las pipelines al cargar, no saltárselas.
- El enemigo real en iPhone: ancho de banda y draw calls. Storm 3 hace muchos más
  que Minecraft 360. Si con todo optimizado no llega a 30 fps estables, no hay
  cvar que lo arregle.

### 8. Audio entrecortado
Sube `audio_maxqframes` a 24–32. Baja si la latencia molesta.

## Cómo pedir ayuda

En una issue incluye: modelo de iPhone, versión de iOS, el log `ns3fb_*.log` más
reciente, el backtrace del crash report y qué cvars cambiaste.
