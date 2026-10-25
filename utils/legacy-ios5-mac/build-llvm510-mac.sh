#!/bin/bash
# Isolated x86_64 LLVM/Clang build; never changes xcode-select or installed toolchains.
set -euo pipefail
B="${LEGACY_BUILD_ROOT:?set LEGACY_BUILD_ROOT (see README)}"
export DEVELOPER_DIR="${XCODE_13_4_1_DEVELOPER_DIR:?set XCODE_13_4_1_DEVELOPER_DIR to Xcode 13.4.1/Contents/Developer}"
CM="$(command -v cmake)"; NINJA="$(command -v ninja)"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
CC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
mkdir -p "$B/build/llvm" "$B/logs"
/usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$CM" -S "$B/src/llvm-project/llvm" -B "$B/build/llvm" -G Ninja \
 -DCMAKE_MAKE_PROGRAM="$NINJA" -DCMAKE_BUILD_TYPE=Release \
 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="${CC}++" \
 -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
 -DLLVM_ENABLE_PROJECTS=clang -DLLVM_TARGETS_TO_BUILD='X86;ARM;AArch64' \
 -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
 -DCLANG_INCLUDE_TESTS=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_ZLIB=OFF \
 -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_PARALLEL_LINK_JOBS=1
exec /usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$NINJA" -C "$B/build/llvm" -j4 clang llvm-tblgen llvm-config llvm-ar llvm-ranlib llvm-nm llvm-objdump
