#!/bin/bash
# Simulator timing/profiling fixture for the legacy (force-installed) path.
#   Tests/run-simulator-perf.sh [SIMULATOR_DEVICE_NAME]
# Reuses the same staged-source build as run-simulator-hook-test.sh.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
VENDOR=$(CDPATH= cd -- "$HERE/.." && pwd -P)
DEVICE=${1:-iPhone SE (3rd generation)}
WORK=${TMPDIR:-/tmp}/legacy-ios5-sim-perf
rm -rf "$WORK"; mkdir -p "$WORK/src" "$WORK/tool"
PY=${PYTHON:-python3}
"$PY" - "$VENDOR" "$WORK/src" <<'PYSTAGE'
import re, sys
from pathlib import Path
vendor, out = Path(sys.argv[1]), Path(sys.argv[2])
for component in ('Cassowary', 'LegacyAutoLayout'):
    for path in sorted((vendor / component).glob('*.swift')):
        text = path.read_text()
        text = re.sub(r'^import (UIKit|Cassowary|LegacyAutoLayout)\s*$', '', text, flags=re.M)
        text = re.sub(r'^private typealias (Expression|Constraint|RelationalOperator) = \w+\.\w+\s*$', '', text, flags=re.M)
        text = text.replace('Cassowary.', '')
        (out / (component + '-' + path.name)).write_text('import UIKit\n' + text)
for path in sorted((vendor / 'Runtime').glob('*.swift')):
    text = path.read_text()
    text = re.sub(r'^import CUIKitBackports\s*$',
                  '@_silgen_name("UICInstallConstraintClassMethods")\n'
                  'func UICInstallConstraintClassMethods()', text, flags=re.M)
    (out / path.name).write_text('import UIKit\n' + text)
PYSTAGE
cp "$HERE/autolayout_simulator_perf.swift" "$WORK/tool/main.swift"
cat > "$WORK/stub.c" <<'CSRC'
void UICInstallConstraintClassMethods(void) {}
CSRC
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET=$(uname -m)-apple-ios15.0-simulator
clang -target "$TARGET" -isysroot "$SDK" -c "$WORK/stub.c" -o "$WORK/stub.o"
clang -target "$TARGET" -isysroot "$SDK" -O2 -ffp-contract=off -c "$VENDOR/CassowaryC/CassowaryC.c" -o "$WORK/CassowaryC.o"
FILES=$(ls "$WORK"/src/*.swift | grep -v -E "LegacyAutoLayoutIOS5|UILayoutGuideShim|UIViewAnchorShims")
# shellcheck disable=SC2086
/usr/bin/xcrun swiftc -swift-version 5 -target "$TARGET" -sdk "$SDK" -O \
  $FILES "$WORK/tool/main.swift" "$WORK/stub.o" "$WORK/CassowaryC.o" -o "$WORK/simperf"
UDID=$(xcrun simctl list devices available | grep -m1 "$DEVICE" | sed -E 's/.*\(([0-9A-Fa-f-]+)\).*/\1/')
[ -n "$UDID" ] || { echo "No available simulator named '$DEVICE'" >&2; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl spawn "$UDID" "$WORK/simperf" "${@:2}"
