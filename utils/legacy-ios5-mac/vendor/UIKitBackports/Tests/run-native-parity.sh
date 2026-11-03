#!/bin/bash
# Native-vs-backport parity on real UIKit controls (simulator). Fails on any frame difference.
#   Tests/run-native-parity.sh [SIMULATOR_DEVICE_NAME]
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SIM=$(sed -e 's#autolayout_simulator_hook_test.swift#autolayout_native_parity.swift#; s#legacy-ios5-sim-hook-test#legacy-ios5-native-parity#' "$HERE/run-simulator-hook-test.sh")
python3 - "$HERE" "$SIM" <<'PY'
import sys
here, text = sys.argv[1], sys.argv[2]
i = text.index('UDID=$(xcrun')
open(here + '/.native-parity-build.sh', 'w').write(text[:i])
PY
bash "$HERE/.native-parity-build.sh" >/dev/null 2>&1 || { bash "$HERE/.native-parity-build.sh" 2>&1 | grep -E 'error' | head; exit 1; }
rm -f "$HERE/.native-parity-build.sh"
WORK=${TMPDIR:-/tmp}/legacy-ios5-native-parity
DEVICE=${1:-iPhone SE (3rd generation)}
UDID=$(xcrun simctl list devices available | grep -m1 "$DEVICE" | sed -E 's/.*\(([0-9A-Fa-f-]+)\).*/\1/')
xcrun simctl boot "$UDID" 2>/dev/null || true; xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl spawn "$UDID" "$WORK/simrun" native > "$WORK/native.txt"
xcrun simctl spawn "$UDID" "$WORK/simrun" legacy > "$WORK/legacy.txt"
if diff -u "$WORK/native.txt" "$WORK/legacy.txt" > "$WORK/diff.txt"; then
  echo "PASS: native and backport frames identical ($(wc -l < "$WORK/native.txt") frames)"
else
  echo "FAIL: backport differs from native UIKit:"; cat "$WORK/diff.txt"; exit 1
fi
