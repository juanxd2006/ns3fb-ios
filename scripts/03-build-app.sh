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

# --- Icono de la app --------------------------------------------------------
# El maestro vive en el repo como base64 porque la API que usa este proyecto
# solo acepta texto. Aqui se decodifica y se generan con sips los tamanos que
# pide CFBundleIcons; CMake los recoge del directorio icons/ al configurar.
ICONS="$APP/platform/ios/icons"
ICON_B64="$ICONS/ns3fb-icon-256.png.b64"
if [ -f "$ICON_B64" ]; then
  MASTER="$ICONS/.master.png.bin"
  tr -d '\n' < "$ICON_B64" | base64 --decode > "$MASTER" 2>/dev/null \
    || tr -d '\n' < "$ICON_B64" | base64 -D > "$MASTER"
  rm -f "$ICONS"/AppIcon*.png
  if command -v sips >/dev/null 2>&1; then
    make_icon() { sips -z "$1" "$1" "$MASTER" --out "$ICONS/$2" >/dev/null 2>&1; }
    make_icon 29  AppIcon29x29.png
    make_icon 58  AppIcon29x29@2x.png
    make_icon 87  AppIcon29x29@3x.png
    make_icon 40  AppIcon40x40.png
    make_icon 80  AppIcon40x40@2x.png
    make_icon 120 AppIcon40x40@3x.png
    make_icon 60  AppIcon60x60.png
    make_icon 120 AppIcon60x60@2x.png
    make_icon 180 AppIcon60x60@3x.png
    make_icon 76  AppIcon76x76.png
    make_icon 152 AppIcon76x76@2x.png
    make_icon 167 AppIcon83.5x83.5@2x.png
    echo "==> Iconos generados: $(ls -1 "$ICONS"/AppIcon*.png | wc -l | tr -d ' ')"
  else
    echo "==> aviso: sips no disponible; la app saldra con el icono por defecto" >&2
  fi
fi

# Argumentos extra de CMake, para poder activar opciones experimentales desde
# Codemagic sin tocar este script. Ejemplo:
#   NS3FB_CMAKE_ARGS=-DNS3FB_MEM_EXTENSION=ON ./scripts/03-build-app.sh
# Sin la variable, el build es exactamente el de siempre.
EXTRA_CMAKE_ARGS="${NS3FB_CMAKE_ARGS:-}"
[ -n "$EXTRA_CMAKE_ARGS" ] && echo "==> Extra CMake args: $EXTRA_CMAKE_ARGS"

echo "==> Configuring (iOS arm64, CMake $("cmake" --version | head -1 | awk '{print $3}'))"
cmake -S "$APP" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=16.3 \
  -DCMAKE_PREFIX_PATH="$SDK/out/install/ios-arm64" \
  -Drexglue_DIR="$SDK/out/install/ios-arm64/lib/cmake/rexglue" \
  $EXTRA_CMAKE_ARGS \
  -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
  -DREXGLUE_HOST_TOOL="$SDK/out/mac-arm64/Release/rexglue" \
  -DNS3FB_IOS_SDK_LIB_DIR="$SDK/out/ios-arm64/Release"

echo "==> Building"
cmake --build "$BUILD" -j "$(sysctl -n hw.ncpu 2>/dev/null || nproc)"

APP_BUNDLE="$BUILD/ns3fb.app"
[ -d "$APP_BUNDLE" ] || { echo "No se genero $APP_BUNDLE" >&2; exit 1; }
echo "==> Bundle listo: $APP_BUNDLE"
ls -1 "$APP_BUNDLE/Frameworks" 2>/dev/null || true
