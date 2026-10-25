#!/bin/bash
set -euo pipefail
B="$HOME/swift-5.10-ios5-build"
export DEVELOPER_DIR="$HOME/Applications/Xcode-13.4.1.app/Contents/Developer"
SDK="$DEVELOPER_DIR/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk"
CC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
OLD="$HOME/swift-ios5-build/build/runtime-ios5/lib/swift/iphoneos"
# A link experiment, not a qualified runtime; module object was generated without new class marking until patched compiler built.
exec /usr/bin/nice -n 15 "$CC" -target armv7-apple-ios7.0 -isysroot "$SDK" -dynamiclib \
 "$B/probes/Dispatch510.o" -o "$B/probes/libswiftDispatch510.dylib" \
 -L "$OLD" -lswiftCore -lswiftDarwin -lswiftObjectiveC -lobjc -lSystem \
 -Wl,-install_name,@rpath/libswiftDispatch.dylib \
 -Wl,-force_load,"$HOME/swift-ios5-build/build/crt-armv7-ios50/libclang_rt.builtins_armv7_ios.a"
