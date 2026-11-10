#!/bin/bash
# run.sh SRC.swift [TC] : build with scratch toolchain and run on the iPod (iOS 5.1.1)
set -euo pipefail
SRC=$1; TC=${2:-/tmp/tc-conc/swift-5.10.1-ios5.xctoolchain}
RES=$TC/usr/lib/swift_ios5
XC=/Users/jwalr/Applications/Xcode-13.4.1.app/Contents/Developer; SDK=$XC/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
CLANG=$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang; CLANG_RES=$(ls -d "$TC"/usr/lib/clang/*/ | head -1)
CONC=${CONC_DYLIB:-/Users/jwalr/Developer/legacy-build-fix7/build/runtime510-ios5/lib/swift/iphoneos/armv7/libswift_Concurrency.dylib}
NAME=$(basename $SRC .swift); OUT=$(dirname $0)/out; mkdir -p $OUT; cp $SRC $OUT/main.swift
$TC/usr/bin/swiftc -c $OUT/main.swift -module-name $NAME -target armv7-apple-ios5.0 -sdk $SDK -enable-legacy-ios5-runtime -resource-dir $RES -Xcc -resource-dir -Xcc $CLANG_RES -Xcc -I$RES/legacy-overlay-shims -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements -Xfrontend -disable-autolink-library -Xfrontend swiftFileProvider ${SWIFT_EXTRA:-} -o $OUT/main.o
LIBS=(); for l in Core Foundation Dispatch ObjectiveC CoreFoundation CoreGraphics Darwin; do LIBS+=("-lswift$l"); done
cp $CONC $OUT/libswift_Concurrency.dylib
$CLANG -target armv7-apple-ios5.0 -isysroot $SDK -nostartfiles -Wl,-no_new_main -L $RES/iphoneos -L $OUT $OUT/main.o $RES/iphoneos/crt1.3.1.o $RES/iphoneos/libswiftLegacyIOS5Backports.a "${LIBS[@]}" -lswift_Concurrency -lobjc -lSystem -Wl,-rpath,@executable_path/Frameworks -o $OUT/$NAME 2>&1 | grep -v "deprecated\|libLTO\|warning" || true
ldid -S $OUT/$NAME; ldid -S $OUT/libswift_Concurrency.dylib
B=/Users/jwalr/Developer/Neocord2-iOS5-Work/device-bridge
ssh_() { ssh -p 2225 -i $B/device-key -o BatchMode=yes -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa -o UserKnownHostsFile=/tmp/legacy-ipod-known-hosts root@127.0.0.1 "$@"; }
ssh_ 'mkdir -p /var/root/n2conc/Frameworks'
put() { cat "$1" | ssh_ "cat > /var/root/n2conc/$2.new && chmod 755 /var/root/n2conc/$2.new && mv /var/root/n2conc/$2.new /var/root/n2conc/$2"; }
put $OUT/$NAME $NAME
for lib in libswift_Concurrency.dylib; do put $OUT/$lib Frameworks/$lib; done
for lib in $(xcrun otool -L $OUT/$NAME | grep '@rpath' | sed -E 's/.*@rpath\/([^ ]+).*/\1/'); do [ -f $RES/iphoneos/$lib ] && { ldid -S $RES/iphoneos/$lib 2>/dev/null || true; put $RES/iphoneos/$lib Frameworks/$lib; }; done
for lib in $(xcrun otool -L $OUT/libswift_Concurrency.dylib | grep '@rpath' | sed -E 's/.*@rpath\/([^ ]+).*/\1/'); do [ -f $RES/iphoneos/$lib ] && put $RES/iphoneos/$lib Frameworks/$lib; done
ssh_ "cd /var/root/n2conc && ./$NAME 2>&1; echo EXIT=\$?"
