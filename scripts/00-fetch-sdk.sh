#!/usr/bin/env bash
# Fetch rexglue-sdk, apply the iOS platform patch and build it for macOS (host
# tools) and for iOS (device dylibs).
#
# The iOS layer (aarch64 fibers, POSIX memory/threading for iOS, touch controls,
# iOS surface, achievement toasts, codegen tweaks) comes from DevZer0D4Y's patch,
# published with MCX360-EDITION under BSD-3-Clause. We download it instead of
# vendoring it so credit and updates stay with the original.
#
# Requires: macOS, Xcode CLT, cmake >= 3.25, ninja, git, python3.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SDK="${REXGLUE_SDK:-$ROOT/thirdparty/rexglue-sdk}"
PATCH="${PATCH:-$ROOT/thirdparty/rexglue-sdk-ios.patch}"
PATCH_URL="https://raw.githubusercontent.com/DevZer0D4Y/MCX360-EDITION/main/sdk/rexglue-sdk-ios.patch"

[ "$(uname -s)" = "Darwin" ] || {
  echo "This script needs macOS: the iOS target requires Apple's SDK and clang." >&2
  exit 1
}
command -v cmake >/dev/null || { echo "cmake not found (brew install cmake)" >&2; exit 1; }
command -v ninja >/dev/null || { echo "ninja not found (brew install ninja)" >&2; exit 1; }

mkdir -p "$ROOT/thirdparty"

# La cache de CI restaura thirdparty/rexglue-sdk/out pero NO el .git ni el
# codigo fuente. En ese caso hay que clonar igualmente, pero sin perder el out/
# cacheado: se aparta, se clona limpio y se devuelve a su sitio.
CACHE_OUT=""
if [ -d "$SDK" ] && [ ! -d "$SDK/.git" ]; then
  if [ -d "$SDK/out" ]; then
    CACHE_OUT="$(mktemp -d)/out"
    echo "==> Cache-only SDK directory found; preserving out/ and re-cloning sources"
    mv "$SDK/out" "$CACHE_OUT"
  fi
  rm -rf "$SDK"
fi

if [ ! -d "$SDK/.git" ]; then
  echo "==> Cloning rexglue-sdk"
  git clone --recursive https://github.com/rexglue/rexglue-sdk.git "$SDK"
fi

if [ -n "$CACHE_OUT" ] && [ ! -d "$SDK/out" ]; then
  mv "$CACHE_OUT" "$SDK/out"
  echo "==> Restored cached out/ into the fresh clone"
fi

# --- Version de MoltenVK -----------------------------------------------------
# El SDK fija un commit concreto de thirdparty/moltenvk (1.4.1 en el momento de
# escribir esto). Un punto release posterior trae correcciones del traductor
# SPIR-V -> MSL que pueden arreglar el fallo que perseguimos: los shaders de la
# ruta fsi (fragment shader interlock) no compilan y el servicio XPC del
# compilador de Metal se cae con XPC_ERROR_CONNECTION_INTERRUPTED, con lo que
# despues fallan TODAS las pipelines del frame.
#
# MVK_VERSION=vX.Y.Z lo sube sin tocar el SDK. Vacio = respetar el commit del SDK.
# Al cambiar la version cambia la huella de la cache, asi que se recompila.
MVK_VERSION="${MVK_VERSION:-v1.4.2}"
MVK_DIR="$SDK/thirdparty/moltenvk"
if [ -n "$MVK_VERSION" ] && [ -e "$MVK_DIR/.git" ]; then
  CURRENT_MVK="$(git -C "$MVK_DIR" describe --tags --always 2>/dev/null || echo unknown)"
  if [ "$CURRENT_MVK" != "$MVK_VERSION" ]; then
    echo "==> MoltenVK: $CURRENT_MVK -> $MVK_VERSION"
    if ! git -C "$MVK_DIR" fetch -q origin "refs/tags/$MVK_VERSION:refs/tags/$MVK_VERSION" 2>/dev/null; then
      git -C "$MVK_DIR" fetch -q --tags origin
    fi
    git -C "$MVK_DIR" checkout -q "tags/$MVK_VERSION"
    # SPIRV-Cross, SPIRV-Tools y Vulkan-Headers internos de MoltenVK van fijados
    # por su ExternalRevisions/. Sin esto se compilaria 1.4.2 contra el
    # SPIRV-Cross de 1.4.1, que es justo la pieza que traduce los shaders.
    git -C "$MVK_DIR" submodule update --init --recursive -q
    echo "==> MoltenVK now at $(git -C "$MVK_DIR" describe --tags --always)"
  else
    echo "==> MoltenVK already at $MVK_VERSION"
  fi
fi

if [ ! -f "$PATCH" ]; then
  echo "==> Downloading the iOS patch"
  curl -fsSL "$PATCH_URL" -o "$PATCH"
fi

if git -C "$SDK" apply --check "$PATCH" 2>/dev/null; then
  echo "==> Applying the iOS patch"
  git -C "$SDK" apply "$PATCH"
elif git -C "$SDK" apply --reverse --check "$PATCH" 2>/dev/null; then
  echo "==> iOS patch already applied, skipping"
else
  echo "Patch does not apply cleanly. rexglue-sdk has probably moved since the" >&2
  echo "patch was written; rebase it by hand against the new tree, then re-run." >&2
  exit 1
fi

# Parches opcionales de nuestro repo (diagnostico y arreglos de kernel). Se
# aplican todos los ci/rexglue-*.patch que existan, en orden alfabetico. Para
# desactivar uno, basta con borrar el archivo del repo.
TRAP_APPLIED=0
EXTRA_FINGERPRINT=""
PATCH_LIST="$ROOT/ci/patches.list"
[ -f "$PATCH_LIST" ] || { echo "falta $PATCH_LIST" >&2; exit 1; }
for name in $(grep -v '^#' "$PATCH_LIST" | tr -d ' \r'); do
  extra="$ROOT/ci/$name"
  [ -e "$extra" ] || { echo "parche listado pero ausente: $name" >&2; exit 1; }
  if git -C "$SDK" apply --check "$extra" 2>/dev/null; then
    echo "==> Applying $name"
    git -C "$SDK" apply "$extra"
  elif git -C "$SDK" apply --reverse --check "$extra" 2>/dev/null; then
    echo "==> $name already applied"
  else
    echo "$name does not apply against this SDK revision." >&2
    echo "Rebase it or remove it from ci/ and re-run." >&2
    exit 1
  fi
  case "$name" in *trap-continue*) TRAP_APPLIED=1 ;; esac
  EXTRA_FINGERPRINT="$EXTRA_FINGERPRINT$name:$(shasum -a 256 "$extra" | awk '{print $1}');"
done

# Huella de los parches + version del SDK. Si cambia, la cache de out/ no sirve
# y hay que recompilar: sin esto el guard reutilizaria dylibs sin los parches.
SDK_REV="$(git -C "$SDK" rev-parse HEAD 2>/dev/null || echo unknown)"
FINGERPRINT="$(cat "$PATCH" 2>/dev/null | shasum -a 256 | awk '{print $1}')-$SDK_REV-$TRAP_APPLIED-mvk-${MVK_VERSION:-sdk}-$EXTRA_FINGERPRINT"
STAMP="$SDK/out/.build-fingerprint"

# `cmake --preset` resolves CMakePresets.json from the *current working
# directory*, not from -S. Running these from the repo root configures the right
# tree and then dies with "Could not read presets", so enter the SDK first.
cd "$SDK"

# Fast path: actions/cache restored thirdparty/rexglue-sdk/out, so the host
# tools and the iOS dylibs are already built. Skip configure+build entirely -
# ninja judges by mtime and a restored tree would otherwise rebuild everything.
if [ "${REXGLUE_SDK_FORCE:-0}" != "1" ] \
   && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$FINGERPRINT" ] \
   && [ -x "$SDK/out/mac-arm64/Release/rexglue" ] \
   && [ -f "$SDK/out/ios-arm64/Release/librexruntime.dylib" ] \
   && [ -f "$SDK/out/ios-arm64/Release/librexgpu-xenos.dylib" ] \
   && [ -f "$SDK/out/ios-arm64/Release/libMoltenVK.dylib" ] \
   && [ -d "$SDK/out/install/ios-arm64/lib/cmake/rexglue" ]; then
  echo "==> Cached ReXGlue SDK found, skipping build"
  echo "    host tools: $("$SDK/out/mac-arm64/Release/rexglue" --version 2>/dev/null | head -1)"
  ls -1 "$SDK/out/ios-arm64/Release"/*.dylib
  echo
  echo "Done. Export this before building the game:"
  echo "  export REXGLUE_SDK=\"$SDK\""
  exit 0
fi

echo "==> Building host tools (macOS arm64)"
# The host tools are only the codegen CLI: profiling and perf counters are dead
# weight that add minutes to every clean build.
cmake --preset mac-arm64 \
  -DREXGLUE_ENABLE_TRACY=OFF \
  -DREXGLUE_ENABLE_PERF_COUNTERS=OFF
cmake --build --preset mac-arm64-release -j "$(sysctl -n hw.ncpu)"
cmake --install "$SDK/out/build/mac-arm64" --config Release

# iOS 16.0 is too low: Apple's libc++ only exposes std::to_chars for floating
# point (used by std::format <- spdlog <- Vulkan headers) from iOS 16.3, and
# clang hard-errors on it below that. Raise the deployment target in the patched
# preset before configuring.
perl -pi -e 's/"CMAKE_OSX_DEPLOYMENT_TARGET": "16\.0"/"CMAKE_OSX_DEPLOYMENT_TARGET": "16.3"/' \
  "$SDK/CMakePresets.json"
grep -q '"CMAKE_OSX_DEPLOYMENT_TARGET": "16.3"' "$SDK/CMakePresets.json" || {
  echo "could not raise CMAKE_OSX_DEPLOYMENT_TARGET to 16.3 in $SDK/CMakePresets.json" >&2
  exit 1
}

echo "==> Building iOS device dylibs (arm64)"
cmake --preset ios-arm64
cmake --build --preset ios-arm64-release -j "$(sysctl -n hw.ncpu)"
cmake --install "$SDK/out/build/ios-arm64" --config Release

mkdir -p "$SDK/out"
printf '%s' "$FINGERPRINT" > "$STAMP"

echo
echo "Done. Export this before building the game:"
echo "  export REXGLUE_SDK=\"$SDK\""
ls -1 "$SDK/out/ios-arm64/Release"/*.dylib 2>/dev/null || \
  echo "(warning: no dylibs in out/ios-arm64/Release - check the build log)"
