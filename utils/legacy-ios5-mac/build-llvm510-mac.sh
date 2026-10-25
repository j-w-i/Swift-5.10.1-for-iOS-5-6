#!/bin/bash
# Isolated x86_64 LLVM/Clang build; never changes xcode-select or installed toolchains.
set -euo pipefail
B="$HOME/swift-5.10-ios5-build"
export DEVELOPER_DIR="$HOME/Applications/Xcode-13.4.1.app/Contents/Developer"
TOOLS="$HOME/swift-ios5-build/tools"
CM="$TOOLS/cmake/CMake.app/Contents/bin/cmake"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
CC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
mkdir -p "$B/build/llvm" "$B/logs"
/usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$CM" -S "$B/src/llvm-project/llvm" -B "$B/build/llvm" -G Ninja \
 -DCMAKE_MAKE_PROGRAM="$TOOLS/ninja" -DCMAKE_BUILD_TYPE=Release \
 -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="${CC}++" \
 -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
 -DLLVM_ENABLE_PROJECTS=clang -DLLVM_TARGETS_TO_BUILD='X86;ARM;AArch64' \
 -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
 -DCLANG_INCLUDE_TESTS=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_ZLIB=OFF \
 -DLLVM_ENABLE_TERMINFO=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_PARALLEL_LINK_JOBS=1
exec /usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$TOOLS/ninja" -C "$B/build/llvm" -j4 clang llvm-tblgen llvm-config llvm-ar llvm-ranlib llvm-nm llvm-objdump
