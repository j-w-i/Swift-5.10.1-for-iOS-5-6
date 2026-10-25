#!/bin/bash
set -euo pipefail
B="$HOME/swift-5.10-ios5-build"
export DEVELOPER_DIR="$HOME/Applications/Xcode-13.4.1.app/Contents/Developer"
SDK="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk"
CC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
OLD="$HOME/swift-ios5-build/build/runtime-ios5"
OBJS="$OLD/stdlib/public/Darwin/Foundation/CMakeFiles/swiftFoundation-iphoneos-armv7.dir"
exec /usr/bin/nice -n 15 "$CC" -target armv7-apple-ios7.0 -isysroot "$SDK" -dynamiclib \
 "$B/probes/Foundation510.o" "$OBJS/BundleLookup.mm.o" "$OBJS/DataThunks.m.o" "$OBJS/NSError.mm.o" "$OBJS/CheckClass.mm.o" \
 -o "$B/probes/libswiftFoundation510.dylib" \
 -L "$OLD/lib/swift/iphoneos" -lswiftCore -lswiftDarwin -lswiftObjectiveC -lswiftCoreFoundation -lswiftCoreGraphics \
 "$B/probes/libswiftDispatch510.dylib" -framework Foundation -framework CoreFoundation -framework CoreGraphics -lobjc -lSystem -lc++ \
 -Wl,-install_name,@rpath/libswiftFoundation.dylib \
 -Wl,-force_load,"$HOME/swift-ios5-build/build/crt-armv7-ios50/libclang_rt.builtins_armv7_ios.a"
