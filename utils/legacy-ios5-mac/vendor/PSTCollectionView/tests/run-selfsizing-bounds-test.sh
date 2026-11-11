#!/bin/bash
# A self-sizing cell whose preferred size never converges must not hang layout: the scheduler bounds attempts per
# cell and passes per transaction. Usage: run-selfsizing-bounds-test.sh SIM [SRC_DIR]
set -euo pipefail
SIM=${1:?booted simulator uuid};HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P);SRC=$(CDPATH= cd -- "${2:-$HERE/..}" && pwd -P)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/bounds.XXXXXX");SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FL=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC")
OB=();for s in "$SRC"/*.m;do o="$OUT/$(basename "$s" .m).o";xcrun clang "${FL[@]}" -c "$s" -o "$o" >>"$OUT/build.log" 2>&1||{ tail -20 "$OUT/build.log">&2;exit 1;};OB+=("$o");done
xcrun clang "${FL[@]}" "$HERE/selfsizing-schedule-bounds.m" "${OB[@]}" -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/bound"
( xcrun simctl spawn "$SIM" "$OUT/bound" >"$OUT/out.txt" 2>&1; echo "exit=$?" >>"$OUT/out.txt" ) &
for _ in $(seq 1 40);do sleep 1;grep -q '^exit=' "$OUT/out.txt" 2>/dev/null && break;done
if ! grep -q '^exit=' "$OUT/out.txt";then pkill -f "$OUT/bound" || true;echo "FAIL: non-converging cell hung layout (no exit in 40s)";exit 1;fi
cat "$OUT/out.txt";grep -q '^PASS' "$OUT/out.txt" && grep -q '^exit=0' "$OUT/out.txt"
