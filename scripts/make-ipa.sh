#!/usr/bin/env bash
# Package the built app as an .ipa for sideloading (AltStore, SideStore,
# Sideloadly, TrollStore). Those tools sign it with your own Apple ID.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP="${APP:-$ROOT/app/out/build/ios-arm64-release/ns3fb.app}"
OUT="${OUT:-$ROOT/NS3FB.ipa}"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/app/platform/ios/ns3fb.entitlements}"

[ -d "$APP" ] || { echo "Built app not found at $APP - build it first (README, Paso 4)." >&2; exit 1; }
[ -f "$ENTITLEMENTS" ] || { echo "Entitlements not found at $ENTITLEMENTS." >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
BUNDLE="$STAGE/Payload/$(basename "$APP")"

# Strip anything that identifies the builder: a provisioning profile lists the
# team, name and device UDIDs, and a signature names the certificate.
rm -f "$BUNDLE/embedded.mobileprovision"
rm -rf "$BUNDLE/_CodeSignature"

# Re-sign ad hoc. An ad hoc signature names no certificate or team, but it does
# carry the entitlements the app asks for, and sideloading tools carry those
# over into their own signature. That is how the app requests extended virtual
# addressing, which 3 GB devices need: TrollStore, jailbroken installs and paid
# developer accounts grant it, free Apple IDs drop it.
#
# Firma anidada, de dentro hacia fuera: primero las dylibs, luego cada .appex de
# PlugIns/ (la extension de memoria) y al final el .app. iOS rechaza el IPA
# entero si un bundle anidado no esta firmado. El .appex va SIN entitlements a
# proposito: los suyos tienen que ser un subconjunto de los de la app, y una
# extension que solo reserva memoria no necesita ninguno.
for d in "$BUNDLE"/Frameworks/*.dylib; do
  [ -f "$d" ] || continue
  codesign -f -s - "$d"
done
for appex in "$BUNDLE"/PlugIns/*.appex; do
  [ -d "$appex" ] || continue
  codesign -f -s - "$appex"
  echo "==> Firmado $(basename "$appex")"
done
codesign -f -s - --entitlements "$ENTITLEMENTS" "$BUNDLE"

rm -f "$OUT"
(cd "$STAGE" && zip -qry "$OUT" Payload)
echo "Wrote $OUT"
shasum -a 256 "$OUT"