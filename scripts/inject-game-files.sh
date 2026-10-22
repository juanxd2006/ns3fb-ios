#!/usr/bin/env bash
# Bake the extracted game into an .ipa, so nothing has to be copied by hand on
# the device: the files land in Payload/NS3FB.app/game/ and ns3fb_app.h falls
# back to <bundle>/game when Documents/game is empty.
#
#   ./scripts/inject-game-files.sh NS3FB.ipa ./game NS3FB-full.ipa
#
# WARNING: the game data is ~7 GB. The resulting .ipa is huge, every sideload
# tool has to transfer it in full, and reinstalling re-transfers it. If you will
# iterate on the app, keep the .ipa data-free and copy `game/` over with the
# Files app instead - both locations work.
set -euo pipefail
IPA="${1:?usage: inject-game-files.sh <in.ipa> <game-dir> [out.ipa]}"
GAME="${2:?usage: inject-game-files.sh <in.ipa> <game-dir> [out.ipa]}"
OUT="${3:-${IPA%.ipa}-full.ipa}"

[ -f "$IPA" ] || { echo "IPA not found: $IPA" >&2; exit 1; }
[ -f "$GAME/default.xex" ] || { echo "$GAME/default.xex not found - pass the folder that contains default.xex." >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Unpacking $IPA"
unzip -q "$IPA" -d "$WORK"
APP_DIR="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP_DIR" ] || { echo "No .app inside Payload/ - is this a real .ipa?" >&2; exit 1; }

echo "==> Copying game into $(basename "$APP_DIR")/game"
mkdir -p "$APP_DIR/game"
# cp -R (not mv) so a failed run does not damage the source folder.
cp -R "$GAME"/. "$APP_DIR/game"/

# Adding resources invalidates the signature, and a half-signed bundle fails to
# install. Strip it; sideloading tools sign the whole bundle themselves.
rm -rf "$APP_DIR/_CodeSignature" "$APP_DIR/embedded.mobileprovision"
if command -v codesign >/dev/null && command -v xcrun >/dev/null; then
  echo "==> Re-signing ad hoc"
  for d in "$APP_DIR"/Frameworks/*.dylib; do codesign -f -s - "$d" 2>/dev/null || true; done
  codesign -f -s - "$(dirname "$0")/../app/platform/ios/ns3fb.entitlements" "$APP_DIR" 2>/dev/null || \
    codesign -f -s - "$APP_DIR"
fi

echo "==> Repacking"
rm -f "$OUT"
(cd "$WORK" && zip -qry "$OUT" Payload)
SIZE="$(du -h "$OUT" | awk '{print $1}')"
echo "Wrote $OUT ($SIZE)"
echo
echo "Install with AltStore / SideStore / Sideloadly. On-device free space needed:"
echo "roughly twice the .ipa size during install."
