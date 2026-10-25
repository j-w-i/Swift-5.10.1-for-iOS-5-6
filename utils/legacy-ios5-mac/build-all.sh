#!/bin/bash
# One command: build the dual iOS 5 + iOS 6 Swift 5.10.1 toolchain from source.
#
#   LEGACY_BUILD_ROOT=/path/to/empty/dir \
#   XCODE_13_4_1_DEVELOPER_DIR=/path/to/Xcode-13.4.1.app/Contents/Developer \
#   ./build-all.sh [--from STAGE] [--only STAGE]
#
# Output: $LEGACY_BUILD_ROOT/out/swift-5.10.1-ios5.xctoolchain
# Stages are idempotent and resumable: a finished stage leaves $ROOT/.stamps/<stage>; delete it to redo a stage.
# Everything is fetched from GitHub/swift.org at pinned refs; nothing is read from $HOME or prebuilt directories.
set -euo pipefail
ROOT="${LEGACY_BUILD_ROOT:?set LEGACY_BUILD_ROOT to a directory (created if missing)}"
XC="${XCODE_13_4_1_DEVELOPER_DIR:?set XCODE_13_4_1_DEVELOPER_DIR to Xcode 13.4.1.app/Contents/Developer}"
HERE="$(cd "$(dirname "$0")" && pwd -P)"; REPO="$(cd "$HERE/../.." && pwd -P)"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"; SWIFT_JOBS="${SWIFT_JOBS:-$JOBS}"; export JOBS
mkdir -p "$ROOT"; ROOT="$(cd "$ROOT" && pwd -P)"
export LEGACY_BUILD_ROOT="$ROOT" XCODE_13_4_1_DEVELOPER_DIR="$XC" DEVELOPER_DIR="$XC"
mkdir -p "$ROOT"/{src,build,logs,out,downloads,tools,.stamps}
S="$ROOT/src"; L="$ROOT/logs"
export PATH="$ROOT/tools:$ROOT/tools/cmake/CMake.app/Contents/bin:$PATH"
X86() { /usr/bin/arch -x86_64 "$@"; }

# ---- pinned inputs --------------------------------------------------------------------------------
CMAKE_URL=https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-macos-universal.tar.gz
NINJA_URL=https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-mac.zip
SWIFT510_PKG_URL=https://download.swift.org/swift-5.10.1-release/xcode/swift-5.10.1-RELEASE/swift-5.10.1-RELEASE-osx.pkg
THEOS_SDKS_URL=https://github.com/theos/sdks.git
THEOS_SDKS_REF=0222fd5413cf4b9af096f37b4621afa2688572f7
SWIFT515_REPO=https://github.com/j-w-i/Swift-5.1.5-for-iOS-6.git; SWIFT515_BRANCH=ios5-mac
LLVM515_REPO=https://github.com/j-w-i/llvm-project.git;            LLVM515_REF=swift/swift-5.1-branch
CMARK515_REPO=https://github.com/apple/swift-cmark.git;           CMARK515_REF=swift-5.1.5-RELEASE

stage() { # name  command...
  local n=$1; shift
  [ -e "$ROOT/.stamps/$n" ] && { echo "== $n: done (skip)"; return; }
  if [ -n "${ONLY:-}" ] && [ "$ONLY" != "$n" ]; then return; fi
  if [ -n "${FROM:-}" ] && [ -z "${STARTED:-}" ]; then [ "$FROM" = "$n" ] && STARTED=1 || { echo "== $n: before --from, skip"; return; }; fi
  echo "== $n: $(date +%T)"; "$@" > "$L/$n.log" 2>&1 || { echo "FAILED: $n (see $L/$n.log)"; tail -25 "$L/$n.log"; exit 1; }
  touch "$ROOT/.stamps/$n"
}
while [ $# -gt 0 ]; do case "$1" in --from) FROM=$2; shift 2;; --only) ONLY=$2; shift 2;; *) echo "bad arg $1"; exit 64;; esac; done
clone() { [ -d "$S/$1/.git" ] || git clone -q --depth 1 --branch "$3" "$2" "$S/$1"; }

# ---- stages -----------------------------------------------------------------------------------------
tools() {
  cd "$ROOT/tools"
  [ -x cmake/CMake.app/Contents/bin/cmake ] || { curl -fsSL -o "$ROOT/downloads/cmake.tgz" "$CMAKE_URL"; tar xzf "$ROOT/downloads/cmake.tgz"; mv cmake-3.31.6-macos-universal cmake; }
  [ -x ninja ] || { curl -fsSL -o "$ROOT/downloads/ninja.zip" "$NINJA_URL"; unzip -oq "$ROOT/downloads/ninja.zip"; chmod +x ninja; }
  mkdir -p shim; ln -sf "$XC/usr/bin/python3" shim/python; ln -sf "$XC/usr/bin/python3" shim/python3
  # Only two SDKs are needed (9.3 for crt1.3.1.o, 13.7 for the iOS runtime build); sparse-checkout avoids fetching them all.
  if [ ! -d "$S/theos-sdks/iPhoneOS13.7.sdk" ]; then
    rm -rf "$S/theos-sdks"; git clone -q --filter=blob:none --no-checkout "$THEOS_SDKS_URL" "$S/theos-sdks"
    git -C "$S/theos-sdks" sparse-checkout set iPhoneOS9.3.sdk iPhoneOS13.7.sdk
    git -C "$S/theos-sdks" checkout -q "$THEOS_SDKS_REF"
  fi
}
host_toolchain() { # official swift.org 5.10.1 toolchain: host compiler for the build and the baseline of the assembly
  cd "$ROOT/downloads"
  [ -s swift-5.10.1.pkg ] || curl -fsSL -o swift-5.10.1.pkg "$SWIFT510_PKG_URL"
  if [ ! -d "$ROOT/host/swift-5.10.1-RELEASE.xctoolchain" ]; then
    rm -rf pkgx && /usr/sbin/pkgutil --expand-full swift-5.10.1.pkg pkgx
    mkdir -p "$ROOT/host"; mv pkgx/*-package.pkg/Payload "$ROOT/host/swift-5.10.1-RELEASE.xctoolchain" 2>/dev/null || mv pkgx/*/Payload "$ROOT/host/swift-5.10.1-RELEASE.xctoolchain"
    rm -rf pkgx
  fi
  [ -x "$ROOT/host/swift-5.10.1-RELEASE.xctoolchain/usr/bin/swiftc" ]
}
fetch510() { bash "$HERE/fetch-deps.sh"; }
llvm510() { bash "$HERE/build-llvm510-mac.sh"; }
swift510() { export SWIFT_5_10_1_HOST_TOOLCHAIN="$ROOT/host/swift-5.10.1-RELEASE.xctoolchain"; bash "$HERE/configure-swift510-mac.sh"; }
driver510() { cd "$S/swift-driver" && X86 env DEVELOPER_DIR="$XC" PATH="$ROOT/host/swift-5.10.1-RELEASE.xctoolchain/usr/bin:$PATH" swift build -c debug --product swift-driver -j "$SWIFT_JOBS"; }
fetch515() {
  export LEGACY_515_ROOT="$ROOT/b515"; mkdir -p "$LEGACY_515_ROOT/src" "$LEGACY_515_ROOT/build" "$LEGACY_515_ROOT/tools"
  P="$LEGACY_515_ROOT/src"
  [ -d "$P/swift/.git" ] || git clone -q --depth 1 --branch "$SWIFT515_BRANCH" "$SWIFT515_REPO" "$P/swift"
  [ -d "$P/llvm-project/.git" ] || git clone -q --depth 1 --branch "$LLVM515_REF" "$LLVM515_REPO" "$P/llvm-project"
  [ -d "$P/cmark/.git" ] || git clone -q --depth 1 --branch "$CMARK515_REF" "$CMARK515_REPO" "$P/cmark"
  for d in llvm clang compiler-rt; do :; done
  ln -sfn llvm-project/llvm "$P/llvm"; ln -sfn llvm-project/clang "$P/clang"; ln -sfn llvm-project/compiler-rt "$P/compiler-rt"
  ln -sfn llvm-project/libcxx "$P/libcxx"; ln -sfn llvm-project/libcxxabi "$P/libcxxabi"; ln -sfn llvm-project/lld "$P/lld"
  cp -R "$ROOT/tools/"* "$LEGACY_515_ROOT/tools/" 2>/dev/null || true
  mkdir -p "$LEGACY_515_ROOT/sdks"; ln -sfn "$S/theos-sdks" "$LEGACY_515_ROOT/sdks/theos-sdks"
  # LLVM-fork patches that live next to the Mac scripts (idempotent)
  for pf in "$P/swift/utils/legacy-ios5-mac/"*.patch; do
    git -C "$P/llvm-project" apply --check "$pf" 2>/dev/null && git -C "$P/llvm-project" apply "$pf" || echo "patch already applied or not applicable: $(basename "$pf")"
  done
}
compiler515() { export LEGACY_515_ROOT="$ROOT/b515"; JOBS=$JOBS bash "$LEGACY_515_ROOT/src/swift/utils/legacy-ios5-mac/build-compiler.sh"; }
crt515() { export LEGACY_515_ROOT="$ROOT/b515"; bash "$LEGACY_515_ROOT/src/swift/utils/legacy-ios5-mac/build-compiler-rt.sh"
  B515="$ROOT/b515"; D="$B515/build/macos/llvm-macosx-x86_64/lib/clang/7.0.0/lib/darwin"; mkdir -p "$D"
  cp "$B515/build/crt-armv7-ios50/lib/darwin/libclang_rt.ios.a" "$D/"; }
runtime515() { export LEGACY_515_ROOT="$ROOT/b515"; M="$LEGACY_515_ROOT/src/swift/utils/legacy-ios5-mac"
  bash "$M/configure-ios-runtime.sh" ios5 -k 0; bash "$M/configure-ios-runtime.sh" default -k 0; }
overlays() { # prepare + build + link the rewritten overlays
  export LEGACY_515_ROOT="$ROOT/b515"; H="$ROOT/host/swift-5.10.1-RELEASE.xctoolchain"
  SDK="$XC/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk"
  bash "$HERE/prepare-legacy-resources.sh" --swift510-resource "$H/usr/lib/swift" --swift51-source "$LEGACY_515_ROOT/src/swift" --output "$ROOT/bootstrap"
  bash "$HERE/build-overlay-stage.sh" "$ROOT/bootstrap" "$ROOT/build/swift/bin/swift-frontend" "$SDK" --legacy-marking
  LLVM_CONFIG_INCLUDE_DIR="$ROOT/build/llvm/include" LINK_OUTPUT_NAME=linked510-legacy IOS_DEPLOYMENT_TARGET=5.0 AR="$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar" \
  SWIFT51_SOURCE="$LEGACY_515_ROOT/src/swift" \
  bash "$HERE/link-overlay-stage.sh" "$ROOT/bootstrap" "$SDK" "$LEGACY_515_ROOT/build/runtime-ios5" \
    "$LEGACY_515_ROOT/build/crt-armv7-ios50/libclang_rt.builtins_armv7_ios.a" "$ROOT/build/llvm/bin/clang" "$LEGACY_515_ROOT/src/llvm-project/libcxx/include"
}
assemble() {
  H="$ROOT/host/swift-5.10.1-RELEASE.xctoolchain"; export LEGACY_515_ROOT="$ROOT/b515"
  LINK_OUTPUT_NAME=linked510-legacy bash "$HERE/assemble-510-toolchain.sh" "$H" "$ROOT/build/swift/bin/swift-frontend" \
    "$S/swift-driver/.build/x86_64-apple-macosx/debug/swift-driver" "$ROOT/bootstrap" "$LEGACY_515_ROOT/build/runtime-ios5" \
    "$ROOT/bootstrap/probes/linked510-legacy/libLegacyRuntimeBackports.a" "$S/theos-sdks/iPhoneOS9.3.sdk/usr/lib/crt1.3.1.o" \
    "$ROOT/out/swift-5.10.1-ios5.xctoolchain"
}
stage tools tools
stage host-toolchain host_toolchain
stage fetch-510 fetch510
stage llvm-510 llvm510
stage swift-510 swift510
stage driver-510 driver510
stage fetch-515 fetch515
stage compiler-515 compiler515
stage crt-515 crt515
stage runtime-515 runtime515
stage overlays overlays
stage assemble assemble
echo "DONE: $ROOT/out/swift-5.10.1-ios5.xctoolchain"
