#!/bin/bash
# Trace by default; optional gate checks ONLY initial geometry/fitting-call budget, never stepped parity.
# Usage: bash trace-selfsizing-steps.sh BOOTED_SIMULATOR_UUID [--check-initial-fittings]
set -euo pipefail
CHECK=${2:-trace};[[ "$CHECK" = trace || "$CHECK" = --check-initial-fittings ]] || exit 64
SIM=${1:?booted simulator uuid};HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P);SRC="$HERE/.."
OUT=$(mktemp -d "${TMPDIR:-/tmp}/selfsizing-step-trace.XXXXXX");SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules
 -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC")
OBJECTS=()
for source in "$SRC"/*.m;do
 object="$OUT/$(basename "$source" .m).o"
 xcrun clang "${FLAGS[@]}" -c "$source" -o "$object" >>"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log" >&2;exit 1; }
 OBJECTS+=("$object")
done
for mode in native pst;do
 EXTRA=();[[ "$mode" != pst ]] || EXTRA=(-DTEST_PST=1 "${OBJECTS[@]}")
 xcrun clang "${FLAGS[@]}" "$HERE/selfsizing-step-trace.m" ${EXTRA[@]+"${EXTRA[@]}"} \
 -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/$mode"
 xcrun simctl spawn "$SIM" "$OUT/$mode" >"$OUT/$mode.jsonl" 2>"$OUT/$mode.stderr"
done
python3 - "$OUT" "$CHECK" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);native=[json.loads(s) for s in (p/'native.jsonl').read_text().splitlines()];pst=[json.loads(s) for s in (p/'pst.jsonl').read_text().splitlines()]
assert len(native)==len(pst)==6
for a,b in zip(native,pst):
 assert a['phase']==b['phase']
 changed=[i for i,(x,y) in enumerate(zip(a['frames'],b['frames'])) if max(abs(x[0]-y[0]),abs(x[1]-y[1]))>.51]
 print(a['phase'], 'native/PST',
  'content=',(a['contentHeight'],b['contentHeight']), 'offset=',(a['offset'],b['offset']),
  'requests=',(a['requests'],b['requests']), 'fit_calls=',(len(a['fittings']),len(b['fittings'])),
  'visible=',(a['visible'],b['visible']), 'differing_frame_count=',len(changed))
if sys.argv[2]=='--check-initial-fittings':
 a,b=native[0],pst[0]
 assert len(a['frames'])==len(b['frames'])==60
 assert all(max(abs(x[0]-y[0]),abs(x[1]-y[1]))<=.51 for x,y in zip(a['frames'],b['frames'])), 'initial geometry mismatch'
 assert abs(a['contentHeight']-b['contentHeight'])<=.51 and a['visible']==b['visible']
 assert len(b['fittings'])<=len(a['fittings']), 'PST exceeds initial native fitting-call budget'
 print('PASS initial geometry and fitting-call budget ONLY; stepped mismatches above remain')
print('Trace artifacts:',p)
PY
