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
- Baja `framerate_limit` a 30 (ya viene así) y confirma que no está en 60.
- `clear_memory_page_state = false` (ya viene así). Si lo activas, se re-sube
  todo a la GPU cada frame.
- `async_shader_compilation = false` cuesta frames durante la compilación pero
  evita dibujos en blanco.
- El enemigo real en iPhone: el ancho de banda y los draw calls. Storm 3 hace
  muchos más que Minecraft 360. Si con todo optimizado no llega a 30 fps
  estables, no hay cvar que lo arregle.
- Añade un parche de spin-wait (el `#if 0` de `main.cpp`): si el juego espera a la
  GPU girando en vacío, un núcleo se calienta y el móvil hace throttling en
  minutos.

### 8. Audio entrecortado
Sube `audio_maxqframes` a 24–32. Baja si la latencia molesta.

## Cómo pedir ayuda

En una issue incluye: modelo de iPhone, versión de iOS, el log `ns3fb_*.log` más
reciente, el backtrace del crash report y qué cvars cambiaste.
