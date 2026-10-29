#!/bin/bash
# Public-API native/PST differential test. Never selects ambiguous 'booted'.
# Usage: bash run-collection-empty-tests.sh SRC_DIR NEW_OUT_DIR SIMULATOR_UUID
# No install, boot, shutdown, erase, device configuration, or runtime source edits.
set -euo pipefail
[[ $# == 3 ]] || { echo 'usage: run-collection-empty-tests.sh SRC_DIR NEW_OUT_DIR SIMULATOR_UUID' >&2; exit 64; }
SRC=$(CDPATH= cd -- "$1" && pwd -P)
OUT=$2
UDID=$3
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[[ "$UDID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || { echo 'Explicit simulator UUID required' >&2; exit 64; }
[[ ! -e "$OUT" ]] || { echo 'Output exists; refusing overwrite' >&2; exit 73; }
# Inspect only: require this exact already-booted iOS simulator.
xcrun simctl list devices -j | python3 -c '
import json, sys
uid = sys.argv[1]
rows = [(r,d) for r,ds in json.load(sys.stdin)["devices"].items() for d in ds if d["udid"] == uid]
assert len(rows) == 1, "Simulator UUID not found"
r,d = rows[0]
assert ".iOS-" in r and d["state"] == "Booted" and d.get("isAvailable"), "Requires already-booted iOS simulator"
print(uid, r, d["name"], d["state"])
' "$UDID"
mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)
# Bound individual generated artifacts/logs to 2 MiB; total normally below 3 MiB.
ulimit -f 4096
printf 'bash %q %q %q %q\n' "$HERE/run-collection-empty-tests.sh" "$SRC" "$OUT" "$UDID" > "$OUT/invocation.txt"
cp "$HERE/PSTCollectionEmptyAttributesHarness.m" "$OUT/harness-source.m"
cp "$HERE/run-collection-empty-tests.sh" "$OUT/runner-source.sh"
df -h "$OUT" > "$OUT/disk-before.txt"
shasum -a 256 "$SRC"/*.m "$SRC"/*.h > "$OUT/runtime-before.sha256"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET=arm64-apple-ios17.0-simulator
OBJECTS=()
for source in "$SRC"/*.m; do
    name=$(basename "$source" .m)
    xcrun --sdk iphonesimulator clang -target "$TARGET" -isysroot "$SDK" -O2 -g0 \
        -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 \
        -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC" \
        -c "$source" -o "$OUT/$name.o" > "$OUT/$name.log" 2>&1 || {
        tail -30 "$OUT/$name.log" >&2; exit 65;
    }
    OBJECTS+=("$OUT/$name.o")
done
xcrun --sdk iphonesimulator clang -target "$TARGET" -isysroot "$SDK" -O2 -g0 \
    -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 \
    -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC" \
    "$HERE/PSTCollectionEmptyAttributesHarness.m" "${OBJECTS[@]}" \
    -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
    -o "$OUT/harness" > "$OUT/link.log" 2>&1 || { tail -30 "$OUT/link.log" >&2; exit 65; }
/usr/bin/codesign -s - -f "$OUT/harness" > "$OUT/codesign.log" 2>&1
set +e
xcrun simctl spawn "$UDID" "$OUT/harness" "$OUT/result.json" > "$OUT/stdout.txt" 2> "$OUT/stderr.txt"
status=$?
set -e
printf '%s\n' "$status" > "$OUT/exit-status.txt"
shasum -a 256 "$SRC"/*.m "$SRC"/*.h > "$OUT/runtime-after.sha256"
cmp "$OUT/runtime-before.sha256" "$OUT/runtime-after.sha256"
python3 - "$OUT" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
print((p / 'stderr.txt').read_text())
if (p / 'result.json').exists():
    d = json.loads((p / 'result.json').read_text())
    print('Native OS:', d['nativeOSVersion'], 'simulator:', d['simulatorUDID'])
    print('step                    engine visible subviews displayed created requested ended prepared queries')
    for n, s in zip(d['native'], d['pst']):
        for engine, row in [('native', n), ('PST', s)]:
            print(f"{row['step']:23} {engine:6} {str(row['visible']):9}", *(row[k] for k in ['cellSubviews','displayedCellSubviews','created','requested','ended','prepared','attributeQueries']))
print('Artifact bytes:', sum(x.stat().st_size for x in p.iterdir() if x.is_file()))
PY
exit "$status"
