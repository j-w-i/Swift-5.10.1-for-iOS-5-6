#!/bin/bash
# Clean native/PST build: geometry precedence, not complete callback parity.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SRC="$HERE/.."
SIM=${1:?booted simulator UUID}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/self-sizing-delegate.XXXXXX")
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
    xcrun clang "${FLAGS[@]}" "$HERE/self-sizing-delegate.m" ${EXTRA[@]+"${EXTRA[@]}"} -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/$mode"
    echo "=== $mode"
    xcrun simctl spawn "$SIM" "$OUT/$mode" > "$OUT/$mode.txt"
    # Keep raw callback counts: zero-estimate native/PST calls currently differ.
    while IFS= read -r line; do printf '%s\n' "$line"; done < "$OUT/$mode.txt"
done
echo "PASS: both engines satisfy sizing-delegate geometry assertions; artifacts: $OUT"
