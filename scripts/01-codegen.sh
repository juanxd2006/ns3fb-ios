#!/usr/bin/env bash
# Recompile YOUR OWN game/default.xex into C++ and generate the project manifest.
#
# The recompiler only translates code. It does not supply the game, and it does
# not make the title boot on its own: the generated manifest needs the
# entrypoint/setjmp/longjmp details checked by hand (see README.md, Paso 3).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP="$ROOT/app"
SDK="${REXGLUE_SDK:-$ROOT/thirdparty/rexglue-sdk}"
TOOL="${REXGLUE_HOST_TOOL:-$SDK/out/mac-arm64/Release/rexglue}"

XEX="$APP/game/default.xex"
EXPECTED_SHA1="f7ad65e26a00df6c29c9d34b291819593e455e9f"
EXPECTED_SIZE=11218944

[ -f "$XEX" ] || { echo "Missing $XEX - extract your own disc first (README, Paso 1)." >&2; exit 1; }
[ -x "$TOOL" ] || { echo "rexglue tool not found at $TOOL - run scripts/00-fetch-sdk.sh." >&2; exit 1; }

echo "==> Verifying default.xex"
SIZE="$(wc -c < "$XEX" | tr -d ' ')"
if command -v shasum >/dev/null; then
  SHA1="$(shasum -a 1 "$XEX" | awk '{print $1}')"
else
  SHA1="$(sha1sum "$XEX" | awk '{print $1}')"
fi
if [ "$SHA1" != "$EXPECTED_SHA1" ] || [ "$SIZE" != "$EXPECTED_SIZE" ]; then
  echo "  size: $SIZE (expected $EXPECTED_SIZE)" >&2
  echo "  sha1: $SHA1" >&2
  echo "  expected: $EXPECTED_SHA1" >&2
  echo >&2
  echo "This is a different disc revision. The recompiled code is built from one" >&2
  echo "specific executable: NTSC-U, Title ID 4E4D085C, Media ID 2576927D." >&2
  echo "Nothing downstream can fix a mismatch - the port will not boot." >&2
  exit 1
fi
echo "  ok"

cd "$APP"

# `init` generates ns3fb_manifest.toml and generated/rexglue.cmake, which we do
# need. But it also rewrites CMakeLists.txt and CMakePresets.json with its own
# generic templates (RegeneratePolicy::RequiresForce) - destroying the iOS
# bundle target and the ios-arm64 preset this project depends on. Keep copies
# and put them back immediately after init.
KEEP="$(mktemp -d)"
for f in CMakeLists.txt CMakePresets.json; do
  [ -f "$f" ] && cp "$f" "$KEEP/"
done
restore_project_files() {
  for f in CMakeLists.txt CMakePresets.json; do
    if [ -f "$KEEP/$f" ]; then
      cp "$KEEP/$f" "$f"
    fi
  done
}
trap 'restore_project_files; rm -rf "$KEEP"' EXIT

if [ ! -f ns3fb_manifest.toml ]; then
  echo "==> Initialising project (manifest + SDK boilerplate)"
  "$TOOL" -f init \
    --project-name ns3fb \
    --xex-path game/default.xex \
    --game-root game \
    --project-root .
else
  echo "==> Reusing existing ns3fb_manifest.toml"
fi

restore_project_files
echo "==> Project files restored (CMakeLists.txt, CMakePresets.json)"
echo "    preset iOS disponible: $(grep -c '"name": "ios-arm64-release"' CMakePresets.json || true)"

# Titulos reales siempre tienen ramas directas a funciones que el analizador no
# ve (no estan en .pdata). Se declaran en [entrypoint.functions] antes de
# recompilar, o el codegen aborta con "target not in any function".
echo "==> Seeding entrypoints"
python3 "$HERE/02-seed-entrypoints.py"

# Sin setjmp/longjmp el codegen compila longjmp como una llamada normal que
# retorna, con el epilogo ya omitido: r1 y los callee-saved quedan corruptos y
# el invitado acaba llamando a trozos de epilogo. Ver docs/INTERIOR_ENTRIES.md.
echo "==> setjmp/longjmp del CRT"
python3 "$HERE/02b-set-jumptargets.py"

echo "==> Running codegen (slow: analyse + emit C++ for an 11 MB image)"
"$TOOL" codegen ns3fb_manifest.toml

echo
echo "Generated:"
ls -1 "$APP/generated/default" 2>/dev/null | head -20
echo
echo "Next: read the codegen warnings, then build (README, Paso 4)."
echo "Expect unresolved entrypoints and 'invalid or unregistered function' traps;"
echo "each one is added to [entrypoint.functions] in ns3fb_manifest.toml and the"
echo "codegen is re-run. See docs/TROUBLESHOOTING.md."
