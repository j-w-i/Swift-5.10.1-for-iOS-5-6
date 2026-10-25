#!/bin/bash
set -euo pipefail
B="$HOME/swift-5.10-ios5-build"
export DEVELOPER_DIR="$HOME/Applications/Xcode-13.4.1.app/Contents/Developer"
SRC="$B/src/legacy-overlays/Dispatch"
HOST="$HOME/Library/Developer/Toolchains/swift-5.10.1-RELEASE.xctoolchain/usr/bin/swiftc"
SDK="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk"
R="$B/probes/modules510"
mkdir -p "$R/iphoneos/Dispatch.swiftmodule"
exec /usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$HOST" -j1 -parse-as-library -module-name Dispatch \
 -target armv7-apple-ios7.0 -sdk "$SDK" -resource-dir "$R" -D LEGACY_IOS5 \
 -Xcc -DOS_OBJECT_USE_OBJC=0 -Xcc -DSWIFT_LEGACY_IOS5_CDISPATCH=1 \
 -Xcc -I"$R/iphoneos" -I "$B/probes/dispatch-shims" -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements \
 -enable-library-evolution -O -emit-module -emit-object \
 -emit-module-path "$R/iphoneos/Dispatch.swiftmodule/armv7.swiftmodule" \
 -whole-module-optimization -o "$B/probes/Dispatch510.o" "$SRC/"*.swift
