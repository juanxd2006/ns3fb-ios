#!/usr/bin/env bash
# Compila metal-tile-resolve y produce MetalSpike.ipa (sin firmar).
#
# No depende del SDK de ReXGlue ni de CMake: es un solo .mm compilado con
# clang de Xcode y empaquetado a mano, asi que el build son ~1 minuto en vez de
# los 30-45 del port.
#
# Uso:  ./spike/build-ipa.sh
# Sale: MetalSpike.ipa en la raiz del repo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$ROOT/build-spike"
APP="$OUT/Payload/MetalSpike.app"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
MIN_IOS="${MIN_IOS:-16.3}"

echo "==> Xcode: $(xcodebuild -version | head -1)"
echo "==> SDK:   $SDK_PATH"

rm -rf "$OUT"
mkdir -p "$APP"

echo "==> Compilando (arm64, iOS $MIN_IOS)"
xcrun --sdk iphoneos clang++ \
  -std=c++17 \
  -fobjc-arc \
  -arch arm64 \
  -miphoneos-version-min="$MIN_IOS" \
  -isysroot "$SDK_PATH" \
  -O2 \
  -framework UIKit \
  -framework Foundation \
  -framework CoreGraphics \
  -framework Metal \
  -framework QuartzCore \
  -o "$APP/MetalSpike" \
  "$HERE/src/main.mm"

cp "$HERE/ios/Info.plist" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist"

# Sin firma: la hace el servicio de firma del dispositivo al instalar.
cd "$OUT"
rm -f "$ROOT/MetalSpike.ipa"
/usr/bin/zip -qry "$ROOT/MetalSpike.ipa" Payload
cd "$ROOT"

echo "==> Listo: MetalSpike.ipa"
ls -lh "$ROOT/MetalSpike.ipa"
/usr/bin/unzip -l "$ROOT/MetalSpike.ipa"
