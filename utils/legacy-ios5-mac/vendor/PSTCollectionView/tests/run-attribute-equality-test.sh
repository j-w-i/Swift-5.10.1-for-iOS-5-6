#!/bin/bash
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SRC="$HERE/.."
SIM=${1:?booted simulator UUID}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/attribute-equality.XXXXXX")
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
    xcrun clang "${FLAGS[@]}" "$HERE/attribute-equality.m" ${EXTRA[@]+"${EXTRA[@]}"} -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/$mode"
    xcrun simctl spawn "$SIM" "$OUT/$mode" > "$OUT/$mode.txt"
done
diff -u "$OUT/native.txt" "$OUT/pst.txt"
echo "PASS: native/PST geometry and presentation equality cases agree; artifacts: $OUT"
