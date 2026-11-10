#!/bin/bash
# Usage: bash run-self-sizing-updates.sh BOOTED_SIM_UUID
# Visible/offscreen mutation sizing gate. Animations disabled; not an animation/performance gate.
# Offscreen visits retarget scrolling to isolate sizing from pending scroll-position parity.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SRC="$HERE/.."
SIM=${1:?booted simulator UUID}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/self-sizing-updates.XXXXXX")
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
    xcrun clang "${FLAGS[@]}" "$HERE/self-sizing-updates.m" ${EXTRA[@]+"${EXTRA[@]}"} -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/$mode"
    xcrun simctl spawn "$SIM" "$OUT/$mode" > "$OUT/$mode.txt"
    echo "=== $mode"
    cat "$OUT/$mode.txt"
done
diff -u "$OUT/native.txt" "$OUT/pst.txt"
echo "PASS: visible/offscreen self-sizing mutation checks agree (scroll retargeting allowed); artifacts: $OUT"
