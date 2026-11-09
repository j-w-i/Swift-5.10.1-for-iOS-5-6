#!/bin/bash
# Build the Swift 5.10.1 standard library for the legacy iOS 5.0 armv7 slice (class-marking ABI, ARM
# mode, iOS 5-era libc++ headers, deployment target 5.0). This is the armv7 base runtime of the
# assembled toolchain; the armv7s/arm64 slices come from build-ios-stdlib510.sh.
#
# Output: $LEGACY_BUILD_ROOT/build/runtime510-ios5  (lib/swift/iphoneos/{libswiftCore,Darwin,
#         SwiftOnoneSupport,...}.dylib and armv7 modules). Recipe recovered from the CMake cache of the
#         hand-built tree this replaces; see RUNTIME-510-PATCHES.md.
# Required: LEGACY_BUILD_ROOT, XCODE_13_4_1_DEVELOPER_DIR. Needs stages tools, swift-510, fetch-515,
#           crt-515 (compiler-rt for armv7 iOS 5.0 and the iOS 5-era libc++ headers).
set -euo pipefail
B="${LEGACY_BUILD_ROOT:?set LEGACY_BUILD_ROOT}"
XC="${XCODE_13_4_1_DEVELOPER_DIR:?set XCODE_13_4_1_DEVELOPER_DIR}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
CM="$B/tools/cmake/CMake.app/Contents/bin/cmake"; NINJA="$B/tools/ninja"
L="$B/build/llvm"; S="$B/build/swift"; C="$B/build/cmark"
O="$B/build/runtime510-ios5"
SDK="$XC/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk"
CLANG="$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"; CLANGXX="$CLANG++"
LIBCXX="$B/b515/src/llvm-project/libcxx/include"
CRT="$B/b515/build/crt-armv7-ios50/lib/darwin/libclang_rt.ios.a"
[ -f "$CRT" ] || CRT="$(ls "$B"/b515/build/macos/llvm-macosx-x86_64/lib/clang/*/lib/darwin/libclang_rt.ios.a 2>/dev/null | head -1)"
HOST_SWIFT="$B/host/swift-5.10.1-RELEASE.xctoolchain/usr/bin/swiftc"
for p in "$CM" "$NINJA" "$S/bin/swift-frontend" "$S/bin/swiftc" "$LIBCXX" "$CRT" "$HOST_SWIFT"; do
  [ -e "$p" ] || { echo "missing: $p" >&2; exit 1; }
done
[ ! -d "$O/lib/swift/iphoneos/armv7" ] || { echo "legacy core: present"; exit 0; }

# Target compiler: the driver with the legacy opt-ins, as an executable path (CMake needs one file).
W="$B/tools/ios5-native"; mkdir -p "$W"
ln -sfn "$S/bin/swift-frontend" "$W/swift-frontend"
cat > "$W/swiftc" <<WRAP
#!/bin/sh
# Target compiler for the iOS 5 stdlib build. Executed as swiftc so the driver validates the
# deployment target and forwards frontend options; the legacy iOS 5 runtime and class-marking
# modes are explicit opt-ins on this fork and only valid for an iOS armv7 target. CMake also runs
# this compiler for its own host self-test, which must not receive them.
case "\$*" in
  *apple-ios*) exec "$S/bin/swiftc" "\$@" -enable-legacy-ios5-runtime -enable-legacy-ios5-class-marking ;;
  *) exec "$S/bin/swiftc" "\$@" ;;
esac
WRAP
chmod +x "$W/swiftc"
cp "$W/swiftc" "$B/tools/swiftc-ios5"

export DEVELOPER_DIR="$XC"
mkdir -p "$O"
/usr/bin/arch -x86_64 "$CM" -G Ninja -S "$B/src/swift" -B "$O" \
  -DCMAKE_MAKE_PROGRAM="$NINJA" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_C_COMPILER="$CLANG" -DCMAKE_CXX_COMPILER="$CLANGXX" -DCMAKE_Swift_COMPILER="$B/tools/swiftc-ios5" \
  -DCMAKE_OSX_SYSROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)" -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DCMAKE_C_FLAGS="-marm" \
  -DCMAKE_CXX_FLAGS="-marm -nostdinc++ -isystem $LIBCXX -stdlib=libc++" \
  -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-force_load,$CRT" \
  -DSWIFT_ENABLE_LEGACY_IOS5_CLASS_MARKING=ON -DSWIFT_ENABLE_IOS32=ON \
  -DSWIFT_SDKS=IOS -DSWIFT_SDK_IOS_PATH="$SDK" -DSWIFT_DARWIN_DEPLOYMENT_VERSION_IOS=5.0 \
  -DSWIFT_DARWIN_SUPPORTED_ARCHS=armv7 -DSWIFT_PRIMARY_VARIANT_SDK=IOS -DSWIFT_PRIMARY_VARIANT_ARCH=armv7 \
  -DSWIFT_DARWIN_STDLIB_INSTALL_NAME_DIR=@rpath -DSWIFT_DARWIN_STDLIB_PRIVATE_INSTALL_NAME_DIR=@rpath \
  -DSWIFT_BUILD_SWIFT_SYNTAX=OFF -DSWIFT_INCLUDE_TOOLS=OFF -DSWIFT_INCLUDE_TESTS=OFF -DSWIFT_INCLUDE_DOCS=OFF \
  -DSWIFT_INCLUDE_TEST_BINARIES=OFF -DSWIFT_BUILD_STDLIB=ON -DSWIFT_BUILD_SDK_OVERLAY=ON \
  -DSWIFT_BUILD_DYNAMIC_STDLIB=ON -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=ON -DSWIFT_INCLUDE_APINOTES=ON \
  -DSWIFT_BUILD_REMOTE_MIRROR=OFF -DSWIFT_BUILD_SOURCEKIT=OFF \
  -DSWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY=OFF -DSWIFT_ENABLE_EXPERIMENTAL_STRING_PROCESSING=OFF \
  -DSWIFT_ENABLE_EXPERIMENTAL_DIFFERENTIABLE_PROGRAMMING=OFF -DSWIFT_ENABLE_EXPERIMENTAL_DISTRIBUTED=OFF \
  -DSWIFT_ENABLE_EXPERIMENTAL_OBSERVATION=OFF -DSWIFT_ENABLE_EXPERIMENTAL_CXX_INTEROP=OFF \
  -DSWIFT_ENABLE_BACKTRACING=OFF \
  -DLLVM_DIR="$L/lib/cmake/llvm" -DClang_DIR="$L/lib/cmake/clang" \
  -DSWIFT_PATH_TO_CMARK_BUILD="$C" -DSWIFT_PATH_TO_CMARK_SOURCE="$B/src/cmark" \
  -DSWIFT_PATH_TO_SWIFT_SYNTAX_SOURCE="$B/src/swift-syntax" \
  -DSWIFT_PATH_TO_STRING_PROCESSING_SOURCE="$B/src/string-processing" \
  -DSWIFT_NATIVE_LLVM_TOOLS_PATH="$L/bin" -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$L/bin" -DSWIFT_NATIVE_SWIFT_TOOLS_PATH="$W"
/usr/bin/arch -x86_64 "$NINJA" -C "$O" -j"$JOBS" swift-stdlib-iphoneos-armv7
[ -f "$O/lib/swift/iphoneos/armv7/libswiftCore.dylib" ] || { echo "legacy core was not produced" >&2; exit 1; }
echo "legacy iOS 5.0 armv7 core: $O/lib/swift/iphoneos/armv7/libswiftCore.dylib"
