#!/bin/bash
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
V=$(dirname "$HERE")
W=$(mktemp -d /tmp/legacy-fitting.XXXXXX)
printf 'enum LegacyAutoLayout { static func ensureInstalled() {} }; func retainNativeAPIBootstrap() {}\n' > "$W/stubs.swift"
clang -O2 -ffp-contract=off -c "$V/CassowaryC/CassowaryC.c" -o "$W/core.o"
xcrun swiftc -O -emit-module -emit-library -module-name Cassowary "$V"/Cassowary/*.swift "$W/core.o" -o "$W/libCassowary.dylib" -emit-module-path "$W/Cassowary.swiftmodule"
cp "$HERE/autolayout_fitting.swift" "$W/main.swift"
SOURCES=()
for f in LegacyLayoutEngine LegacyLayoutGeneration LegacyLayoutItem LegacyLayoutSolver LegacyLayoutStats RRLayoutAttribute RRLayoutConstraint RRLayoutPriority RRLayoutRelation; do
  SOURCES+=("$V/LegacyAutoLayout/$f.swift")
done
xcrun swiftc -O -I "$W" -L "$W" -lCassowary "$W/stubs.swift" "${SOURCES[@]}" "$HERE/AutoLayoutTestSupport.swift" "$W/main.swift" -o "$W/test"
DYLD_LIBRARY_PATH="$W" "$W/test"
printf 'Test artifacts: %s\n' "$W"
