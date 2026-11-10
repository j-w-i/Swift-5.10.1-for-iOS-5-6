#!/bin/bash
# Usage: bash run-collection-size-hook-test.sh BOOTED_SIM_UUID
# Exercises private hook bookkeeping with test doubles, plus native installer fallthrough.
# Does not emulate the iOS 6/7 layout engine; that still needs a device run.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SIM=${1:?booted simulator UUID}
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/collection-size-hook.XXXXXX")
xcrun clang -fobjc-arc -fblocks -arch arm64 -isysroot "$SDK" -mios-simulator-version-min=17.0 \
    -include "$HERE/../Runtime/UICObjCCompatibility.h" \
    -framework UIKit -framework Foundation -framework CoreGraphics \
    "$HERE/collection_size_hook_test.m" -o "$OUT/test"
xcrun simctl spawn "$SIM" "$OUT/test"
