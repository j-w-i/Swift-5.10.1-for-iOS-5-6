#!/bin/bash
# run-sim-gates.sh RUNTIME_DIR [SIMULATOR_UDID]
# Dynamic gates on a modern iOS Simulator using the *shipping* 64-bit runtime dylibs (retagged for the
# simulator). RUNTIME_DIR is a directory of fat libswift*.dylib (e.g. <toolchain>/usr/lib/swift_ios5/iphoneos).
# Compiles the gate with the legacy compiler and runs it; any trap or abort fails the gate.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
RT=${1:?usage: run-sim-gates.sh RUNTIME_DIR [SIM_UDID]}; SIM=${2:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)}
[ -n "$SIM" ] || { echo 'no booted simulator' >&2; exit 2; }
TC=${LEGACY_TOOLCHAIN:?set LEGACY_TOOLCHAIN to the 5.10.1-ios5.xctoolchain/usr dir}
SDK=${LEGACY_SDK:?set LEGACY_SDK to the iPhoneOS SDK}
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/links" "$W/pkg/Frameworks"; ln -s "$TC/lib/swift_ios5" "$W/links/res"; ln -s "$(ls -d "$TC"/lib/clang/*/ | tail -1)" "$W/links/clang"; ln -s "$TC/lib/swift_ios5/legacy-overlay-shims" "$W/links/shims"
"$TC/bin/swiftc" -target arm64-apple-ios7.0 -sdk "$SDK" -enable-legacy-ios5-runtime -resource-dir "$W/links/res" -Xcc -resource-dir -Xcc "$W/links/clang" -Xcc -I"$W/links/shims" \
  -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements \
  $(for l in swiftCoreMIDI swiftsimd swiftUniformTypeIdentifiers swiftos swiftAccelerate swiftCoreLocation; do printf -- '-Xfrontend -disable-autolink-library -Xfrontend %s ' $l; done) \
  -O "$HERE/cast-corruption.swift" -o "$W/pkg/gate" -L "$RT" -Xlinker -rpath -Xlinker @executable_path/Frameworks || { echo 'gate failed to compile' >&2; exit 1; }
for f in "$RT"/*.dylib; do lipo "$f" -thin arm64 -output "$W/pkg/Frameworks/$(basename "$f")" || exit 1; done
# Kit bundle: Resources/Tools; toolchain repo: next to qualify-ios5.sh.
SCRIPT=$(dirname "$HERE")/../Tools/strip-system-swift-deps.py; [ -f "$SCRIPT" ] || SCRIPT="$(dirname "$HERE")/strip-system-swift-deps.py"
/usr/bin/python3 "$SCRIPT" --reexport-core --drop-system-swift-rpath --linked-sdk=19.0 "$W/pkg/gate" "$W/pkg/Frameworks/"*.dylib >/dev/null || exit 1
for f in "$W/pkg/gate" "$W/pkg/Frameworks/"*.dylib; do vtool -set-build-version 7 15.0 19.0 -replace -output "$f.v" "$f" >/dev/null 2>&1 && mv "$f.v" "$f"; codesign -f -s - "$f" >/dev/null 2>&1; done
OUT=$(xcrun simctl spawn "$SIM" "$W/pkg/gate" 2>&1 | grep -v 'implemented in both')
echo "$OUT" | tail -3
echo "$OUT" | grep -q 'GATE cast-corruption OK' && { echo 'PASS: simulator runtime gates'; exit 0; }
echo 'GATE FAIL: cast-corruption' >&2; exit 1
