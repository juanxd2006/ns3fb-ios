#!/usr/bin/env bash
# Compila metal-720p y produce Metal720p.ipa (sin firmar).
#
# Banco de decision, no el port: un solo .mm con clang de Xcode, ~1 minuto de
# build en vez de los 30-45 del port. No necesita el SDK de ReXGlue ni el
# ejecutable del juego.
#
# Uso:  ./spike/metal-720p/build-ipa.sh
# Sale: Metal720p.ipa en la raiz del repo.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$ROOT/build-metal-720p"
APP="$OUT/Payload/Metal720p.app"
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
  -o "$APP/Metal720p" \
  "$HERE/src/main.mm"

cp "$HERE/ios/Info.plist" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist"

# Sin firma: la hace el servicio de firma del dispositivo al instalar.
cd "$OUT"
rm -f "$ROOT/Metal720p.ipa"
/usr/bin/zip -qry "$ROOT/Metal720p.ipa" Payload
cd "$ROOT"

echo "==> Listo: Metal720p.ipa"
ls -lh "$ROOT/Metal720p.ipa"
/usr/bin/unzip -l "$ROOT/Metal720p.ipa"
