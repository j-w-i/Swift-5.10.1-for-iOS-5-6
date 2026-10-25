#!/bin/bash
# Build the real upstream compiler-rt arbitrary-width atomic implementation.
# This is an addition to target builtins, not fake synchronization.
set -euo pipefail
[ "$#" -eq 5 ] || { echo 'Usage: script CLANG SDK LLVM_SOURCE ARCHIVER NEW_OUTPUT_DIR' >&2; exit 64; }
CC=$1; SDK=$2; LLVM=$3; AR=$4; OUT=$5
for p in "$CC" "$SDK" "$LLVM" "$AR" "$OUT"; do [[ "$p" = /* ]] || exit 64; done
[ -x "$CC" ] && [ -d "$SDK" ] && [ -s "$LLVM/compiler-rt/lib/builtins/atomic.c" ] && [ -x "$AR" ] || exit 1
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo 'Choose a new output.' >&2; exit 1; }
mkdir "$OUT"
/usr/bin/nice -n 15 "$CC" -target armv7-apple-ios5.0 -isysroot "$SDK" -O2 -std=c11 -fvisibility=hidden \
  -I "$LLVM/compiler-rt/lib/builtins" -c "$LLVM/compiler-rt/lib/builtins/atomic.c" -o "$OUT/atomic.o" \
  > "$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log" >&2; exit 1; }
/usr/bin/nice -n 15 "$AR" rcs "$OUT/libLegacyAtomicBackport.a" "$OUT/atomic.o"
echo "Real upstream atomic backport: $OUT/libLegacyAtomicBackport.a"
