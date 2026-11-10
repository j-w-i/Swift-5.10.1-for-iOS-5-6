#!/bin/bash
# Run device-built arm64 test code against private simulator-retagged runtime copies.
# This tests the embedded runtime, not Apple's simulator Swift overlays.
set -euo pipefail
SRC=${1:?usage: run-on-simulator.sh SOURCE TOOLCHAIN SIMULATOR_UDID}
TC=${2:?}; SIM=${3:?}
HERE=$(cd "$(dirname "$0")" && pwd -P)
SDK=${LEGACY_SDK:-$HOME/Applications/Xcode-13.4.1.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk}
RES="$TC/usr/lib/swift_ios5"
W=$(mktemp -d /tmp/legacy-async-sim.XXXXXX)
# Keep this private directory as reproducible evidence; never change toolchain files.
printf 'Evidence directory: %s\n' "$W"
mkdir -p "$W/Frameworks"
cp "$SRC" "$W/main.swift"
CLANG_RES=$(ls -d "$TC"/usr/lib/clang/*/ | tail -1)
"$TC/usr/bin/swiftc" -target arm64-apple-ios7.0 -sdk "$SDK" \
 -enable-legacy-ios5-runtime -resource-dir "$RES" -Xcc -resource-dir -Xcc "$CLANG_RES" \
 -Xcc -I"$RES/legacy-overlay-shims" -runtime-compatibility-version none \
 -disable-autolinking-runtime-compatibility-dynamic-replacements \
 -Xfrontend -disable-autolink-library -Xfrontend swiftFileProvider \
 "$W/main.swift" -o "$W/test" -L "$RES/iphoneos" -Xlinker -rpath -Xlinker @executable_path/Frameworks
for f in "$RES/iphoneos/"*.dylib; do
 lipo "$f" -thin arm64 -output "$W/Frameworks/$(basename "$f")"
done
for f in "$W/test" "$W/Frameworks/"*.dylib; do
 vtool -set-build-version 7 15.0 19.0 -replace -output "$f.sim" "$f"
 # Both paths are verified children of this fresh private directory.
 [[ "$f" = "$W/"* ]] || exit 2
 mv "$f.sim" "$f"
 codesign -f -s - "$f"
done
xcrun simctl spawn "$SIM" "$W/test"
