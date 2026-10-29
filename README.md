<div align="center">

<img src="assets/banner.svg" alt="NS3FB iOS — native Xbox 360 port for iPhone" width="100%">

<br>

**Naruto Shippuden: Ultimate Ninja Storm 3 Full Burst** running natively on iPhone.

Static PowerPC → ARM64 recompilation · Vulkan over Metal · ~30 fps

<br>

[![iOS](https://img.shields.io/badge/iOS-16.3%2B-000000?logo=apple&logoColor=white)](#-minimum-requirements)
[![Device](https://img.shields.io/badge/arm64-iPhone-555555)](#-minimum-requirements)
[![Engine](https://img.shields.io/badge/ReXGlue-static%20recomp-7c3aed)](https://github.com/rexglue/rexglue-sdk)
[![Graphics](https://img.shields.io/badge/Vulkan-MoltenVK-e11d48)](https://github.com/KhronosGroup/MoltenVK)
[![Status](https://img.shields.io/badge/status-playable-22c55e)](#-status)
[![License](https://img.shields.io/badge/license-MIT-3b82f6)](LICENSE)

[Status](#-status) · [Requirements](#-minimum-requirements) · [What you provide](#-what-you-provide) · [Building](#-building) · [Performance](#-performance) · [Debugging](#-debugging)

<sub><a href="README.es.md">Leer en español</a></sub>

</div>

---

> [!IMPORTANT]
> **This repository contains nothing from the game.** No executable, no data, no audio,
> no video, no textures. Only the toolchain that turns **your** copy into an iOS app.
> You supply `default.xex` from your own disc, and it is never committed here.

> [!WARNING]
> Fan project, non-commercial, not affiliated with Bandai Namco, CyberConnect2,
> VIZ Media or Microsoft. **Not publishable on the App Store.** Sideload only.

---

## 📱 Minimum requirements

| | Minimum | Recommended |
|---|---|---|
| **Device** | arm64 iPhone with iOS 16.3 (iPhone XS/XR or newer) | iPhone 12 or newer |
| **iOS** | 16.3 | 17 or newer |
| **RAM** | 4 GB — verified on iPhone 11 | 6 GB or more |
| **Free storage** | 10 GB | 15 GB (7 GB is game data) |
| **Signing** | Free Apple ID (expires every 7 days) | SideStore / AltStore / certificate |
| **Extras** | Your own NTSC-U `default.xex` | Bluetooth controller |

> [!NOTE]
> **Tested on iPhone 11 (A13).** Everything else is an honest extrapolation, not a
> guarantee. On 3 GB devices you may run out of address space unless your signing
> profile grants `extended-virtual-addressing` — untested with this game.

**Signing:** the `.ipa` ships unsigned. With a free Apple ID you re-sign every 7 days;
SideStore/AltStore renew it automatically.

---

## ✅ Status

Playable start to finish on iPhone 11 at a stable ~30 fps (960×540, GPU ~27 ms/frame).

| Part | Status |
|---|---|
| Boot, menus, character and stage select | ✅ |
| VS Battle, practice, HUD, particles, audio | ✅ |
| Ultimate jutsus, awakening ("beast mode"), end of match | ✅ |
| Results screen and Ryos screen | ✅ |
| Story mode | ✅ (mob-battle combo does not advance — see [v0.2.0](docs/RELEASE_NOTES_v0.2.0.md)) |
| Touch controls + Bluetooth controller (Xbox/PlayStation/MFi) | ✅ |
| Game Mode, custom app icon | ✅ |
| 1280×720 | ❌ ~18 fps — SDK ceiling, see [Performance](#-performance) |
| Minor visual artefacts | ⚠️ uncatalogued |

---

## 📦 What you provide

| Item | Detail | Committed? |
|---|---|---|
| `default.xex` | 11,218,944 bytes · SHA-1 `f7ad65e2…55e9f` · from your **NTSC-U** disc | ❌ never |
| `data/` + `datafb/` | ~7 GB of game data | ❌ never |
| App signing | SideStore, AltStore, Sideloadly or your own certificate | — |
| A Mac **or** a Codemagic account | Build only | — |

The hash is mandatory: the code is recompiled from one specific executable.
If it does not match, the port will not boot — that is not a config issue, it is a
different binary.

| Field | Value |
|---|---|
| Title ID | `4E4D085C` |
| Media ID | `2576927D` |
| `default.xex` SHA-1 | `f7ad65e26a00df6c29c9d34b291819593e455e9f` |
| `default.xex` size | 11,218,944 bytes |

```bash
extract-xiso -x "Naruto Storm 3 Full Burst.iso" -d app/game
shasum -a 1 app/game/default.xex
# f7ad65e26a00df6c29c9d34b291819593e455e9f
```

`app/game/` is in `.gitignore`: whatever you drop there will not be committed by accident.

---

## 🗂️ Repository layout

```
ns3fb-ios/
├── app/
│   ├── CMakeLists.txt              iOS target, embeds the SDK dylibs
│   ├── game/                       ← YOUR extraction goes here (git-ignored)
│   ├── generated/                  ← codegen output (git-ignored)
│   ├── platform/ios/               Info.plist, entitlements, icons, memext/
│   └── src/
│       ├── main.cpp                entry point
│       └── ns3fb_app.h             iOS paths, cvar defaults, markers
├── ci/
│   ├── patches.list                the 11 SDK patches, in order
│   ├── rexglue-*.patch             the patches themselves
│   ├── entrypoint_seeds.txt        193 functions the codegen cannot discover
│   └── game/                       ← empty: no executable travels here
├── scripts/
│   ├── 00-fetch-sdk.sh             clones the SDK, applies the iOS + ci/ patches
│   ├── 01-codegen.sh               recompiles YOUR default.xex to C++
│   ├── 02-seed-entrypoints.py      applies entrypoint_seeds.txt to the manifest
│   ├── 03-build-app.sh             builds the app (and generates the icons)
│   └── make-ipa.sh                 packages NS3FB.ipa
├── tools/xex/                      unxex.py and find_callback_thunks.py
├── docs/                           TROUBLESHOOTING, PERF_MATRIX, RAM_EXTENSION_PLAN
├── codemagic.yaml                  no-Mac CI (unsigned IPA)
└── LICENSE / CREDITS.md
```

---

## 🔨 Building

### Option A — on your Mac

Requires macOS 13+, Xcode 15+, `cmake`, `ninja`, `python3`.

```bash
chmod +x scripts/*.sh
cp -R /path/to/your/extraction/* app/game/   # default.xex + data/ + datafb/
./scripts/00-fetch-sdk.sh                    # ~30-40 min the first time
./scripts/01-codegen.sh                      # recompiles the .xex (~20-30 min)
./scripts/03-build-app.sh
./scripts/make-ipa.sh                        # unsigned NS3FB.ipa
```

### Option B — in the cloud, no Mac (Codemagic)

This repo ships `codemagic.yaml` with the `ios-unsigned` workflow. **A public repo
cannot build here**: CI needs `default.xex` in the working tree and that file is not
in the repo. The correct flow is to work on a **private copy**:

```bash
git clone https://github.com/juanxd2006/ns3fb-ios.git
cd ns3fb-ios
# GitHub: Settings → Danger Zone → Change visibility → Private

cp "/path/to/your/extraction/default.xex" ci/game/default.xex
git add -f ci/game/default.xex        # -f: it is git-ignored on purpose
git commit -m "Game executable for CI (private copy)"
git push
```

Then connect the repo in Codemagic (*Add application* → GitHub) and run `ios-unsigned`.

| Aspect | Reality |
|---|---|
| Cold build | 45–60 min (compiles the whole SDK) |
| Warm-cache build | 20–30 min |
| Touching any file under `ci/` | Invalidates the SDK cache → cold build |
| Artifact | unsigned `NS3FB.ipa` |
| `sdk-cache` workflow | Warms the SDK cache only (~2 min when warm) |

The log must contain `==> Cached ReXGlue SDK found, skipping build`.
If it does not, you are paying for a cold build again.

---

## 📲 Installing and signing

The `.ipa` ships **unsigned**:

- **SideStore / AltStore** — signs with your Apple ID, auto-renews every 7 days.
- **Sideloadly** — free Apple ID, expires after 7 days.
  *Advanced Options → Enable File Sharing*.
- **Your own developer certificate:**
  ```bash
  PROFILE=~/path/to/profile.mobileprovision ./scripts/sign-and-install.sh
  ```

> [!TIP]
> To make an **icon change** show up you must uninstall before reinstalling:
> iOS caches icons per bundle ID.

### Copying game data to the iPhone

1. Open the app once, then close it (it creates its folders).
2. Finder → your iPhone → **Files** → *On My iPhone / NS3FB*:

```
NS3FB/
├── game/          ← default.xex, data/, datafb/
├── userdata/      ← saves and logs (automatic)
└── ns3fb.toml     ← settings (automatic, editable)
```

Optional: `scripts/inject-game-files.sh` packs the data into the `.ipa`
(→ ~3-5 GB per install). If you are iterating on the app, keep the IPA data-free.

---

## ⚙️ Settings

`NS3FB/Documents/ns3fb.toml`, editable from the Files app; takes effect on restart.
This is the measured configuration:

```toml
video_mode_width = 960
video_mode_height = 540
present_effect = "cas"          # or "fsr"
present_cas_additional_sharpness = 0.4
msaa_override = 0
direct_host_resolve = false
execute_unclipped_draw_vs_on_cpu = true
anisotropic_override = 0
present_dither = false
clear_memory_page_state = false
vulkan_submit_on_primary_buffer_end = false
async_shader_compilation = false
readback_resolve = "none"
readback_memexport = false
texture_cache_memory_limit_soft = 320
texture_cache_memory_limit_hard = 640
texture_cache_memory_limit_rtt = 24
framerate_limit = 30            # the original is locked to 30
vsync = true
```

The original game is locked to 30 fps: at 60 it runs at double speed.

---

## 📊 Performance

iPhone 11 (A13), Metal HUD:

| Resolution | GPU (ms) | Compute (ms) | Fragment (ms) | FPS |
|---|---|---|---|---|
| 1280×720 | 54–55 | 28.5 | 19.0 | 18.2 |
| 960×540 | 22–27 | 10–11 | 11–13 | 30 |

At 720p, **51% of the frame** is the EDRAM dump compute shaders (~129 compute encoders
per frame): a fixed per-resolve cost, not tunable through configuration. That is why
720p is off the table unless someone writes direct resolve shaders (a separate project).

**Already measured and ruled out**, so nobody repeats it:

- `msaa_override = 1` does not reduce compute (28.05 → 26.39 ms) and **corrupts the image**.
- `direct_host_resolve` does not help: `TryResolveCopyDirectly()` ends in
  `return DumpRenderTargets(...)`. Same stub in D3D12.
- `execute_unclipped_draw_vs_on_cpu_with_scissor` does not move the compute cost.
- The `fsi` path is slower with this game. `keep_pass_open` gives ~7%, discarded.

---

## 🔍 Debugging

All diagnostics are log-based, no rebuild needed. In `NS3FB/Documents/`, just duplicate
and rename a file:

| Marker | Effect |
|---|---|
| `diag_on.txt` | Enables `NS3FB-*` (>200 lines/s, the game stops responding) |
| `msaa1.txt` / `msaa2.txt` / `msaa4.txt` | Forces `msaa_override` |
| `ztest_off.txt` / `blend_off.txt` | Diagnostic overrides |
| `mvk.txt` | `MVK_CONFIG_XXX=value` lines |

Markers override `ns3fb.toml`.

### `NS3FB-TRAP` — the remaining bug class

```
NS3FB-TRAP 0x825A7258 unregistered guest function, continuing as no-op
```

The game called a function the codegen never discovered (not in `.pdata`, only reachable
through runtime-built pointers) and it ran as a no-op. Typical symptoms: an animation
cutting short, a menu that will not advance, a screen stuck loading.

Fix: seed the address in `ci/entrypoint_seeds.txt` (one per line, `0xXXXXXXXX`, with a
comment recording date and symptom). **193 are already seeded**; that brought traps down
from 10 per session to 0–4.

```bash
python3 tools/xex/unxex.py app/game/default.xex /tmp/image.bin
python3 tools/xex/find_callback_thunks.py /tmp/image.bin
```

---

## 🧠 Memory and entitlements

`ns3fb.entitlements` requests `com.apple.developer.kernel.extended-virtual-addressing`:
the guest memory map needs ~4.5 GB of contiguous reservation. A free Apple ID does **not**
grant that entitlement, so on 3 GB devices you will see *"not enough free address space"*
unless you use TrollStore, a jailbreak or a paid account. Today the app uses ~1.33 GB of 3 GB.

`sustained-execution` and `increased-memory-limit` are documented and **commented out**:
with a free Apple ID, signing fails if you leave them enabled.

---

## ⚖️ Legal

- Fan project, non-commercial. Not affiliated with Bandai Namco, CyberConnect2,
  VIZ Media or Microsoft. *Naruto* and *Naruto Shippuden: Ultimate Ninja Storm 3 Full
  Burst* are trademarks and works of their respective owners.
- This repository **does not include or distribute** any game files. The code produced
  by the codegen is a derivative work of **your** `default.xex`: do not redistribute it.
- **Do not open issues asking for or sharing game files.** They are closed without reply.
- Not publishable on the App Store. Sideload / internal TestFlight only.
- Code license: [LICENSE](LICENSE) · Scope of that license: [NOTICE.md](NOTICE.md) · Third parties: [CREDITS.md](CREDITS.md)

## 🙏 Credits

This would not exist without **DevZer0D4Y** (iOS layer of the ReXGlue SDK), **ReXGlue**,
**Xenia**, **XenonRecomp**, **XenosRecomp** and **MoltenVK**.
Full detail in [CREDITS.md](CREDITS.md).

<div align="center">
<sub>Made by fans, for fans. Bring your own disc.</sub>
</div>
