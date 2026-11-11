#!/bin/bash
# First-layout proposal for unmeasured self-sizing items: native iOS 27 simulator vs PST.
# Only the first-layout probe is a gate; stepped scrolling is a known difference (see COLLECTION-VIEW.md).
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P); SRC="$HERE/.."; SIM=${1:?sim uuid}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/selfsizing-proposal.XXXXXX"); SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC")
OBJECTS=(); for s in "$SRC"/*.m; do o="$OUT/$(basename "$s" .m).o"; xcrun clang "${FLAGS[@]}" -c "$s" -o "$o" >>"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }; OBJECTS+=("$o"); done
for m in native pst; do E=(); [[ $m == pst ]] && E=(-DTEST_PST=1 "${OBJECTS[@]}")
  xcrun clang "${FLAGS[@]}" "$HERE/selfsizing-unmeasured-proposal.m" ${E[@]+"${E[@]}"} -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/$m"
  xcrun simctl spawn "$SIM" "$OUT/$m" > "$OUT/$m.txt"; done
diff -u "$OUT/native.txt" "$OUT/pst.txt"; echo "PASS: first-layout unmeasured proposal matches native; artifacts: $OUT"
