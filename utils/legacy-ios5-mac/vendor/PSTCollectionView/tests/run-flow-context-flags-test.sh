#!/bin/bash
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P); SRC="$HERE/.."; SIM=${1:?sim uuid}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/flow-context-flags.XXXXXX"); SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC")
if [[ ${2:-} == --named-items ]]; then FLAGS+=(-DTEST_NAMED_ITEM_CONTEXT=1); fi
OBJECTS=(); for s in "$SRC"/*.m; do o="$OUT/$(basename "$s" .m).o"; xcrun clang "${FLAGS[@]}" -c "$s" -o "$o" >>"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }; OBJECTS+=("$o"); done
for m in native pst; do E=(); [[ $m == pst ]] && E=(-DTEST_PST=1 "${OBJECTS[@]}")
 xcrun clang "${FLAGS[@]}" "$HERE/flow-context-flags.m" ${E[@]+"${E[@]}"} -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/$m"
 xcrun simctl spawn "$SIM" "$OUT/$m" > "$OUT/$m.txt"
done
diff -u "$OUT/native.txt" "$OUT/pst.txt"
echo "PASS: four flag combinations and both coalescing orders match native geometry and delegate-query behavior; artifacts: $OUT"
