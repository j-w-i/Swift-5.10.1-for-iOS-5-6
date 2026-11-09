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
case "$XC$ROOT" in *" "*) echo "Paths containing spaces are not supported by the LLVM/Swift build systems (XCODE_13_4_1_DEVELOPER_DIR, LEGACY_BUILD_ROOT)." >&2; exit 64;; esac
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

fetch() { # url destination - resumable download with retries; never leaves a partial file in place
  local url="$1" dest="$2" part="$2.part" attempt
  [ -s "$dest" ] && return 0
  for attempt in 1 2 3; do
    if /usr/bin/curl -fsSL --retry 3 --retry-all-errors --retry-delay 2 --continue-at - -o "$part" "$url"; then
      /bin/mv -f "$part" "$dest"; return 0
    fi
    echo "download attempt $attempt failed: $url" >&2
    /bin/sleep 5
  done
  return 1
}

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
  [ -x cmake/CMake.app/Contents/bin/cmake ] || { fetch "$CMAKE_URL" "$ROOT/downloads/cmake.tgz" || exit 1; tar xzf "$ROOT/downloads/cmake.tgz"; mv cmake-3.31.6-macos-universal cmake; }
  [ -x ninja ] || { fetch "$NINJA_URL" "$ROOT/downloads/ninja.zip" || exit 1; unzip -oq "$ROOT/downloads/ninja.zip"; chmod +x ninja; }
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
  if [ ! -d "$ROOT/host/swift-5.10.1-RELEASE.xctoolchain" ]; then
    for attempt in 1 2; do
      fetch "$SWIFT510_PKG_URL" swift-5.10.1.pkg || exit 1
      rm -rf pkgx
      if /usr/sbin/pkgutil --expand-full swift-5.10.1.pkg pkgx; then
        mkdir -p "$ROOT/host"; mv pkgx/*-package.pkg/Payload "$ROOT/host/swift-5.10.1-RELEASE.xctoolchain" 2>/dev/null || mv pkgx/*/Payload "$ROOT/host/swift-5.10.1-RELEASE.xctoolchain"
        rm -rf pkgx
        break
      fi
      echo "swift-5.10.1.pkg does not expand (attempt $attempt); discarding it and downloading again" >&2
      rm -rf pkgx swift-5.10.1.pkg swift-5.10.1.pkg.part
    done
  fi
  [ -x "$ROOT/host/swift-5.10.1-RELEASE.xctoolchain/usr/bin/swiftc" ]
}
fetch510() { bash "$HERE/fetch-deps.sh"; }
stdlib510ios() { bash "$HERE/build-ios-stdlib510.sh"; }
baseline510() { bash "$HERE/stage-510-baseline.sh"; }
llvm510() { bash "$HERE/build-llvm510-mac.sh"; }
swift510() { export SWIFT_5_10_1_HOST_TOOLCHAIN="$ROOT/host/swift-5.10.1-RELEASE.xctoolchain"; bash "$HERE/configure-swift510-mac.sh"; }
driver510() { cd "$S/swift-driver" && X86 env DEVELOPER_DIR="$XC" PATH="$ROOT/host/swift-5.10.1-RELEASE.xctoolchain/usr/bin:$PATH" swift build -c debug --product swift-driver -j "$SWIFT_JOBS"; }
fetch515() {
  export LEGACY_515_ROOT="$ROOT/b515"; mkdir -p "$LEGACY_515_ROOT/src" "$LEGACY_515_ROOT/build" "$LEGACY_515_ROOT/tools"
  P="$LEGACY_515_ROOT/src"
  [ -d "$P/swift/.git" ] || git clone -q --depth 1 --branch "$SWIFT515_BRANCH" "$SWIFT515_REPO" "$P/swift"
  # The legacy class marker is separate from the real deployment target. Never
  # ship a runtime compiled for 7 merely because it uses the iOS 5 class marker.
  RUNTIME515_PATCH="$HERE/runtime515-target5.patch"
  if git -C "$P/swift" apply --check "$RUNTIME515_PATCH"; then
    git -C "$P/swift" apply "$RUNTIME515_PATCH"
  elif git -C "$P/swift" apply --reverse --check "$RUNTIME515_PATCH"; then
    echo 'Runtime target-5 source patch is already applied.'
  else
    echo 'Runtime target-5 source patch conflicts; review the pinned source.' >&2
    return 1
  fi
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
runtime515package() { # runtime-only 5.1.5 .xctoolchain for the iOS 6 guide route (compiler-rt atomics inside)
  bash "$HERE/package-runtime-515.sh"
}
qualify515() { # run the five iOS 5 qualification checks; publish the profile when the environment is known
  rm -rf "$ROOT/out/ios5-qualification"
  if [ -n "${LEGACY_ENVIRONMENT_ROOT:-}" ]; then
    LEGACY_BUILD_ROOT="$ROOT" bash "$HERE/qualify-ios5.sh" --environment-root "$LEGACY_ENVIRONMENT_ROOT"
  else
    LEGACY_BUILD_ROOT="$ROOT" bash "$HERE/qualify-ios5.sh" --check-only
  fi
}
overlays() { # prepare + build + link the rewritten overlays
  # The overlay stages refuse to reuse an output directory (their outputs are evidence of one run),
  # so a re-run of this stage starts from a clean derived directory.
  rm -rf "$ROOT/bootstrap"
  export LEGACY_515_ROOT="$ROOT/b515"; H="$ROOT/out/swift-5.10.1-baseline.xctoolchain"
  SDK="$XC/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk"
  bash "$HERE/prepare-legacy-resources.sh" --swift510-resource "$H/usr/lib/swift" --swift51-source "$LEGACY_515_ROOT/src/swift" --output "$ROOT/bootstrap"
  # The Swift 5.10 resource tree carries no ObjectiveC/CoreFoundation overlay modules (the 5.10 source
  # tree has no Darwin overlay directory), but the Foundation/UIKit overlays import them (ObjCBool,
  # CF bridging). They come from the matching Swift 5.1.5 runtime built in the runtime-515 stage.
  for MOD in ObjectiveC CoreFoundation; do
    SRC_MOD="$LEGACY_515_ROOT/build/runtime-ios5/lib/swift/iphoneos/$MOD.swiftmodule"
    [ -d "$SRC_MOD" ] || { echo "missing $SRC_MOD (runtime-515 must run first)" >&2; exit 1; }
    mkdir -p "$ROOT/bootstrap/probes/modules510/iphoneos"
    DEST_MOD="$ROOT/bootstrap/probes/modules510/iphoneos/$MOD.swiftmodule"
    rm -rf "$DEST_MOD"; mkdir -p "$DEST_MOD"
    # Interface text only: the 5.1.5 binary .swiftmodule cannot be read by the 5.10 compiler, which
    # instead builds its own module from the .swiftinterface (armv7 spelling is reused by every slice).
    cp "$SRC_MOD/armv7.swiftinterface" "$DEST_MOD/armv7.swiftinterface"
    for A in armv7s arm64; do cp "$SRC_MOD/armv7.swiftinterface" "$DEST_MOD/$A.swiftinterface"; done
  done
  # UIKit's iOS 5 declaration supplement is a compiler resource, not a bridging
  # header or package. Build the matching implementation from vendored sources
  # before compiling overlays; link-overlay-stage embeds it in libswiftUIKit.
  bash "$HERE/build-collection-runtime.sh" "$SDK" "$ROOT/build/llvm/bin/clang" \
    "$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar" "$ROOT/bootstrap/probes/collection-runtime"
  cp -R "$ROOT/bootstrap/probes/collection-runtime/legacy-collection" "$ROOT/bootstrap/probes/modules510/legacy-collection"
  # Backported UIKit APIs are part of the SDK, not a package: their Objective-C
  # and Swift implementations are built here and linked into libswiftUIKit.
  bash "$HERE/build-backports-runtime.sh" "$SDK" "$ROOT/build/llvm/bin/clang" \
    "$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar" "$ROOT/bootstrap/probes/backports-runtime"
  bash "$HERE/build-compositional-layout.sh" "$SDK" "$ROOT/build/llvm/bin/clang" \
    "$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar" "$ROOT/bootstrap/probes/compositional-layout-runtime"
  # Foundation backports use native SDK signatures and live in the Foundation
  # overlay runtime, never a separate package or client-side linker setting.
  bash "$HERE/build-foundation-runtime.sh" "$SDK" "$ROOT/build/llvm/bin/clang" \
    "$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar" "$ROOT/bootstrap/probes/foundation-runtime"
  bash "$HERE/build-overlay-stage.sh" "$ROOT/bootstrap" "$ROOT/build/swift/bin/swift-frontend" "$SDK" --legacy-marking
  # Genuine native API implementations belong to the SDK's existing backports
  # archive. No client helper module, renamed API or new app linker flag.
  bash "$HERE/build-native-uikit-runtime.sh" "$SDK" "$ROOT/build/llvm/bin/clang" \
    "$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar" "$ROOT/bootstrap/probes/native-uikit-runtime"
  OLD_CORE_DIR="$LEGACY_515_ROOT/build/runtime-ios5/lib/swift/iphoneos"
  [ -d "$OLD_CORE_DIR" ] || OLD_CORE_DIR="$LEGACY_515_ROOT/build/runtime-ios5"
  bash "$HERE/build-native-numeric-runtime.sh" armv7 "$SDK" "$ROOT/build/llvm/bin/clang" \
    "$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar" "$ROOT/build/swift/bin/swift-frontend" \
    "$ROOT/bootstrap/probes/modules510" "$ROOT/bootstrap/probes/native-numeric-runtime" \
    "$OLD_CORE_DIR/libswiftCore.dylib"
  LLVM_CONFIG_INCLUDE_DIR="$ROOT/build/llvm/include" LINK_OUTPUT_NAME=linked510-legacy IOS_DEPLOYMENT_TARGET=5.0 AR="$XC/Toolchains/XcodeDefault.xctoolchain/usr/bin/ar" \
  SWIFT51_SOURCE="$LEGACY_515_ROOT/src/swift" \
  bash "$HERE/link-overlay-stage.sh" "$ROOT/bootstrap" "$SDK" "$LEGACY_515_ROOT/build/runtime-ios5" \
    "$LEGACY_515_ROOT/build/crt-armv7-ios50/libclang_rt.builtins_armv7_ios.a" "$ROOT/build/llvm/bin/clang" "$LEGACY_515_ROOT/src/llvm-project/libcxx/include"
}
# Non-armv7 legacy slices: build the overlays, facades and runtime for armv7s/arm64 and merge them
# with the armv7 dylibs into one multi-arch tree. Runs after `overlays` (armv7 objects/modules) and
# after stdlib-510-ios produced the extra per-arch module trees when EXTRA_ARCHS is set.
multiarch() {
  [ -n "${EXTRA_ARCHS:-}" ] || { echo 'multiarch: EXTRA_ARCHS empty, nothing to do'; return 0; }
  local base
  base=$(dirname "$(dirname "$ROOT/build/swift/bin/swift-frontend")")/../bootstrap/probes/modules510/iphoneos 2>/dev/null || true
  BASELINE_RUNTIME="$ROOT/bootstrap/probes/linked510-legacy" \
  SDK="$ROOT/src/theos-sdks/iPhoneOS13.7.sdk" \
  SWIFT51_SOURCE="$LEGACY_515_ROOT/src/swift" \
  LLVM_CONFIG_INCLUDE_DIR="$ROOT/build/llvm/include" \
  EXTRA_ARCHS="$EXTRA_ARCHS" \
    bash "$HERE/build-multiarch-overlays.sh" "$ROOT" "$ROOT/out/multiarch-runtime"
}

assemble() {
  # assemble-510-toolchain.sh refuses to reuse an output directory; a re-run rebuilds the derived
  # toolchain from the current stage inputs.
  rm -rf "$ROOT/out/swift-5.10.1-ios5.xctoolchain"
  H="$ROOT/out/swift-5.10.1-baseline.xctoolchain"; export LEGACY_515_ROOT="$ROOT/b515"
  LINK_OUTPUT_NAME=linked510-legacy bash "$HERE/assemble-510-toolchain.sh" "$H" "$ROOT/build/swift/bin/swift-frontend" \
    "$S/swift-driver/.build/x86_64-apple-macosx/debug/swift-driver" "$ROOT/bootstrap" "$LEGACY_515_ROOT/build/runtime-ios5" \
    "$ROOT/bootstrap/probes/linked510-legacy/libLegacyRuntimeBackports.a" "$S/theos-sdks/iPhoneOS9.3.sdk/usr/lib/crt1.3.1.o" \
    "$ROOT/out/swift-5.10.1-ios5.xctoolchain"
}
sanitize() {
  local TC="$ROOT/out/swift-5.10.1-ios5.xctoolchain"
  local LIB="$TC/usr/lib/swift_ios5/iphoneos"
  [ -d "$LIB" ] || { echo 'sanitize: no assembled iOS 5 toolchain; run the assemble stage first' >&2; exit 1; }
  # Reproducible pass over an already-assembled toolchain, for build roots whose
  # assemble stage predates this step. New assemblies already run it inline.
  /usr/bin/python3 "$HERE/strip-system-swift-deps.py" --reexport-core --drop-system-swift-rpath "$LIB/"libswift*.dylib
}

stage tools tools
stage host-toolchain host_toolchain
stage fetch-510 fetch510
stage llvm-510 llvm510
stage swift-510 swift510
stage stdlib-510-ios stdlib510ios
stage driver-510 driver510
stage baseline-510 baseline510
stage fetch-515 fetch515
stage compiler-515 compiler515
stage crt-515 crt515
stage runtime-515 runtime515
stage runtime-package-515 runtime515package
stage overlays overlays
if [ -n "${EXTRA_ARCHS:-}" ]; then stage multiarch multiarch; fi
stage assemble assemble
stage sanitize sanitize
stage qualify-ios5 qualify515
echo "DONE: $ROOT/out/swift-5.10.1-ios5.xctoolchain"
echo "      $ROOT/out/swift-5.1.5-ios6-runtime.xctoolchain.tar.gz (Swift 5.1.5 runtime for the iOS 6 guide route; import it as the environment's 5.1.5 runtime)"
if [ -n "${LEGACY_ENVIRONMENT_ROOT:-}" ]; then
  echo "      iOS 5 qualified in $LEGACY_ENVIRONMENT_ROOT (profile published by the qualify-ios5 stage)"
else
  echo "      iOS 5 qualification evidence: $ROOT/out/ios5-qualification; publish with:"
  echo "        LEGACY_BUILD_ROOT=$ROOT $HERE/qualify-ios5.sh --environment-root \"<env>\""
fi
