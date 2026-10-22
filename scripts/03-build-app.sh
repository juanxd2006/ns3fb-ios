#!/usr/bin/env bash
# Configura y compila la app para iOS arm64 SIN depender de CMakePresets.json.
#
# Por qué no se usa `cmake --preset`: `rexglue init` reescribe CMakePresets.json
# con sus plantillas genéricas (sin el preset iOS), y aunque 01-codegen.sh ya lo
# restaura, pasar todas las opciones explícitamente hace el build inmune a eso.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP="$ROOT/app"
SDK="${REXGLUE_SDK:-$ROOT/thirdparty/rexglue-sdk}"
BUILD="$APP/out/build/ios-arm64-release"

[ -f "$APP/CMakeLists.txt" ] || { echo "Falta app/CMakeLists.txt" >&2; exit 1; }
[ -d "$SDK/out/install/ios-arm64/lib/cmake/rexglue" ] || {
  echo "SDK iOS no instalado en $SDK/out/install/ios-arm64 - ejecuta 00-fetch-sdk.sh" >&2
  exit 1
}
[ -x "$SDK/out/mac-arm64/Release/rexglue" ] || {
  echo "Host tool no encontrado en $SDK/out/mac-arm64/Release/rexglue" >&2
  exit 1
}

echo "==> Configuring (iOS arm64, CMake $("cmake" --version | head -1 | awk '{print $3}'))"
cmake -S "$APP" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.3 \
  -DCMAKE_PREFIX_PATH="$SDK/out/install/ios-arm64" \
  -Drexglue_DIR="$SDK/out/install/ios-arm64/lib/cmake/rexglue" \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
  -DREXGLUE_HOST_TOOL="$SDK/out/mac-arm64/Release/rexglue" \
  -DNS3FB_IOS_SDK_LIB_DIR="$SDK/out/ios-arm64/Release"

echo "==> Building"
cmake --build "$BUILD" -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

APP_BUNDLE="$BUILD/ns3fb.app"
[ -d "$APP_BUNDLE" ] || { echo "No se genero $APP_BUNDLE" >&2; exit 1; }
echo "==> Bundle listo: $APP_BUNDLE"
ls -1 "$APP_BUNDLE/Frameworks" 2>/dev/null || true
