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

# `init` writes ns3fb_manifest.toml plus the SDK boilerplate (generated/rexglue.cmake).
# It is idempotent only with -f, so skip it when a manifest already exists.
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

# Titulos reales siempre tienen ramas directas a funciones que el analizador no
# ve (no estan en .pdata). Se declaran en [entrypoint.functions] antes de
# recompilar, o el codegen aborta con "target not in any function".
echo "==> Seeding entrypoints"
python3 "$HERE/02-seed-entrypoints.py"

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
