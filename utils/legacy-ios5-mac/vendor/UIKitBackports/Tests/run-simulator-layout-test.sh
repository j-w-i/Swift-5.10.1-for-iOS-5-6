#!/bin/bash
# Simulator regression test for the iOS 5 UIView hook crash (UIStackView path).
#
#   Tests/run-simulator-hook-test.sh [SIMULATOR_DEVICE_NAME]
#
# Builds the staged LegacyAutoLayout/Cassowary sources plus
# autolayout_simulator_layout_test.swift for the current Xcode's iPhoneSimulator SDK
# (system toolchain; the legacy device toolchain has no simulator stdlib), boots a
# simulator, force-installs the legacy bridge and runs the injected-hook test.
#
# The test source is compiled into the same module as the backport so the
# internal force-install/audit entry points are reachable, exactly like the
# legacy-name app path on iOS 5.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
VENDOR=$(CDPATH= cd -- "$HERE/.." && pwd -P)
DEVICE=${1:-iPhone SE (3rd generation)}
WORK=${TMPDIR:-/tmp}/legacy-ios5-sim-layout-test
rm -rf "$WORK"; mkdir -p "$WORK/src" "$WORK/tool"
PY=${PYTHON:-python3}
"${PY:-python3}" - "$VENDOR" "$WORK/src" <<'PYSTAGE'
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
# Optional: stage a different LegacyAutoLayoutSwizzling.swift (used by the
# harness to prove the test catches the pre-fix sibling-dispatch crash).
if [ -n "${SWIZZLING_OVERRIDE:-}" ]; then
  cp "$SWIZZLING_OVERRIDE" "$WORK/src/LegacyAutoLayout-LegacyAutoLayoutSwizzling.swift"
fi
cp "$HERE/autolayout_simulator_layout_test.swift" "$WORK/tool/main.swift"
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
  $FILES "$WORK/tool/main.swift" "$WORK/stub.o" "$WORK/CassowaryC.o" -o "$WORK/simrun"
UDID=$(xcrun simctl list devices available | grep -m1 "$DEVICE" | sed -E 's/.*\(([0-9A-Fa-f-]+)\).*/\1/')
[ -n "$UDID" ] || { echo "No available simulator named '$DEVICE'" >&2; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
OUTPUT=$(xcrun simctl spawn "$UDID" "$WORK/simrun" 2>&1)
echo "$OUTPUT"
grep -q "layout: PASS" <<< "$OUTPUT" || { echo 'FAIL: legacy engine did not solve the login-shaped layout' >&2; exit 1; }
echo "PASS: simulator layout regression test (frames solved for login-shaped hierarchies)"
