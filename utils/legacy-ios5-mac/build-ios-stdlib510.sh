#!/bin/bash
# Build the Swift 5.10.1 iOS standard library from source for armv7, armv7s and arm64.
#
# This replaces the pinned prebuilt "baseline" package (swift-5.10.1-ios6.pkg) that used to be
# downloaded and used as the toolchain's default resource tree. The standard library, its modules
# and compiler-rt builtins are all compiled here with the just-built host compiler and clang; the
# only SDK input is the pinned theos iPhoneOS13.7 SDK (armv7-capable) plus libc++ headers from the
# selected Xcode's iOS SDK.
#
# Output: <LEGACY_BUILD_ROOT>/out/ios-stdlib/lib/swift/iphoneos - one merged resource tree with
# per-arch dylib directories, per-arch module files and fat (armv7+armv7s+arm64) dylibs/archives.
#
# Usage: build-ios-stdlib510.sh
# Required: LEGACY_BUILD_ROOT, XCODE_13_4_1_DEVELOPER_DIR; JOBS optional.
# Idempotent: per-arch build directories and archives are reused once complete.
set -euo pipefail

B="${LEGACY_BUILD_ROOT:?set LEGACY_BUILD_ROOT}"
XC="${XCODE_13_4_1_DEVELOPER_DIR:?set XCODE_13_4_1_DEVELOPER_DIR to Xcode 13.4.1/Contents/Developer}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

CM="$B/tools/cmake/CMake.app/Contents/bin/cmake"
NINJA="$B/tools/ninja"
L="$B/build/llvm"
S="$B/build/swift"
C="$B/build/cmark"
SDK="$B/src/theos-sdks/iPhoneOS13.7.sdk"
HOST_SWIFT="$B/host/swift-5.10.1-RELEASE.xctoolchain/usr/bin/swiftc"
OUT="$B/out/ios-stdlib"
ARCHS="armv7 armv7s arm64"

[ -x "$CM" ] || { echo "missing build tools (run the tools stage): $CM" >&2; exit 1; }
[ -d "$SDK" ] || { echo "missing pinned SDK: $SDK" >&2; exit 1; }
[ -d "$B/src/llvm-project/compiler-rt/lib/builtins" ] || { echo "missing compiler-rt sources" >&2; exit 1; }
[ -x "$HOST_SWIFT" ] || { echo "missing bootstrap Swift compiler: $HOST_SWIFT" >&2; exit 1; }
[ -x "$S/bin/swift-frontend" ] || { echo "missing built swift-frontend (run swift-510)" >&2; exit 1; }

# The theos SDK ships libc++ stubs but not libc++ headers, so C++ standard headers are missing from
# the sysroot. Point the SDK's c++ include directory at the selected Xcode's iOS SDK headers; this is
# a header-only input (the armv7 libc++ library still comes from the pinned SDK).
IOS_HEADERS="$(ls -d "$XC"/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS*.sdk 2>/dev/null | sort -V | tail -1)/usr/include/c++/v1"
[ -d "$IOS_HEADERS" ] || { echo "no libc++ headers in the Xcode iOS SDK under $XC" >&2; exit 1; }
mkdir -p "$SDK/usr/include/c++"
if [ ! -e "$SDK/usr/include/c++/v1" ]; then
  ln -s "$IOS_HEADERS" "$SDK/usr/include/c++/v1"
  echo "linked libc++ headers into the pinned SDK: $SDK/usr/include/c++/v1 -> $IOS_HEADERS"
fi

# CMake on an Apple Silicon host injects -arch <host> into compile lines; the Swift stdlib build also
# adds -target <arch>-apple-ios, which clang rejects. The wrapper drops the injected host arch only
# for cross-target compiles.
W="$B/tools/llvm-wrapped-bin"
if [ ! -x "$W/clang-wrap" ]; then
  mkdir -p "$W"
  for f in "$L"/bin/*; do n="$(basename "$f")"; case "$n" in clang|clang++) ;; *) ln -sfn "$f" "$W/$n" ;; esac; done
  cp "$HERE/clang-wrap" "$W/clang-wrap"
  for n in clang clang++; do
    printf '#!/bin/bash\nCLANG_WRAP_REAL=%s/bin/%s exec %s/clang-wrap "$@"\n' "$L" "$n" "$W" > "$W/$n"
    chmod +x "$W/$n"
  done
fi

export DEVELOPER_DIR="$XC"
export SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"

# 1. compiler-rt builtins per arch: Float16 conversions (___extendhfsf2/___truncdfhf2/___truncsfhf2)
#    and ___isPlatformVersionAtLeast are not provided by libSystem at the 7.0 floor on 32-bit ARM.
for ARCH in $ARCHS; do
  CRT="$B/build/crt-510-$ARCH-ios70"
  [ -s "$CRT/libclang_rt.builtins_${ARCH}_ios.a" ] && { echo "builtins $ARCH: present"; continue; }
  echo "== compiler-rt builtins $ARCH"
  mkdir -p "$CRT"
  /usr/bin/arch -x86_64 "$CM" -G Ninja -S "$B/src/llvm-project/compiler-rt/lib/builtins" -B "$CRT" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_C_COMPILER="$W/clang" -DCMAKE_ASM_COMPILER="$W/clang" \
    -DCMAKE_C_COMPILER_TARGET="$ARCH-apple-ios7.0" -DCMAKE_ASM_COMPILER_TARGET="$ARCH-apple-ios7.0" \
    -DCMAKE_AR="$L/bin/llvm-ar" -DCMAKE_RANLIB="$L/bin/llvm-ranlib" -DCMAKE_NM="$L/bin/llvm-nm" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
    -DCMAKE_C_FLAGS="-isysroot $SDK -miphoneos-version-min=7.0" \
    -DCMAKE_ASM_FLAGS="-isysroot $SDK -miphoneos-version-min=7.0" \
    -DLLVM_CONFIG_PATH="$L/bin/llvm-config"
  /usr/bin/arch -x86_64 "$NINJA" -C "$CRT" -j"$JOBS" "libclang_rt.builtins_${ARCH}_ios.a"
done

# 2. the standard library itself, one build directory per arch.
for ARCH in $ARCHS; do
  O="$B/build/ios-stdlib-$ARCH"; [ "$ARCH" = armv7 ] && O="$B/build/ios-stdlib"
  [ -d "$O/lib/swift/iphoneos/$ARCH" ] && { echo "stdlib $ARCH: present"; continue; }
  echo "== Swift stdlib $ARCH"
  mkdir -p "$O"
  /usr/bin/arch -x86_64 "$CM" -G Ninja -S "$B/src/swift" -B "$O" \
    -DCMAKE_MAKE_PROGRAM="$NINJA" -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_C_COMPILER="$W/clang" -DCMAKE_CXX_COMPILER="$W/clang++" -DCMAKE_Swift_COMPILER="$HOST_SWIFT" \
    -DCMAKE_OSX_SYSROOT="$SDKROOT" -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$B/build/crt-510-$ARCH-ios70 -lclang_rt.builtins_${ARCH}_ios -Wl,-U,_objc_setHook_lazyClassNamer -Wl,-U,__dyld_is_objc_constant" \
    -DCMAKE_CXX_FLAGS=-DSWIFT_STDLIB_LEGACY_SDK_OBJC_HOOK=1 -DCMAKE_C_FLAGS=-DSWIFT_STDLIB_LEGACY_SDK_OBJC_HOOK=1 \
    -DSWIFT_BUILD_SWIFT_SYNTAX=OFF -DSWIFT_INCLUDE_TOOLS=OFF -DSWIFT_INCLUDE_TEST_BINARIES=OFF \
    -DSWIFT_DARWIN_STDLIB_INSTALL_NAME_DIR=@rpath -DSWIFT_DARWIN_STDLIB_PRIVATE_INSTALL_NAME_DIR=@rpath \
    -DSWIFT_SDKS=IOS -DSWIFT_SDK_IOS_PATH="$SDK" -DSWIFT_DARWIN_DEPLOYMENT_VERSION_IOS=7.0 \
    -DSWIFT_DARWIN_SUPPORTED_ARCHS="$ARCH" -DSWIFT_ENABLE_LEGACY_IOS5_CLASS_MARKING=OFF \
    -DSWIFT_ENABLE_EXPERIMENTAL_CONCURRENCY=ON -DSWIFT_ENABLE_EXPERIMENTAL_STRING_PROCESSING=ON \
    -DSWIFT_ENABLE_EXPERIMENTAL_DIFFERENTIABLE_PROGRAMMING=ON -DSWIFT_ENABLE_EXPERIMENTAL_DISTRIBUTED=ON \
    -DSWIFT_ENABLE_EXPERIMENTAL_OBSERVATION=ON -DSWIFT_ENABLE_EXPERIMENTAL_CXX_INTEROP=ON \
    -DSWIFT_ENABLE_BACKTRACING=ON \
    -DSWIFT_INCLUDE_APINOTES=ON -DSWIFT_BUILD_STDLIB=ON -DSWIFT_BUILD_SDK_OVERLAY=ON \
    -DSWIFT_BUILD_DYNAMIC_STDLIB=ON -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=ON \
    -DSWIFT_BUILD_REMOTE_MIRROR=OFF -DSWIFT_BUILD_SOURCEKIT=OFF -DSWIFT_INCLUDE_TESTS=OFF -DSWIFT_INCLUDE_DOCS=OFF \
    -DLLVM_DIR="$L/lib/cmake/llvm" -DClang_DIR="$L/lib/cmake/clang" \
    -DSWIFT_PATH_TO_CMARK_BUILD="$C" -DSWIFT_PATH_TO_CMARK_SOURCE="$B/src/cmark" \
    -DSWIFT_PATH_TO_SWIFT_SYNTAX_SOURCE="$B/src/swift-syntax" \
    -DSWIFT_PATH_TO_STRING_PROCESSING_SOURCE="$B/src/string-processing" \
    -DSWIFT_NATIVE_LLVM_TOOLS_PATH="$W" -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$W" -DSWIFT_NATIVE_SWIFT_TOOLS_PATH="$S/bin" \
    -DSWIFT_PRIMARY_VARIANT_SDK=IOS -DSWIFT_PRIMARY_VARIANT_ARCH="$ARCH"
  /usr/bin/arch -x86_64 "$NINJA" -C "$O" -j"$JOBS" "swift-stdlib-iphoneos-$ARCH"
done

# 3. Merge the per-arch trees into one resource tree, the shape a toolchain expects: per-arch dylib
#    directories, per-arch module files, and fat dylibs/static archives at the iphoneos root.
echo "== merge resources"
rm -rf "$OUT"; mkdir -p "$OUT/lib/swift/iphoneos"
T="$OUT/lib/swift"
cp -R "$B/build/ios-stdlib/lib/swift/apinotes" "$B/build/ios-stdlib/lib/swift/shims" \
      "$B/build/ios-stdlib/lib/swift/module.modulemap" "$T/"
CLANG_VERSION="$(ls -1 "$L/lib/clang" | sort -V | tail -1)"
ln -sfn "../clang/$CLANG_VERSION" "$T/clang"
for ARCH in $ARCHS; do
  O="$B/build/ios-stdlib-$ARCH"; [ "$ARCH" = armv7 ] && O="$B/build/ios-stdlib"
  SRC="$O/lib/swift/iphoneos"
  cp -R "$SRC/$ARCH" "$T/iphoneos/"
  cp "$SRC/layouts-$ARCH.yaml" "$T/iphoneos/"
  for m in "$SRC"/*.swiftmodule; do n="$(basename "$m")"; mkdir -p "$T/iphoneos/$n"; cp -R "$m/." "$T/iphoneos/$n/"; done
done
for f in "$B/build/ios-stdlib/lib/swift/iphoneos/armv7"/*.dylib; do
  name="$(basename "$f")"; parts=("$f")
  for ARCH in armv7s arm64; do p="$B/build/ios-stdlib-$ARCH/lib/swift/iphoneos/$ARCH/$name"; [ -f "$p" ] && parts+=("$p"); done
  if [ "${#parts[@]}" -gt 1 ]; then lipo -create "${parts[@]}" -output "$T/iphoneos/$name"
  else cp "$f" "$T/iphoneos/$name"; fi
done
for a in "$B/build/ios-stdlib/lib/swift/iphoneos"/*.a; do
  name="$(basename "$a")"; parts=("$a")
  for ARCH in armv7s arm64; do p="$B/build/ios-stdlib-$ARCH/lib/swift/iphoneos/$name"; [ -f "$p" ] && parts+=("$p"); done
  if [ "${#parts[@]}" -gt 1 ]; then lipo -create "${parts[@]}" -output "$T/iphoneos/$name"
  else cp "$a" "$T/iphoneos/$name"; fi
done
echo "merged $(ls "$T/iphoneos"/*.dylib | wc -l | tr -d ' ') fat dylibs, $(ls -d "$T/iphoneos"/*.swiftmodule | wc -l | tr -d ' ') modules into $T/iphoneos"
