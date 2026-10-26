#!/bin/bash
# Usage: bash run-base64-tests.sh /absolute/swiftc /absolute/fresh-output [iterations]
# Optional HOST_SDK/HOST_TARGET select the host SDK/architecture explicitly.
# Exit 0 = exact native parity, 2 = semantic mismatches recorded, other = failure.
set -euo pipefail
[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { echo 'Usage: run-base64-tests.sh SWIFTC OUT [iterations]' >&2; exit 64; }
SWIFTC=$1; OUT=$2; ITERATIONS=${3:-5000}
[[ "$SWIFTC" = /* && "$OUT" = /* ]] && [ -x "$SWIFTC" ] || { echo 'Use absolute paths and an executable compiler.' >&2; exit 64; }
[[ "$ITERATIONS" =~ ^[1-9][0-9]*$ ]] || exit 64
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo 'Refusing existing output; choose a fresh directory.' >&2; exit 1; }
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
LEGACY=$(CDPATH= cd -- "$HERE/../../.." && pwd -P)
SOURCE="$LEGACY/overlays/Foundation/LegacyBase64.swift"
[ -s "$SOURCE" ] || { echo 'Original overlay helper not found.' >&2; exit 1; }
mkdir -p "$(dirname -- "$OUT")"
mkdir "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)
/usr/bin/shasum -a 256 "$SOURCE" > "$OUT/source-before.sha256"
"$SWIFTC" --version > "$OUT/compiler-version.txt" 2>&1
OPTIONS=(-O -swift-version 5 -D LEGACY_IOS5 -module-name LegacyBase64Differential)
if [ -n "${HOST_SDK:-}" ]; then [[ "$HOST_SDK" = /* ]] && [ -d "$HOST_SDK" ] || exit 64; OPTIONS+=(-sdk "$HOST_SDK"); fi
if [ -n "${HOST_TARGET:-}" ]; then OPTIONS+=(-target "$HOST_TARGET"); fi
command=("$SWIFTC" "${OPTIONS[@]}" "$SOURCE" "$HERE/main.swift" -o "$OUT/base64-tests")
(printf '%q ' "${command[@]}"; printf '\n') > "$OUT/compile.command"
"${command[@]}" > "$OUT/compile.log" 2>&1 || { echo "Compile failed; see $OUT/compile.log" >&2; exit 1; }
runner=("$OUT/base64-tests" "$OUT" "$ITERATIONS")
if [ -n "${SIMULATOR_UDID:-}" ]; then
  [[ "${SIMCTL:-}" = /* ]] && [ -x "$SIMCTL" ] || { echo 'Set explicit executable SIMCTL for simulator runs.' >&2; exit 64; }
  runner=("$SIMCTL" spawn "$SIMULATOR_UDID" "${runner[@]}")
fi
(printf '%q ' "${runner[@]}"; printf '\n') > "$OUT/run.command"
set +e
"${runner[@]}" > "$OUT/run.log" 2>&1
status=$?
set -e
/usr/bin/shasum -a 256 "$SOURCE" > "$OUT/source-after.sha256"
cmp "$OUT/source-before.sha256" "$OUT/source-after.sha256" || { echo 'ERROR: original overlay source changed during test.' >&2; exit 1; }
printf '%s\n' "$status" > "$OUT/test-exit-status.txt"
if [ "$status" = 2 ]; then
  printf 'DIFFERENTIAL MISMATCHES recorded (exit 2): %s/results.json and mismatches.json\n' "$OUT"
elif [ "$status" != 0 ]; then
  printf 'Harness failed (exit %s); see %s/run.log\n' "$status" "$OUT" >&2
else
  printf 'PASS: exact native parity; results in %s/results.json\n' "$OUT"
fi
exit "$status"
