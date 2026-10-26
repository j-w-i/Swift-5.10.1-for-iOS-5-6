#!/bin/bash
# Deterministic behavioural + counter harness for the vendored PST collection runtime.
#
# The runtime is built for armv7 iOS 5 by build-collection-runtime.sh. That binary
# can not execute on this machine, so the same Objective-C sources are compiled
# for the iOS simulator here and executed in the booted simulator. Geometry is
# compared against a golden file recorded from the pre-change sources; counters
# are printed for before/after comparison.
#
# Usage:
#   run-collection-perf-tests.sh SRC_DIR OUT_DIR record GOLDEN.json
#   run-collection-perf-tests.sh SRC_DIR OUT_DIR check GOLDEN.json
#
# SRC_DIR is the directory holding PSTCollectionView*.m/h (the vendor directory,
# or a pristine copy of it). OUT_DIR must not exist. The booted simulator from
# the active Xcode is used; no simulator is modified beyond running this binary.
set -euo pipefail

[ "$#" = 4 ] || { echo "Usage: run-collection-perf-tests.sh SRC_DIR OUT_DIR record|check GOLDEN.json" >&2; exit 64; }
SRC=$(CDPATH= cd -- "$1" && pwd -P)
OUT=$2
MODE=$3
GOLDEN=$4
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if [[ "$GOLDEN" != /* ]]; then GOLDEN="$PWD/$GOLDEN"; fi
[ -e "$OUT" ] && { echo 'Output exists; refusing reuse.' >&2; exit 1; }
mkdir -p "$OUT"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
if [ ! -d "$SDK" ]; then
  echo 'No iPhoneSimulator SDK available.' >&2
  exit 69
fi
DEPLOYMENT=17.0
TARGET="arm64-apple-ios${DEPLOYMENT}-simulator"

OBJECTS=()
for source in "$SRC"/*.m; do
  name=$(basename "$source" .m)
  xcrun --sdk iphonesimulator clang -target "$TARGET" -isysroot "$SDK" -O2 -g0 \
    -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 \
    -Wno-nullability-completeness -Wno-incompatible-pointer-types \
    -I "$SRC" -c "$source" -o "$OUT/$name.o" > "$OUT/$name.log" 2>&1 || {
      tail -30 "$OUT/$name.log" >&2; echo "Compilation failed: $name" >&2; exit 65; }
  OBJECTS+=("$OUT/$name.o")
done
xcrun --sdk iphonesimulator clang -target "$TARGET" -isysroot "$SDK" -O2 -g0 \
  -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 \
  -Wno-nullability-completeness -Wno-incompatible-pointer-types \
  -I "$SRC" -I "$HERE" "$HERE/PSTCollectionPerfHarness.m" "${OBJECTS[@]}" \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
  -o "$OUT/harness" > "$OUT/link.log" 2>&1 || { tail -30 "$OUT/link.log" >&2; echo 'Link failed' >&2; exit 65; }
/usr/bin/codesign -s - -f "$OUT/harness" > "$OUT/codesign.log" 2>&1

if ! xcrun simctl list devices booted | grep -q Booted; then
  echo 'No booted simulator; boot one with: xcrun simctl boot <device>' >&2
  exit 69
fi

set +e
if [ "$MODE" = record ]; then
  xcrun simctl spawn booted "$OUT/harness" record "$GOLDEN" > "$OUT/stdout.txt" 2> "$OUT/stderr.txt"
  status=$?
  cp "$GOLDEN" "$OUT/result.json" 2>/dev/null || true
elif [ "$MODE" = check ]; then
  xcrun simctl spawn booted "$OUT/harness" check "$GOLDEN" "$OUT/result.json" > "$OUT/stdout.txt" 2> "$OUT/stderr.txt"
  status=$?
else
  echo "Unknown mode: $MODE" >&2
  exit 64
fi
set -e

cat "$OUT/stderr.txt"
python3 - "$OUT/result.json" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path))
counters = doc['counters']
keys = ['passes', 'passesSkipped', 'visibleCellsCreated', 'attributesComputed',
        'elementScans', 'itemDerivations', 'itemDerivationsCached',
        'layoutPreparations', 'layoutPreparationReuses',
        'itemCountScanSteps', 'dataValidations', 'dataRefilters',
        'visibleAttributeApplications', 'layoutAttributeDiffs', 'layoutPassNanoseconds']
print('\ncounters per scenario (n/a means this source tree has no counters):')
if not counters:
    print('(none)')
    raise SystemExit(0)
width = max(len(name) for name in counters)
print(f'{"scenario":{width}}  ' + '  '.join(f'{k:>16}' for k in keys))
totals = {k: 0 for k in keys}
for name, values in counters.items():
    if not values:
        print(f'{name:{width}}  ' + '  '.join(f'{"n/a":>16}' for _ in keys))
        continue
    print(f'{name:{width}}  ' + '  '.join(f'{values.get(k, 0):>16}' for k in keys))
    for k in keys:
        totals[k] += values.get(k, 0)
if any(totals.values()):
    print(f'\n{"TOTAL":{width}}  ' + '  '.join(f'{totals[k]:>16}' for k in keys))
PY

if [ "$status" -ne 0 ]; then
  echo "harness exited $status" >&2
  exit "$status"
fi
