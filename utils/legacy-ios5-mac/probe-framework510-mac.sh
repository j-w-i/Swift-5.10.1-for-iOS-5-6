#!/bin/bash
set -euo pipefail
B="$HOME/swift-5.10-ios5-build"
export DEVELOPER_DIR="$HOME/Applications/Xcode-13.4.1.app/Contents/Developer"
HOST="$HOME/Library/Developer/Toolchains/swift-5.10.1-RELEASE.xctoolchain/usr/bin/swiftc"
SDK="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk"
R="$B/probes/modules510"
NAME=${1:?framework name}; shift
shopt -s nullglob
SOURCES=("$B/src/legacy-overlays/$NAME/"*.swift)
if [ "${#SOURCES[@]}" -eq 0 ]; then
  SOURCES=("$@"); set --
fi
mkdir -p "$R/iphoneos/$NAME.swiftmodule"
exec /usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$HOST" -j1 -parse-as-library -module-name "$NAME" \
 -target armv7-apple-ios7.0 -sdk "$SDK" -resource-dir "$R" -D LEGACY_IOS5 \
 -I "$B/probes/dispatch-shims" -Xcc -I"$R/iphoneos" \
 -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements \
 -enable-library-evolution -O -whole-module-optimization -emit-object -o "$B/probes/${NAME}510.o" \
 -emit-module -emit-module-path "$R/iphoneos/$NAME.swiftmodule/armv7.swiftmodule" \
 -module-link-name "swift$NAME" -swift-version 5 "${SOURCES[@]}" ${1+"$@"}
