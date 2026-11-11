#!/bin/bash
# Usage: run-batch-insert-visibility-test.sh SIM [SRC_DIR]   (SRC_DIR defaults to the vendor directory)
set -euo pipefail
SIM=${1:?booted simulator uuid};HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P);SRC=$(CDPATH= cd -- "${2:-$HERE/..}" && pwd -P)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/batch-insert.XXXXXX");SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FL=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC")
OB=();for s in "$SRC"/*.m;do o="$OUT/$(basename "$s" .m).o";xcrun clang "${FL[@]}" -c "$s" -o "$o" >>"$OUT/build.log" 2>&1||{ tail -20 "$OUT/build.log">&2;exit 1;};OB+=("$o");done
xcrun clang "${FL[@]}" "$HERE/batch-insert-visibility.m" -framework UIKit -framework QuartzCore -o "$OUT/native"
xcrun clang "${FL[@]}" -DTEST_PST=1 "$HERE/batch-insert-visibility.m" "${OB[@]}" -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/pst"
xcrun simctl spawn "$SIM" "$OUT/native" >"$OUT/native.jsonl";xcrun simctl spawn "$SIM" "$OUT/pst" >"$OUT/pst.jsonl"
python3 - "$OUT" <<'PY'
import json,sys,pathlib
p=pathlib.Path(sys.argv[1]);a=[json.loads(l) for l in (p/'native.jsonl').read_text().splitlines()];b=[json.loads(l) for l in (p/'pst.jsonl').read_text().splitlines()]
assert len(a)==len(b)==9;bad=0
for x,y in zip(a,b):
    ok=x['visible']==y['visible'] and x['content']==y['content'] and x['count']==y['count']
    # PST need not match native's event ORDER here, only the set of requests and displays.
    ev=sorted(x['events'])==sorted(y['events'])
    if not(ok and ev):
        bad+=1;print('MISMATCH',x['scenario']);print('  native',x['events'],x['visible']);print('  PST   ',y['events'],y['visible'])
print(f"{'PASS' if not bad else 'FAIL'}: {9-bad}/9 batch-insert scenarios match native (requests, willDisplay, visible, content); artifacts: {p}")
sys.exit(1 if bad else 0)
PY
