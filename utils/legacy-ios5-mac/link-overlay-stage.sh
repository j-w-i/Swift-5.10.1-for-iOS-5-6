#!/bin/bash
# Link isolated overlay objects; this is a link experiment, NOT iOS 5 qualification.
# Usage: link-overlay-stage.sh STAGE SDK OLD_RUNTIME_DIR CRT_ARCHIVE CLANG [LIBCXX_HEADERS]
# OLD_RUNTIME_DIR is a runtime build root containing lib/swift/iphoneos, or that
# library directory itself. Only Core/Darwin/ObjectiveC/CoreFoundation are reused.
# Native headers come from SWIFT51_SOURCE (defaults to bootstrap-manifest.json),
# LLVM_INCLUDE_DIR (defaults to its neighboring llvm/include or llvm-project/llvm/include),
# and LLVM_CONFIG_INCLUDE_DIR (required: directory containing llvm/Config/*.h).
# These are HEADER inputs, never old native objects. Set AR to an explicit archive
# tool if clang's neighboring llvm-ar/ar is unavailable. No xcrun/global SDK lookup.
# Outputs: STAGE/probes/linked510/{libswift*.dylib,libLegacyRuntimeBackports.a},
# plus native objects, logs, a module cache and generated config below that NEW dir.
# Failed outputs are retained; use a fresh stage, never delete/reuse an output dir.
set -euo pipefail
umask 022
fail() { printf 'link-overlay-stage: %s\n' "$*" >&2; exit 1; }
if [ "$#" -lt 5 ] || [ "$#" -gt 6 ]; then
  echo 'Usage: link-overlay-stage.sh STAGE SDK OLD_RUNTIME_DIR CRT_ARCHIVE CLANG [LIBCXX_HEADERS]' >&2
  exit 64
fi
STAGE=$1; SDK=$2; OLD_RUNTIME_DIR=$3; CRT_ARCHIVE=$4; CLANG=$5
LIBCXX_HEADERS=${6:-${LIBCXX_HEADERS:-}}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for path in "$STAGE" "$SDK" "$OLD_RUNTIME_DIR" "$CRT_ARCHIVE" "$CLANG"; do
  [[ "$path" = /* ]] || fail "Use absolute input paths: $path"
done
[ -d "$STAGE/probes" ] && [ -d "$SDK" ] && [ -d "$OLD_RUNTIME_DIR" ] || fail 'Missing stage, SDK or old runtime directory.'
[ -s "$CRT_ARCHIVE" ] && [ -x "$CLANG" ] || fail 'Missing CRT archive or executable clang.'
STAGE=$(CDPATH= cd -- "$STAGE" && pwd -P)
SDK=$(CDPATH= cd -- "$SDK" && pwd -P)
OLD_RUNTIME_DIR=$(CDPATH= cd -- "$OLD_RUNTIME_DIR" && pwd -P)
SRC="$STAGE/src/legacy-overlays"
OUT="$STAGE/probes/${LINK_OUTPUT_NAME:-linked510}"
[[ "${LINK_OUTPUT_NAME:-linked510}" != */* && "${LINK_OUTPUT_NAME:-linked510}" != .* ]] || fail 'LINK_OUTPUT_NAME must be a simple non-hidden directory name.'
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || fail "Output already exists (including symlinks): $OUT"
OLD_LIB="$OLD_RUNTIME_DIR/lib/swift/iphoneos"
[ -d "$OLD_LIB" ] || OLD_LIB=$OLD_RUNTIME_DIR
for name in Core Darwin ObjectiveC CoreFoundation; do
  [ -s "$OLD_LIB/libswift$name.dylib" ] || fail "Missing old runtime dependency: $OLD_LIB/libswift$name.dylib"
done
for name in Dispatch CoreGraphics Foundation Metal QuartzCore CoreImage UIKit; do
  [ -s "$STAGE/probes/${name}510.o" ] || fail "Missing built overlay: ${name}510.o"
done
for file in Foundation/BundleLookup.mm Foundation/DataThunks.m Foundation/NSError.mm Foundation/NSError.h Foundation/CheckClass.mm UIKit/DesignatedInitializers.mm; do
  [ -s "$SRC/$file" ] || fail "Missing staged native source: $file"
done
[ -s "$SCRIPT_DIR/LegacyRuntimeBackports.c" ] || fail 'Missing neighboring LegacyRuntimeBackports.c.'

# Read the preparation provenance, not a hard-coded user's old build directory.
if [ -z "${SWIFT51_SOURCE:-}" ]; then
  [ -s "$STAGE/bootstrap-manifest.json" ] || fail 'Set SWIFT51_SOURCE or supply the bootstrap manifest.'
  SWIFT51_SOURCE=$(/usr/bin/nice -n 15 "${PYTHON:-python3}" - "$STAGE/bootstrap-manifest.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    print(json.load(stream)['inputs']['swift51Source'])
PY
  )
fi
[[ "$SWIFT51_SOURCE" = /* ]] || fail 'SWIFT51_SOURCE must be absolute.'
[ -d "$SWIFT51_SOURCE" ] || fail 'Missing Swift 5.1 source checkout.'
SWIFT51_SOURCE=$(CDPATH= cd -- "$SWIFT51_SOURCE" && pwd -P)
for file in include/swift/Runtime/Metadata.h include/swift/Runtime/CMakeConfig.h.in stdlib/public/runtime/SwiftHashableSupport.h; do
  [ -s "$SWIFT51_SOURCE/$file" ] || fail "Missing Swift 5.1 header input: $file"
done
if [ -z "${LLVM_INCLUDE_DIR:-}" ]; then
  if [ -s "$SWIFT51_SOURCE/../llvm/include/llvm/ADT/ArrayRef.h" ]; then
    LLVM_INCLUDE_DIR="$SWIFT51_SOURCE/../llvm/include"
  else
    LLVM_INCLUDE_DIR="$SWIFT51_SOURCE/../llvm-project/llvm/include"
  fi
fi
[[ "$LLVM_INCLUDE_DIR" = /* && "${LLVM_CONFIG_INCLUDE_DIR:-}" = /* ]] || fail 'Set absolute LLVM_INCLUDE_DIR and LLVM_CONFIG_INCLUDE_DIR (matching legacy LLVM headers).'
[ -s "$LLVM_INCLUDE_DIR/llvm/ADT/ArrayRef.h" ] || fail 'Missing legacy LLVM source headers.'
for file in llvm-config.h abi-breaking.h; do
  [ -s "$LLVM_CONFIG_INCLUDE_DIR/llvm/Config/$file" ] || fail "Missing LLVM generated header: llvm/Config/$file"
done
CXX_HEADERS=()
if [ -n "$LIBCXX_HEADERS" ]; then
  [[ "$LIBCXX_HEADERS" = /* ]] && [ -s "$LIBCXX_HEADERS/__config" ] || fail 'LIBCXX_HEADERS must be an absolute libc++ include/c++/v1 directory.'
  CXX_HEADERS=(-nostdinc++ -isystem "$LIBCXX_HEADERS")
fi
if [ -z "${AR:-}" ]; then
  if [ -x "$(dirname -- "$CLANG")/llvm-ar" ]; then
    AR="$(dirname -- "$CLANG")/llvm-ar"
  else
    AR="$(dirname -- "$CLANG")/ar"
  fi
fi
[[ "$AR" = /* ]] && [ -x "$AR" ] || fail 'Set AR to an absolute executable archive tool.'

# mkdir is the atomic claim: never mkdir -p the output or follow an existing link.
mkdir "$OUT"
mkdir "$OUT/native" "$OUT/logs" "$OUT/include" "$OUT/include/swift" "$OUT/include/swift/Runtime" "$OUT/module-cache"
# Runtime/CMakeConfig.h.in has exactly these two CMake options. Non-Apple-internal
# builds set both to zero; generate locally instead of needing any oldbuild files.
/usr/bin/nice -n 15 "${PYTHON:-python3}" - "$SWIFT51_SOURCE/include/swift/Runtime/CMakeConfig.h.in" "$OUT/include/swift/Runtime/CMakeConfig.h" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
for name in ('SWIFT_BNI_OS_BUILD', 'SWIFT_BNI_XCODE_BUILD'):
    token = '#cmakedefine01 ' + name
    if token not in text:
        raise SystemExit('Unexpected legacy runtime configuration template')
    text = text.replace(token, '#define ' + name + ' 0')
if '#cmakedefine' in text:
    raise SystemExit('Unsupported legacy runtime configuration option')
with open(sys.argv[2], 'x') as stream:
    stream.write(text)
PY
run() {
  local label=$1; shift
  printf 'Building %s\n' "$label"
  # The complete quoted command is retained alongside diagnostics for reproduction.
  (printf '%q ' "$@"; printf '\n') > "$OUT/logs/$label.command"
  if /usr/bin/nice -n 15 "$@" > "$OUT/logs/$label.log" 2>&1; then
    :
  else
    local status=$?
    tail -40 "$OUT/logs/$label.log" >&2
    fail "$label failed (exit $status); partial outputs retained in $OUT"
  fi
}
# Match the successful probes' SDK/link triple; it does NOT establish an iOS 5
# deployment target. Availability/import/load-command/device audits remain required.
DEPLOYMENT=${IOS_DEPLOYMENT_TARGET:-7.0}
case "$DEPLOYMENT" in 5.0|5.1|5.1.1|7.0) ;; *) fail 'Unsupported IOS_DEPLOYMENT_TARGET; use 5.0/5.1/5.1.1 or probe7.0.' ;; esac
COLLECTION_ARCHIVE="$STAGE/probes/collection-runtime/libswiftLegacyCollectionView.a"
case "$DEPLOYMENT" in
  5.*) [ -s "$COLLECTION_ARCHIVE" ] || fail "Missing source-built UIKit collection runtime: $COLLECTION_ARCHIVE" ;;
esac
COMMON=(-target "armv7-apple-ios$DEPLOYMENT" -isysroot "$SDK")
# Legacy iOS 5 linking loses ARM/Thumb interworking bits on local relocations.
# Native ObjC method lists and block helper pointers therefore must be ARM code,
# like the Swift overlays and collection runtime compiled by the other stages.
NATIVE=(-marm -O2 -fblocks -fno-objc-arc -fno-modules -fmodules-cache-path="$OUT/module-cache"
  -DSWIFT_RUNTIME -DSWIFT_STDLIB_BUILDING_OVERLAY -DOS_OBJECT_USE_OBJC=0 -DLLVM_DISABLE_ABI_BREAKING_CHECKS_ENFORCING=1
  -I "$OUT/include" -I "$SWIFT51_SOURCE/include"
  -I "$LLVM_CONFIG_INCLUDE_DIR" -I "$LLVM_INCLUDE_DIR"
  -I "$SWIFT51_SOURCE/stdlib/public/Darwin/Foundation")
# The last include directory also resolves NSError.h's ../../runtime header
# against the source tree, without altering the staged sources or using old .o's.
FOUNDATION_OBJECTS=()
for file in BundleLookup.mm DataThunks.m NSError.mm CheckClass.mm; do
  obj="$OUT/native/$file.o"
  if [[ "$file" = *.mm ]]; then
    run "$file" "$CLANG" "${COMMON[@]}" "${NATIVE[@]}" -std=c++14 -stdlib=libc++ \
      ${CXX_HEADERS[@]+"${CXX_HEADERS[@]}"} -c "$SRC/Foundation/$file" -o "$obj"
  else
    run "$file" "$CLANG" "${COMMON[@]}" "${NATIVE[@]}" -c "$SRC/Foundation/$file" -o "$obj"
  fi
  FOUNDATION_OBJECTS+=("$obj")
done
run DesignatedInitializers.mm "$CLANG" "${COMMON[@]}" "${NATIVE[@]}" -std=c++14 -stdlib=libc++ \
  ${CXX_HEADERS[@]+"${CXX_HEADERS[@]}"} -c "$SRC/UIKit/DesignatedInitializers.mm" -o "$OUT/native/DesignatedInitializers.mm.o"
run LegacyRuntimeBackports "$CLANG" -target armv7-apple-ios5.0 -isysroot "$SDK" -O2 -std=c11 \
  -c "$SCRIPT_DIR/LegacyRuntimeBackports.c" -o "$OUT/native/LegacyRuntimeBackports.o"
run archive "$AR" rcs "$OUT/libLegacyRuntimeBackports.a" "$OUT/native/LegacyRuntimeBackports.o"

# Explicit dependency paths ensure no old overlay (especially CoreGraphics) can
# silently satisfy a rebuilt overlay dependency. Rebuild CG before Foundation.
BASE=("$OLD_LIB/libswiftCore.dylib" "$OLD_LIB/libswiftDarwin.dylib" "$OLD_LIB/libswiftObjectiveC.dylib")
CF=("$OLD_LIB/libswiftCoreFoundation.dylib")
for name in Dispatch CoreGraphics Foundation Metal QuartzCore CoreImage UIKit; do
  DEPS=("${BASE[@]}")
  EXTRA=()
  case "$name" in
    Dispatch) ;;
    CoreGraphics)
      # CMake lists only Swift sources and generic install-name magic, no native
      # CoreGraphics implementation. The Swift object is its entire payload.
      DEPS+=("${CF[@]}" "$OUT/libswiftDispatch.dylib")
      EXTRA=(-framework CoreGraphics) ;;
    Foundation)
      DEPS+=("${CF[@]}" "$OUT/libswiftDispatch.dylib" "$OUT/libswiftCoreGraphics.dylib")
      EXTRA=("${FOUNDATION_OBJECTS[@]}" -framework Foundation -framework CoreFoundation -framework CoreGraphics -lc++) ;;
    *)
      DEPS+=("${CF[@]}" "$OUT/libswiftDispatch.dylib" "$OUT/libswiftCoreGraphics.dylib" "$OUT/libswiftFoundation.dylib")
      EXTRA=(-framework "$name" -lc++)
      case "$name" in
        Metal) EXTRA=(-weak_framework Metal -lc++) ;;
        CoreImage) DEPS+=("$OUT/libswiftMetal.dylib" "$OUT/libswiftQuartzCore.dylib") ;;
        UIKit)
          DEPS+=("$OUT/libswiftMetal.dylib" "$OUT/libswiftQuartzCore.dylib" "$OUT/libswiftCoreImage.dylib")
          EXTRA+=("$OUT/native/DesignatedInitializers.mm.o")
          case "$DEPLOYMENT" in
            5.*)
              # Force-load internally, not in client projects: retain ObjC classes,
              # categories and constructors even without direct overlay references.
              EXTRA+=(-Xlinker -force_load -Xlinker "$COLLECTION_ARCHIVE" -framework QuartzCore) ;;
          esac ;;
      esac ;;
  esac
  # Backports is an ordinary lazy archive, deliberately NOT force_load/all_load.
  # Compiler-rt builtins are force-loaded for each overlay; the collection archive
  # is force-loaded only into UIKit above. No undefined suppression/dynamic lookup.
  run "link-$name" "$CLANG" "${COMMON[@]}" -dynamiclib "$STAGE/probes/${name}510.o" \
    -L "$OUT" -L "$OLD_LIB" ${EXTRA[@]+"${EXTRA[@]}"} "${DEPS[@]}" "$OUT/libLegacyRuntimeBackports.a" -lobjc -lSystem \
    -Xlinker -install_name -Xlinker "@rpath/libswift$name.dylib" \
    -Xlinker -force_load -Xlinker "$CRT_ARCHIVE" -o "$OUT/libswift$name.dylib"
done
printf 'Linked seven overlay dylibs and lazy backports archive: %s\n' "$OUT"
printf '%s\n' 'Link experiment only: iOS 5 imports/load commands, ABI and real-device validation still pending.'
