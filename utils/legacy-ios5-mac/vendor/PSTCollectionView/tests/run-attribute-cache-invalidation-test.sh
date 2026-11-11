#!/bin/bash
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P); SRC="$HERE/.."; SIM=${1:?sim uuid}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/attribute-cache.XXXXXX"); SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC")
OBJECTS=(); for s in "$SRC"/*.m; do o="$OUT/$(basename "$s" .m).o"; xcrun clang "${FLAGS[@]}" -c "$s" -o "$o" >>"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }; OBJECTS+=("$o"); done
xcrun clang "${FLAGS[@]}" "$HERE/attribute-cache-invalidation.m" "${OBJECTS[@]}" -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/test"
xcrun simctl spawn "$SIM" "$OUT/test"
echo "Artifacts: $OUT"
