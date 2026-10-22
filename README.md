# NS3FB iOS — Port nativo de *Naruto Shippuden: Ultimate Ninja Storm 3 Full Burst* para iPhone

Recompilación estática (PowerPC → ARM64) de la versión **Xbox 360 NTSC-U** corriendo
nativamente en iOS, con gráficos por **Vulkan sobre Metal (MoltenVK)**.

> **Este repositorio NO contiene archivos del juego.** Necesitas tu propio disco y
> tu propio `default.xex`. Nada del contenido de Bandai Namco / CyberConnect2 se
> distribuye aquí.

---

## ⚠️ Lee esto antes de empezar

Esto **no es un port terminado**. Es el esqueleto de proyecto listo para arrancar,
basado en la infraestructura que ya funciona en
[MCX360-EDITION](https://github.com/DevZer0D4Y/MCX360-EDITION) (Minecraft Xbox 360
en iPhone). Lo que viene hecho y lo que falta:

| Parte | Estado |
|---|---|
| Capa iOS del SDK ReXGlue (fibers arm64, memoria, threading, touch, Metal) | ✅ Ya existe — es el parche de MCX360 |
| Traducción PowerPC → C++ del `default.xex` | ✅ Automática (codegen de ReXGlue) |
| Build iOS (CMake + Xcode), empaquetado `.ipa`, sideload | ✅ Plantillas en este repo |
| Config del juego (entrypoint, setjmp/longjmp, función de arranque) | ⚠️ Hay que ajustarlo |
| Cobertura de shaders Xenos del Storm 3 | ⚠️ Hay que probarla |
| Parches HLE del kernel que el juego necesite | ⚠️ Se descubren ejecutando |
| Rendimiento / memoria en iPhone | ❌ Desconocido hasta probar |

**Requisitos reales:** un Mac con Xcode (no hay forma de compilar/firmar iOS sin
Apple), tu disco de Storm 3, y paciencia. Minecraft 360 es un juego ligero; Storm 3
mueve muchísimos más draw calls y EDRAM, así que el rendimiento es la incógnita
grande. Puede que no llegue a 30 FPS jugables. No hay garantía.

---

## Estructura

```
ns3fb-ios/
├── app/
│   ├── CMakeLists.txt          # target iOS, embebe dylibs del SDK
│   ├── CMakePresets.json       # preset ios-arm64-release (requiere macOS)
│   ├── game/                   # ← TUS archivos del juego van aquí (vacío)
│   ├── generated/              # ← lo crea el codegen (no se versiona)
│   ├── platform/ios/           # Info.plist + entitlements
│   └── src/
│       ├── main.cpp            # REX_DEFINE_APP + parches de funciones
│       └── ns3fb_app.h         # hooks iOS: rutas, cvars, touch
├── scripts/
│   ├── 00-fetch-sdk.sh         # clona rexglue-sdk y aplica el parche iOS
│   ├── 01-codegen.sh           # recompila TU default.xex a C++
│   ├── make-ipa.sh             # empaqueta el .ipa para sideload
│   └── sign-and-install.sh     # firma con tu certificado e instala
└── docs/
    └── TROUBLESHOOTING.md
├── ci/game/                    # ← default.xex para el build en la nube
└── .github/workflows/          # build automático en macOS runner
```

---

## Paso 0 — Requisitos

| Cosa | Detalle |
|---|---|
| Mac | macOS 13+, Xcode 15+ con las Command Line Tools |
| Homebrew | `cmake`, `ninja`, `python3` |
| Disco del juego | Storm 3 Full Burst **NTSC-U** |
| iPhone | iOS 16+, arm64 |
| Firma | Apple ID gratis (7 días por firma) o cuenta de desarrollador |

**¿Sin Mac?** Salta a la **Opción B** (GitHub Actions) más abajo: compila el `.ipa`
en la nube con un runner macOS.

**El hash es obligatorio.** El código se recompila desde un ejecutable concreto:

| Campo | Valor |
|---|---|
| Title ID | `4E4D085C` |
| Media ID | `2576927D` |
| Versión | `0.0.0.9` |
| `default.xex` SHA-1 | `f7ad65e26a00df6c29c9d34b291819593e455e9f` |
| `default.xex` tamaño | 11 218 944 bytes |

```bash
shasum -a 1 default.xex
# f7ad65e26a00df6c29c9d34b291819593e455e9f  default.xex
```

Si el hash no coincide, el port **no arranca**. No es un problema de configuración:
es otro binario.

## Paso 1 — Prepara los archivos del juego

Antes de nada, si acabas de descomprimir el proyecto:

```bash
chmod +x scripts/*.sh
```

1. Haz ISO de tu disco y extrae con [`extract-xiso`](https://github.com/XboxDev/extract-xiso):
   ```bash
   extract-xiso -x "Naruto Storm 3 Full Burst.iso" -d app/game
   ```
2. La carpeta debe quedar así (todo dentro, sin subcarpeta extra):
   ```
   app/game/
   ├── default.xex
   ├── nxeart
   ├── AvatarAssetPack
   ├── data/
   └── datafb/
   ```

## Paso 2 — SDK ReXGlue parcheado para iOS

```bash
./scripts/00-fetch-sdk.sh
```

Clona `rexglue/rexglue-sdk`, le aplica el parche de iOS de
[DevZer0D4Y](https://github.com/DevZer0D4Y/MCX360-EDITION) (`sdk/rexglue-sdk-ios.patch`)
y compila dos cosas: los host tools para macOS y las dylibs para iOS.

Exporta la variable antes de compilar el juego:

```bash
export REXGLUE_SDK="$PWD/thirdparty/rexglue-sdk"
```

Ese parche es lo valioso del proyecto de Minecraft: añade fibers `aarch64.S`,
`memory_posix`/`threading_posix` para iOS, `touch_controls_ios.mm`,
`surface_ios`, toasts de logros y ajustes de codegen. Es agnóstico al juego.

> En teoría el codegen de CPU (Paso 3) también corre en Linux x86-64, pero el
> build iOS y la firma exigen macOS. No pierdas tiempo intentándolo en Windows.

## Paso 3 — Recompilar el ejecutable del juego

```bash
./scripts/01-codegen.sh
```

Genera en `app/generated/default/`:

- `ns3fb_register.cpp` — ~50 000 registros de punteros a función del binario
- `ns3fb_init.h`, `sources.cmake` — punto de entrada e includes
- `app/ns3fb_manifest.toml` — la configuración del proyecto

El manifest es donde está el trabajo real. Empieza genérico y se corrige iterando:

| Campo | Qué hacer con Storm 3 |
|---|---|
| `setjmp_address` / `longjmp_address` | Localízalos. Sin ellos, `longjmp` se recompila como una llamada normal que **retorna**, corrompe `r1` y revienta el stack |
| `[entrypoint.functions]` | El analizador irá reportando funciones no descubiertas (ramas indirectas, tablas en runtime); se añaden aquí |
| `[project] name` | Debe ser `ns3fb` para que coincida con los targets de `CMakeLists.txt` |

Nada de esto se puede rellenar a ciegas: cada valor sale de ejecutar y leer el log.

## Paso 4 — Compilar la app

```bash
cd app
cmake --preset ios-arm64-release
cmake --build --preset ios-arm64-release
```

Produce `app/out/build/ios-arm64-release/ns3fb.app` con
`librexruntime.dylib`, `librexgpu-xenos.dylib` y `libMoltenVK.dylib` embebidas en
`Frameworks/`.

## Paso 5 — Empaquetar y instalar

```bash
./scripts/make-ipa.sh          # produce NS3FB.ipa sin firmar
```

Instala con **AltStore / SideStore / Sideloadly / TrollStore**. Sideloadly necesita
*Advanced Options → Enable File Sharing*.

Si tienes perfil de desarrollador:

```bash
PROFILE=~/ruta/al.mobileprovision ./scripts/sign-and-install.sh
```

## Opción B — compilar en la nube (GitHub Actions, sin Mac)

El repo incluye `.github/workflows/build-ios.yml`, que hace los pasos 2 a 5 en un
runner `macos-14` (Apple silicon) y deja el `.ipa` como artefacto descargable.

**Lo único que necesitas subir es `ci/game/default.xex`** (11 MB). Los ~7 GB de
`data/` y `datafb/` no se usan para compilar: van después, dentro del `.ipa` o
copiados con la app Archivos.

```bash
# repo PRIVADO: es tu archivo con copyright
cp "/ruta/a/tu/extraccion/default.xex" ci/game/default.xex
git add ci/game/default.xex .github ci/game/README.md
git commit -m "CI build"
git push
```

Luego: pestaña **Actions** → *Build iOS IPA* → **Run workflow**.

### Qué esperar del CI

| Aspecto | Realidad |
|---|---|
| Primera ejecución | 1–3 h: compila el SDK entero, hace codegen y compila decenas de miles de funciones recompiladas |
| Ejecuciones siguientes | Bastante más rápidas: SDK y codegen van cacheados (`thirdparty/` y `app/generated`) |
| Límite duro | 6 h por job; el workflow corta a los 350 min |
| Minutos macOS | Se facturan **×10**. El plan gratuito da 2 000 min/mes ≈ **200 min de macOS**, así que la primera build puede no caber |
| Artefacto | `NS3FB-ipa` → `NS3FB.ipa` sin firmar, listo para Sideloadly |
| Si falla | Se sube `ns3fb-diagnostics` con el manifest, `build.log` y logs del codegen |

El runner tiene ~14 GB de disco; el workflow borra los árboles de build del SDK
a propósito antes del codegen, porque si no se queda sin espacio.

> Para recalcular el codegen: *Run workflow* con **clean_codegen** marcado.

## Paso 5b — Meter el juego dentro del IPA (opcional)

Así no hay que copiar nada a mano en el teléfono: los archivos van dentro del
bundle y la app los lee de `NS3FB.app/game/`.

```bash
./scripts/inject-game-files.sh NS3FB.ipa ./game NS3FB-full.ipa
```

`ns3fb_app.h` busca primero en `Documents/game` y, si ahí no hay `default.xex`,
usa `<bundle>/game`. Documentos gana siempre, así que puedes sobrescribir los
datos con la app Archivos sin reinstalar.

**Coste:** el `.ipa` pasa a ~3–5 GB comprimido. Cada instalación transfiere todo
otra vez, y durante la instalación iOS necesita cerca del doble de espacio libre.
Si vas a iterar sobre la app, deja el `.ipa` sin datos y usa la app Archivos.

## Paso 6 — Copiar el juego al iPhone

1. Abre la app una vez y ciérrala (crea las carpetas).
2. Finder (Mac) → tu iPhone → **Archivos**, o iTunes en Windows.
3. Dentro de *En mi iPhone / NS3FB*, deja:
   ```
   NS3FB/
   ├── game/            ← todo el contenido del disco
   │   ├── default.xex
   │   ├── data/
   │   └── datafb/
   ├── userdata/        ← saves y logs (automático)
   └── ns3fb.toml       ← ajustes (automático, editable en Archivos)
   ```

Si usaste `inject-game-files.sh`, este paso es opcional: solo hace falta para
cambiar o actualizar los datos del juego.

## Paso 7 — Jugar

Empareja un mando Bluetooth (Xbox/PlayStation/MFi) en Ajustes → Bluetooth y abre
la app. **Hay controles táctiles** — la capa de touch del parche iOS los activa
con `touch_controls = "auto"`.

---

## Ajustes (`ns3fb.toml`)

Se edita desde la app **Archivos**; los cambios aplican al reiniciar.

| Clave | Default | Qué hace |
|---|---|---|
| `gpu_plugin` | `xenos` | Backend gráfico. Vacío = sin gráficos |
| `license_mask` | `1` | Bit 0 = título comprado |
| `present_letterbox` | `false` | `false` estira a 19.5:9; `true` respeta 16:9 con barras |
| `render_target_path_vulkan` | `fbo` | Render targets del host (MSAA por hardware). `fsi` emula EDRAM en el pixel shader: más lento y **rompe la cobertura de samples en MoltenVK** |
| `fsi_sample_mask_from_sample_id` | `true` | MoltenVK no reporta cobertura del sample 0; hay que derivarla de `gl_SampleID` |
| `framerate_limit` | `30` | El juego original está atado a 30 (a 60 corre al doble de velocidad) |
| `clear_memory_page_state` | `false` | Si no, se re-sube todo a la GPU cada frame |
| `vulkan_submit_on_primary_buffer_end` | `false` | Un submit por frame en vez de uno por buffer |
| `vulkan_allow_present_mode_immediate/mailbox/fifo_relaxed` | `false` | Solo FIFO: frames parejos |
| `async_shader_compilation` | `false` | Evita que se salten dibujos con pipeline sin compilar |
| `execute_unclipped_draw_vs_on_cpu` | `true` | Necesario para clears con scissor infinito |
| `audio_maxqframes` | `16` | ~85 ms de colchón; menos da audio entrecortado |
| `touch_controls` | `auto` | `auto` / `on` / `off`; `touch_controls_opacity` 0.1–1.0 |

---

## El blocker que tienes que conocer: memoria

El `ns3fb.entitlements` pide:

```xml
<key>com.apple.developer.kernel.extended-virtual-addressing</key><true/>
```

El mapa de memoria del invitado necesita una reserva contigua de ~4.5 GB. En
dispositivos con 3 GB de RAM solo cabe con direccionamiento extendido, y **ese
entitlement no lo concede un Apple ID gratis**. Se queda en:
TrollStore, jailbreak o cuenta de desarrollador de pago con la capability activada.
Con Apple ID gratis en un iPhone de 3 GB verás *"not enough free address space"*.

En iPhone de 6/8 GB puede colar sin el entitlement, pero nadie lo ha probado con
Storm 3.

---

## Créditos y licencias

Ver [CREDITS.md](CREDITS.md). Resumen: el mérito de que esto sea posible es de
**DevZer0D4Y** (capa iOS del SDK), **ReXGlue**, **Xenia** y **MoltenVK**.

Proyecto de fans, sin ánimo de lucro, sin relación con Bandai Namco, CyberConnect2,
Ubisoft, VIZ Media o Microsoft.
