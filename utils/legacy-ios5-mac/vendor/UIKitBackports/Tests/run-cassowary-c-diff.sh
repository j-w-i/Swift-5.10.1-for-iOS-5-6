#!/bin/bash
# Differential + safety gate for the C Cassowary core. Usage: Tests/run-cassowary-c-diff.sh [SEEDS] [STEPS]
#   1. CassowaryC vs the Swift Solver: every value bit-identical after every operation, same success/failure.
#   2. The same random operations under ASan + UBSan.
#   3. Zero live allocations after repeated solver lifetimes.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P); V=$(dirname "$HERE")
SEEDS=${1:-1000}; STEPS=${2:-150}; W=$(mktemp -d /tmp/cassowary-c-diff.XXXXXX)
mkdir -p "$W/cass" "$W/run"
clang -O2 -ffp-contract=off -c "$V/CassowaryC/CassowaryC.c" -o "$W/CassowaryC.o"
xcrun swiftc -emit-module -emit-library -module-name Cassowary -O "$V"/Cassowary/*.swift "$W/CassowaryC.o" -o "$W/cass/libCassowary.dylib" -emit-module-path "$W/cass/Cassowary.swiftmodule"
printf 'module CassowaryC { header "%s/CassowaryC/CassowaryC.h" export * }\n' "$V" > "$W/module.modulemap"
cp "$HERE/cassowary_c_diff.swift" "$W/run/main.swift"
xcrun swiftc -O -I "$W/cass" -L "$W/cass" -lCassowary -Xcc -fmodule-map-file="$W/module.modulemap" -I "$W" "$W/run/main.swift" -o "$W/run/cdiff"
DYLD_LIBRARY_PATH="$W/cass" "$W/run/cdiff" "$SEEDS" "$STEPS"
xcrun swiftc -O -I "$W/cass" -L "$W/cass" -lCassowary "$HERE/cassowary_shared_constraint.swift" -o "$W/shared"
DYLD_LIBRARY_PATH="$W/cass" "$W/shared"
clang -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -ffp-contract=off -I "$V/CassowaryC" "$HERE/cassowary_c_asan_driver.c" "$V/CassowaryC/CassowaryC.c" -o "$W/asan_driver"
ASAN_OPTIONS=detect_leaks=0 "$W/asan_driver" 400 120
clang -O1 -g -I "$V/CassowaryC" -Wno-implicit-function-declaration "$HERE/cassowary_c_alloc_count.c" -o "$W/count" && "$W/count"
clang -O1 -g -fsanitize=address,undefined -ffp-contract=off -I "$V/CassowaryC" "$HERE/cassowary_presolve_coefficients.c" "$V/CassowaryC/CassowaryC.c" -o "$W/coefficients"
ASAN_OPTIONS=detect_leaks=0 "$W/coefficients"
clang -O1 -g -fsanitize=address,undefined -ffp-contract=off -I "$V/CassowaryC" "$HERE/cassowary_presolve_replay.c" "$V/CassowaryC/CassowaryC.c" -o "$W/replay"
ASAN_OPTIONS=detect_leaks=0 "$W/replay"
echo "Test artifacts: $W"
