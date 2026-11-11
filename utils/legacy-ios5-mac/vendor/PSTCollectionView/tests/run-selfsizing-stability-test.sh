#!/bin/bash
# Native/PST regression gate for conservative preferred-size stability caching.
set -euo pipefail
SIM=${1:?booted simulator uuid};HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P);SRC="$HERE/.."
OUT=$(mktemp -d "${TMPDIR:-/tmp}/selfsizing-stability.XXXXXX");SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules
 -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC")
OBJECTS=()
for source in "$SRC"/*.m;do
 object="$OUT/$(basename "$source" .m).o"
 xcrun clang "${FLAGS[@]}" -c "$source" -o "$object" >>"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log" >&2;exit 1; }
 OBJECTS+=("$object")
done
for mode in native pst;do
 EXTRA=();[[ "$mode" != pst ]] || EXTRA=(-DTEST_PST=1 "${OBJECTS[@]}")
 xcrun clang "${FLAGS[@]}" "$HERE/selfsizing-stability.m" ${EXTRA[@]+"${EXTRA[@]}"} \
 -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/$mode"
 xcrun simctl spawn "$SIM" "$OUT/$mode" >"$OUT/$mode.txt" 2>"$OUT/$mode.stderr"
done
diff -u "$OUT/native.txt" "$OUT/pst.txt"
echo "PASS: invalidation, changed proposal origin and reused-cell stability; artifacts: $OUT"
