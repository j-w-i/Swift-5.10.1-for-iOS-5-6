#!/bin/bash
# Usage: bash run-prefetch-lifecycle-test.sh BOOTED_SIM_UUID
# Isolates setter bookkeeping with seeded outstanding paths, not scrolling/batching.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SRC="$HERE/.."
SIM=${1:?booted simulator UUID}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/prefetch-lifecycle.XXXXXX")
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC")
OBJECTS=()
for source in "$SRC"/*.m; do
    object="$OUT/$(basename "$source" .m).o"
    xcrun clang "${FLAGS[@]}" -c "$source" -o "$object" >> "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
    OBJECTS+=("$object")
done
xcrun clang "${FLAGS[@]}" "$HERE/prefetch-disable.m" "${OBJECTS[@]}" -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/test"
xcrun simctl spawn "$SIM" "$OUT/test"
echo "Artifacts: $OUT"
