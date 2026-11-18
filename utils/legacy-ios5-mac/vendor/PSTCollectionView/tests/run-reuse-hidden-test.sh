#!/bin/bash
# Reuse hiding (hidden-for-reuse, held-back layout, show on add, empty base applyLayoutAttributes:): native UIKit vs PST. Usage: SIM_UUID
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P); SRC="$HERE/.."; SIM=${1:?sim uuid}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/reuse-hidden.XXXXXX"); SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC")
OBJECTS=(); for s in "$SRC"/*.m; do o="$OUT/$(basename "$s" .m).o"; xcrun clang "${FLAGS[@]}" -c "$s" -o "$o" >>"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }; OBJECTS+=("$o"); done
for m in native pst; do E=(); [[ $m == pst ]] && E=(-DTEST_PST=1 "${OBJECTS[@]}")
  xcrun clang "${FLAGS[@]}" "$HERE/reuse-hidden.m" ${E[@]+"${E[@]}"} -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/$m"
  xcrun simctl spawn "$SIM" "$OUT/$m" > "$OUT/$m.txt"; done
# One known difference, recorded rather than diffed away: inside cellForItemAtIndexPath: a reused cell is still hidden
# for reuse under UIKit 6.1 (-[UIView isHidden] reads the layer and _addControlledSubview: shows it only afterwards;
# ios61-ref/ghidra/collection-scroll-output), while the simulator's modern UIKit reports it visible. PST follows 6.1.
python3 - "$OUT/native.txt" "$OUT/pst.txt" <<'PY'
import re, sys
native, pst = (open(p).read().splitlines() for p in sys.argv[1:])
if len(native) != len(pst): sys.exit("FAIL: native and PST printed different line counts")
known = 0
for n, p in zip(native, pst):
    m = re.fullmatch(r"cfi (\d+) hidden=0 attached=1", n)
    if m and p == "cfi %s hidden=1 attached=1" % m.group(1): known += 1; continue
    if n != p: sys.exit("FAIL: native %r vs PST %r" % (n, p))
if known == 0: sys.exit("FAIL: the recorded 6.1-vs-modern difference did not appear; re-check it")
print("KNOWN DIFFERENCE: %d reused cell(s) hidden inside cellForItemAtIndexPath: (UIKit 6.1) vs visible (modern UIKit)" % known)
PY
echo "PASS: reuse hiding matches native apart from the recorded difference; artifacts: $OUT"
