#!/bin/bash
# Independent default variable-size centering, without estimates or scheduling prototypes.
# Usage: run-flow-row-centering-test.sh SIM [--expect-old-top]
set -euo pipefail
SIM=${1:?booted simulator uuid};MODE=${2:-gate};HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P);SRC="$HERE/.."
OUT=$(mktemp -d "${TMPDIR:-/tmp}/flow-centering.XXXXXX");SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules
 -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC")
echo "Artifacts: $OUT"
OBJECTS=()
for source in "$SRC"/*.m;do
 object="$OUT/$(basename "$source" .m).o"
 xcrun clang "${FLAGS[@]}" -c "$source" -o "$object" >>"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log" >&2;exit 1; }
 OBJECTS+=("$object")
done
for engine in native pst;do
 EXTRA=();[[ "$engine" != pst ]] || EXTRA=(-DTEST_PST=1 "${OBJECTS[@]}")
 xcrun clang "${FLAGS[@]}" "$HERE/flow-row-centering.m" ${EXTRA[@]+"${EXTRA[@]}"} \
 -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/$engine"
 if xcrun simctl spawn "$SIM" "$OUT/$engine" >"$OUT/$engine.txt" 2>"$OUT/$engine.stderr";then code=0;else code=$?;fi
 [[ "$code" = 0 || "$code" = 1 ]] || { echo "unexpected $engine exit=$code" >&2;exit 1; }
done
python3 - "$OUT" "$MODE" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1])
def records(name):
 return [json.loads(s[5:]) for s in (p/(name+'.txt')).read_text().splitlines() if s.startswith('CASE ')]
a,b=records('native'),records('pst');assert len(a)==len(b)==16
assert all(r['pass'] for r in a),'native oracle rejected expected centering'
if sys.argv[2]=='--expect-old-top':
 assert sum(not r['pass'] for r in b)==12
 print('BASELINE REPRODUCED: native passes 16; old PST fails 12 variable-size cases (not a parity pass)')
else:
 assert sys.argv[2]=='gate'
 assert all(r['pass'] for r in b),'PST centering mismatch'
 for x,y in zip(a,b):
  assert (x['horizontal'],x['padded'],x['count'])==(y['horizontal'],y['padded'],y['count'])
  assert all(max(abs(v-w) for v,w in zip(r,s))<.01 for r,s in zip(x['frames'],y['frames']))
 print('PASS: 16 default variable-size row/column cases match native')
print('Artifacts:',p)
PY
