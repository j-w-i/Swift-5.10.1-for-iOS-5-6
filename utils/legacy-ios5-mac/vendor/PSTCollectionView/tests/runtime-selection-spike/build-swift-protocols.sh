#!/bin/bash
# Build-only non-UI protocol identity/cast experiment.
# Usage: build-swift-protocols.sh SDK CLANG CRT_DIR NEW_OUT FRONTEND RESOURCE_DIR COMPAT_DIR STDLIB_DIR
set -euo pipefail
SDK=${1:?SDK}; CC=${2:?clang}; CRT=${3:?crt}; OUT=${4:?new output}; FE=${5:?frontend}; RES=${6:?resources}; COMPAT=${7:?compat}; STDLIB=${8:?stdlib}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[[ "$OUT" = /* && ! -e "$OUT" ]] || { echo 'Use a new absolute output directory' >&2; exit 2; }
mkdir "$OUT"
bash "$HERE/build-full-engine.sh" "$SDK" "$CC" "$CRT" "$OUT/engine"
bash "$HERE/build-swift.sh" "$SDK" "$CC" "$CRT" "$OUT/metadata" "$FE" "$RES" "$COMPAT" "$STDLIB"
cp "$OUT/engine/RuntimeFallback.dylib" "$OUT/RuntimeFallback.dylib"
cp -R "$OUT/metadata/Frameworks" "$OUT/Frameworks"
"$FE" -frontend -c -parse-as-library -suppress-warnings -module-name SwiftProtocolProbe \
 -target armv7-apple-ios5.0 -sdk "$SDK" -resource-dir "$RES" -enable-legacy-ios5-runtime \
 -module-cache-path "$OUT/cache" -import-objc-header "$HERE/swift-protocol-types.h" \
 "$HERE/swift-protocols.swift" -o "$OUT/swift-protocols.o"
"$CC" -target armv7-apple-ios5.0 -marm -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules \
 -Wno-unguarded-availability-new -Wno-nullability-completeness -DROUTE_SWIFT_PROTOCOLS=1 -I "$OUT/engine/generated" \
 -L "$CRT" -Wl,-flat_namespace "$HERE/protocol-identity.m" "$OUT/swift-protocols.o" \
 -framework UIKit -framework Foundation "$OUT/RuntimeFallback.dylib" \
 -L "$RES/iphoneos" -L "$COMPAT" -L "$STDLIB" \
 -lswiftCore -lswiftFoundation -lswiftObjectiveC -lswiftUIKit -lswiftDarwin -lswiftDispatch \
 -lswiftCoreFoundation -lswiftCoreGraphics -lswiftCoreImage -lswiftQuartzCore -lswiftMetal \
 -Wl,-rpath,@executable_path/Frameworks -o "$OUT/swift-protocols"
ldid -S "$OUT/swift-protocols"
tar -czf "$OUT/swift-protocols.tgz" -C "$OUT" Frameworks RuntimeFallback.dylib swift-protocols
echo "Built non-UI Swift protocol identity experiment: $OUT"
