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

if [ ! -d "$SDK/.git" ]; then
  echo "==> Cloning rexglue-sdk"
  git clone --recursive https://github.com/rexglue/rexglue-sdk.git "$SDK"
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

echo "==> Building host tools (macOS arm64)"
cmake --preset mac-arm64 -S "$SDK"
cmake --build --preset mac-arm64-release -j "$(sysctl -n hw.ncpu)"
cmake --install "$SDK/out/build/mac-arm64" --config Release

echo "==> Building iOS device dylibs (arm64)"
cmake --preset ios-arm64 -S "$SDK"
cmake --build --preset ios-arm64-release -j "$(sysctl -n hw.ncpu)"
cmake --install "$SDK/out/build/ios-arm64" --config Release

echo
echo "Done. Export this before building the game:"
echo "  export REXGLUE_SDK=\"$SDK\""
ls -1 "$SDK/out/ios-arm64/Release"/*.dylib 2>/dev/null || \
  echo "(warning: no dylibs in out/ios-arm64/Release - check the build log)"
