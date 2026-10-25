#!/bin/bash
set -euo pipefail
B="$HOME/swift-5.10-ios5-build"
export DEVELOPER_DIR="$HOME/Applications/Xcode-13.4.1.app/Contents/Developer"
TOOLS="$HOME/swift-ios5-build/tools"
CM="$TOOLS/cmake/CMake.app/Contents/bin/cmake"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
CC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
HOST="$HOME/Library/Developer/Toolchains/swift-5.10.1-RELEASE.xctoolchain/usr"
run() { /usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$@"; }
run "$CM" -S "$B/src/cmark" -B "$B/build/cmark" -G Ninja -DCMAKE_MAKE_PROGRAM="$TOOLS/ninja" \
 -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$CC" -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0
run "$TOOLS/ninja" -C "$B/build/cmark" -j1
run "$CM" -S "$B/src/swift" -B "$B/build/swift" -G Ninja -DCMAKE_MAKE_PROGRAM="$TOOLS/ninja" \
 -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="${CC}++" \
 -DCMAKE_Swift_COMPILER="$HOST/bin/swiftc" -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
 -DLLVM_DIR="$B/build/llvm/lib/cmake/llvm" -DClang_DIR="$B/build/llvm/lib/cmake/clang" \
 -DSWIFT_PATH_TO_CMARK_SOURCE="$B/src/cmark" -DSWIFT_PATH_TO_CMARK_BUILD="$B/build/cmark" \
 -DSWIFT_PATH_TO_SWIFT_SYNTAX_SOURCE="$B/src/swift-syntax" \
 -DSWIFT_PATH_TO_STRING_PROCESSING_SOURCE="$B/src/string-processing" \
 -DBOOTSTRAPPING_MODE=HOSTTOOLS -DSWIFT_BUILD_SWIFT_SYNTAX=ON -DSWIFT_HOST_TRIPLE=x86_64-apple-macosx12.0 \
 -DSWIFT_HOST_VARIANT_SDK=OSX -DSWIFT_HOST_VARIANT_ARCH=x86_64 -DSWIFT_SDKS=OSX \
 -DSWIFT_INCLUDE_TESTS=OFF -DSWIFT_INCLUDE_DOCS=OFF -DSWIFT_BUILD_SOURCEKIT=OFF \
 -DSWIFT_BUILD_DYNAMIC_STDLIB=OFF -DSWIFT_BUILD_STATIC_STDLIB=OFF \
 -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=OFF -DSWIFT_BUILD_STATIC_SDK_OVERLAY=OFF \
 -DSWIFT_BUILD_REMOTE_MIRROR=OFF -DSWIFT_BUILD_LIBEXEC=OFF -DSWIFT_ENABLE_ASSERTIONS=OFF
if [ "${1:-}" = --configure-only ]; then
  echo 'Configured Swift only; no compiler compilation started.'
  exit 0
fi
# Clang's executable target omits JIT/LTO archives needed by Swift's frontend.
# Derive the actual archive closure from the generated Swift build graph.
MISSING_TARGETS=()
python3 - "$B/build/swift/build.ninja" "$B/build/llvm" > "$B/build/swift/missing-llvm-targets.txt" <<'PY'
from pathlib import Path
import re,sys
text=Path(sys.argv[1]).read_text(); root=Path(sys.argv[2])
for p in sorted(set(re.findall(r'/[^\s|]+/lib[^\s|]+\.a',text))):
    path=Path(p)
    if root in path.parents and not path.exists(): print(path.stem[3:])
PY
while IFS= read -r target; do MISSING_TARGETS+=("$target"); done < "$B/build/swift/missing-llvm-targets.txt"
if [ "${#MISSING_TARGETS[@]}" -gt 0 ]; then
  run "$TOOLS/ninja" -C "$B/build/llvm" -j1 "${MISSING_TARGETS[@]}"
fi
exec /usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$TOOLS/ninja" -C "$B/build/swift" -j1 swift-frontend swift-demangle
