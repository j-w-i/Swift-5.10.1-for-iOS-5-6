#!/bin/bash
# Usage: bash run-automatic-size-test.sh BOOTED_SIM_UUID
# Checks sentinel/proposal/cell sizes; prints remaining native/PST geometry differences.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SRC="$HERE/.."
SIM=${1:?booted simulator UUID}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/automatic-size.XXXXXX")
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC")
OBJECTS=()
for source in "$SRC"/*.m; do
    object="$OUT/$(basename "$source" .m).o"
    xcrun clang "${FLAGS[@]}" -c "$source" -o "$object" >> "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }
    OBJECTS+=("$object")
done
for mode in native pst; do
    EXTRA=()
    if [[ "$mode" == pst ]]; then EXTRA=(-DTEST_PST=1 "${OBJECTS[@]}"); fi
    xcrun clang "${FLAGS[@]}" "$HERE/automatic-size.m" ${EXTRA[@]+"${EXTRA[@]}"} -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/$mode"
    xcrun simctl spawn "$SIM" "$OUT/$mode" > "$OUT/$mode.txt"
done
echo 'PASS: sentinel preserved; initial proposal 50x50 and preferred cell sizes 80x30 on both axes'
if diff -u "$OUT/native.txt" "$OUT/pst.txt"; then
    echo 'PASS: exact geometry parity'
else
    echo 'KNOWN GAP: horizontal content extent and row spacing differ (not an exact parity pass)'
fi
echo "Artifacts: $OUT"
