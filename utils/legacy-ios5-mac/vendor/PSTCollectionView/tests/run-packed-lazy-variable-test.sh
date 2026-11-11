#!/bin/bash
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P); SRC="$HERE/.."; SIM=${1:?sim uuid}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/packed-lazyvar.XXXXXX"); SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun clang -target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC" "$HERE/packed-lazy-variable.m" "$SRC"/*.m -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/test" >"$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log"; exit 1; }
xcrun simctl spawn "$SIM" "$OUT/test"
echo "Artifacts: $OUT"
