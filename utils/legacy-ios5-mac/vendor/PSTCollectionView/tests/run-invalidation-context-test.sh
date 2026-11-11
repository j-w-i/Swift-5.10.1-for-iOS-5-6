#!/bin/bash
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P); SRC="$HERE/.."; SIM=${1:?sim uuid}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/invalidation-context.XXXXXX"); SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -fobjc-arc -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 -I "$SRC")
for engine in native pst; do
 EXTRA=(); if [[ $engine == pst ]]; then EXTRA=(-DTEST_PST=1 "$SRC/PSTCollectionViewLayoutInvalidationContext.m"); fi
 xcrun clang "${FLAGS[@]}" "$HERE/invalidation-context.m" ${EXTRA[@]+"${EXTRA[@]}"} -framework UIKit -framework CoreGraphics -o "$OUT/$engine"
 xcrun simctl spawn "$SIM" "$OUT/$engine" > "$OUT/$engine.txt"
done
diff -u "$OUT/native.txt" "$OUT/pst.txt"
echo "PASS: invalidation context defaults, deduplication and adjustments match native; artifacts: $OUT"
