#!/bin/bash
# Build the Swift runtime for the non-armv7 legacy slices (armv7s, arm64) and merge everything into
# one fat per-dylib tree. armv7 comes from the existing legacy build; this stage adds the rest.
#
# Usage: build-multiarch-overlays.sh BUILD_ROOT OUT
#
#   BUILD_ROOT  a legacy build root that already contains the built compiler and, for each extra
#               arch, a stdlib resource tree at build/ios-stdlib-<arch>/lib/swift (built by
#               build-ios-stdlib510.sh with ARCHS="armv7s arm64").
#   OUT         fresh absolute output directory for the fat runtime tree.
#
# Requires (environment): SDK, Xcode 13.4.1 DEVELOPER_DIR, and a Swift 5.1 source checkout
# (SWIFT51_SOURCE) for the overlay sources the armv7 pipeline borrowed from the old runtime.
#
# Everything here is a parameter of an existing single-arch script; this driver only sequences them
# per architecture and performs the lipo merge, so a change in one place applies to every slice.
set -euo pipefail
umask 022
fail() { printf 'build-multiarch-overlays: %s\n' "$*" >&2; exit 1; }

B=${1:?usage: build-multiarch-overlays.sh BUILD_ROOT OUT}
OUT=${2:?usage: build-multiarch-overlays.sh BUILD_ROOT OUT}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SDK=${SDK:?set SDK to the iPhoneOS SDK used for every slice}
SWIFT51_SOURCE=${SWIFT51_SOURCE:?set SWIFT51_SOURCE to a Swift 5.1 source checkout}
EXTRA_ARCHS=${EXTRA_ARCHS:-"armv7s arm64"}
BASELINE_ARCH=armv7
BASELINE_DEPLOYMENT=5.0
EXTRA_DEPLOYMENT=7.0

[[ "$B" = /* && "$OUT" = /* && "$SDK" = /* && "$SWIFT51_SOURCE" = /* ]] || fail 'Use absolute paths.'
[ -d "$B/build/swift" ] && [ -d "$SDK" ] || fail 'Missing build root or SDK.'
[ ! -e "$OUT" ] || fail "Refusing existing output: $OUT"

CLANG="$B/build/llvm/bin/clang"
AR="$B/build/llvm/bin/llvm-ar"
SWIFT="$B/build/swift/bin/swift-frontend"
LINKER="$B/build/llvm/bin/clang"
for tool in "$CLANG" "$AR" "$SWIFT"; do [ -x "$tool" ] || fail "Missing tool: $tool"; done

STAGE=$(CDPATH= cd -- "$B/bootstrap" && pwd -P)   # resolve symlinks: clang bakes absolute cache paths into PCHs
[ -d "$STAGE/probes" ] || fail 'Missing prepared overlay stage (bootstrap/probes).'
LIBCXX="$($CLANG -print-resource-dir 2>/dev/null || true)"
mkdir -p "$OUT"

# Overlay modules the armv7 pipeline copied from the old runtime instead of building. Their sources
# live in the Swift 5.1 checkout and they build per arch with the same recipe.
SUPPLEMENTARY="ObjectiveC CoreFoundation AVFoundation CoreAudio CoreMedia"
OVERLAYS="Dispatch CoreGraphics Foundation Metal QuartzCore CoreImage UIKit"

for ARCH in $EXTRA_ARCHS; do
  RES="$B/build/ios-stdlib-$ARCH/lib/swift"
  [ -d "$RES" ] || fail "Missing $ARCH stdlib tree: $RES (build it with ARCHS=\"$EXTRA_ARCHS\")"
  WORK="$OUT/work-$ARCH"
  mkdir -p "$WORK"

  echo "== $ARCH: Objective-C backport facades"
  LEGACY_BACKPORTS_TARGET="$ARCH-apple-ios$EXTRA_DEPLOYMENT" \
  LEGACY_BACKPORTS_ISET="$([ "$ARCH" = arm64 ] && echo ARM64 || echo ARM)" \
    bash "$HERE/build-backports-runtime.sh" "$SDK" "$CLANG" "$AR" "$WORK/backports" "$ARCH" \
    > "$OUT/log-$ARCH-backports.log" 2>&1 || { tail -20 "$OUT/log-$ARCH-backports.log" >&2; fail "$ARCH facades failed"; }

  echo "== $ARCH: Foundation backports"
  bash "$HERE/build-foundation-runtime.sh" "$SDK" "$CLANG" "$AR" "$WORK/foundation" "$ARCH" \
    > "$OUT/log-$ARCH-foundation.log" 2>&1 || { tail -20 "$OUT/log-$ARCH-foundation.log" >&2; fail "$ARCH Foundation backports failed"; }

  echo "== $ARCH: overlays"
    bash "$HERE/build-overlay-stage.sh" "$STAGE" "$SWIFT" "$SDK" "" "$ARCH" "$RES" \
    > "$OUT/log-$ARCH-overlays.log" 2>&1 || { tail -20 "$OUT/log-$ARCH-overlays.log" >&2; fail "$ARCH overlays failed"; }

  echo "== $ARCH: supplementary overlays ($SUPPLEMENTARY)"
  for NAME in $SUPPLEMENTARY; do
    SRC="$SWIFT51_SOURCE/stdlib/public/Darwin/$NAME"
    [ -d "$SRC" ] || fail "Missing overlay sources: $SRC"
    /usr/bin/arch -x86_64 "$SWIFT" -parse-as-library -module-name "$NAME" \
      -autolink-force-load -module-link-name "swift$NAME" \
      -target "$ARCH-apple-ios$EXTRA_DEPLOYMENT" -sdk "$SDK" -resource-dir "$RES" \
      -swift-version 5 -O -enable-library-evolution -emit-object -o "$WORK/$NAME.o" \
      -I "$RES/shims" -I "$STAGE/probes/dispatch-shims" \
      -Xcc -DOS_OBJECT_USE_OBJC=0 -Xcc -fmodules-cache-path="$STAGE/probes/cc-modcache" \
      "$SRC"/*.swift > "$OUT/log-$ARCH-$NAME.log" 2>&1 \
      || { tail -20 "$OUT/log-$ARCH-$NAME.log" >&2; fail "$ARCH $NAME overlay failed"; }
  done

  echo "== $ARCH: base runtime (Core, Darwin, ObjectiveC, CoreFoundation)"
  RT="$WORK/oldruntime/lib/swift/iphoneos"
  mkdir -p "$RT" "$WORK/modules"
  cp "$RES/iphoneos/$ARCH/libswiftCore.dylib" "$RES/iphoneos/$ARCH/libswiftDarwin.dylib" "$RT/"
  link_overlay() { # NAME OBJECT SWIFT-DEPS... -- FRAMEWORK-NAMES...
    local NAME="$1" OBJECT="$2"; shift 2
    local FRAMEWORKS=() LIBARGS=() seen_separator=0
    for dep in "$@"; do
      if [ "$dep" = "--" ]; then seen_separator=1; continue; fi
      if [ "$seen_separator" = 1 ]; then FRAMEWORKS+=(-framework "$dep"); else LIBARGS+=("-lswift$dep"); fi
    done
    "$LINKER" -target "$ARCH-apple-ios$EXTRA_DEPLOYMENT" -isysroot "$SDK" -dynamiclib \
      -install_name "@rpath/libswift$NAME.dylib" -o "$RT/libswift$NAME.dylib" "$OBJECT" \
      -L"$RT" -L"$RES/iphoneos" -L"$STAGE/probes/linked510-$ARCH" ${BOOTSTRAP_DISPATCH_DIR:+-L"$BOOTSTRAP_DISPATCH_DIR"} ${LIBARGS[@]+"${LIBARGS[@]}"} \
      -lswiftCompatibility50 -lc++ ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"} \
      ${FORCE_LOAD_UNDEFINED[@]+"${FORCE_LOAD_UNDEFINED[@]}"} \
      >> "$OUT/log-$ARCH-link.log" 2>&1 || { tail -20 "$OUT/log-$ARCH-link.log" >&2; fail "$ARCH libswift$NAME.dylib failed"; }
  }
  # The base runtime dylibs autolink siblings that do not exist yet (CoreFoundation -> Dispatch,
  # CoreMedia -> Foundation/Metal, ...) and the overlays in turn link against these. The autolink
  # force-load references are therefore left undefined here and are never required at run time: the
  # references are weak and the sibling is a real shipped dylib once the tree is merged.
  FORCE_LOAD_UNDEFINED=()
  for sib in Dispatch CoreGraphics Foundation Metal QuartzCore CoreAudio CoreMedia CoreFoundation ObjectiveC Darwin; do
    FORCE_LOAD_UNDEFINED+=(-Xlinker -U -Xlinker "__swift_FORCE_LOAD_\$_swift$sib")
  done
  link_overlay ObjectiveC "$WORK/ObjectiveC.o" Core Darwin --
  link_overlay CoreFoundation "$WORK/CoreFoundation.o" Core Darwin ObjectiveC -- Foundation CoreFoundation
  # AVFoundation is linked after the seven overlays so its Foundation/CoreGraphics/Dispatch/QuartzCore
  # symbols bind to the overlays that really define them; searching only the base runtime lets the
  # linker attribute them to whichever shipped dylib it happened to see first (a launch-time dyld
  # failure on iOS 27: "Symbol not found: CGFloat metadata, expected in libswiftDispatch").
  link_overlay CoreAudio "$WORK/CoreAudio.o" Core Darwin ObjectiveC -- CoreAudio
  link_overlay CoreMedia "$WORK/CoreMedia.o" Core Darwin ObjectiveC -- CoreMedia

  echo "== $ARCH: linking the seven overlays"
  # link-overlay-stage refuses to reuse an output directory; that directory is this stage's product.
  rm -rf "$STAGE/probes/linked510-$ARCH"
  LINK_OUTPUT_NAME="linked510-$ARCH" IOS_DEPLOYMENT_TARGET="$EXTRA_DEPLOYMENT" AR="$AR" \
  SWIFT51_SOURCE="$SWIFT51_SOURCE" \
  LLVM_CONFIG_INCLUDE_DIR="${LLVM_CONFIG_INCLUDE_DIR:-$B/build/llvm/include}" \
  LLVM_INCLUDE_DIR="${LLVM_INCLUDE_DIR:-$(dirname "$SWIFT51_SOURCE")/llvm/include}" \
  LEGACY_UIKIT_BACKPORTS_ARCHIVE="$WORK/backports/libswiftLegacyUIKitBackports.a" \
  LEGACY_FOUNDATION_BACKPORTS_ARCHIVE="$WORK/foundation/libswiftLegacyFoundationBackports.a" \
    bash "$HERE/link-overlay-stage.sh" "$STAGE" "$SDK" "$WORK/oldruntime" \
      "$B/build/crt-510-$ARCH-ios70/libclang_rt.builtins_${ARCH}_ios.a" \
      "$LINKER" "$SDK/usr/include/c++/v1" "$ARCH" \
    > "$OUT/log-$ARCH-dylibs.log" 2>&1 || { tail -20 "$OUT/log-$ARCH-dylibs.log" >&2; fail "$ARCH overlay link failed"; }

  echo "== $ARCH: AVFoundation overlay"
  RES_LINK="$STAGE/probes/linked510-$ARCH"
  "$LINKER" -target "$ARCH-apple-ios$EXTRA_DEPLOYMENT" -isysroot "$SDK" -dynamiclib \
    -install_name "@rpath/libswiftAVFoundation.dylib" -o "$RT/libswiftAVFoundation.dylib" "$WORK/AVFoundation.o" \
    -L"$RES_LINK" -L"$RT" -L"$RES/iphoneos" -lswiftCore -lswiftDarwin -lswiftObjectiveC -lswiftCoreFoundation \
    -lswiftDispatch -lswiftCoreGraphics -lswiftFoundation -lswiftMetal -lswiftQuartzCore \
    -lswiftCompatibility50 -lc++ -framework AVFoundation -framework CoreMedia \
    -Xlinker -U -Xlinker '__swift_FORCE_LOAD_$_swiftCoreMIDI' \
    -Xlinker -U -Xlinker '__swift_FORCE_LOAD_$_swiftUniformTypeIdentifiers' \
    -Xlinker -U -Xlinker '__swift_FORCE_LOAD_$_swiftsimd' \
    >> "$OUT/log-$ARCH-link.log" 2>&1 || { tail -20 "$OUT/log-$ARCH-link.log" >&2; fail "$ARCH libswiftAVFoundation.dylib failed"; }

  echo "== $ARCH: collecting modules"
  # Compiled modules live under <resource>/iphoneos/: the stdlib trees for Swift, Darwin, ... and the
  # overlay stage's own output (Dispatch, Foundation, UIKit, ...) for this architecture. Globbing the
  # resource root, as an earlier version did, matched nothing and shipped no module for 64-bit slices.
  for MODDIR in "$RES/iphoneos" "$STAGE/probes/modules510/iphoneos"; do
    for d in "$MODDIR"/*.swiftmodule; do
      [ -d "$d" ] || continue
      name=$(basename "$d")
      mkdir -p "$WORK/modules/$name"
      for f in "$d"/*; do case "$(basename "$f")" in "$ARCH".*|"$ARCH"-*) cp -R "$f" "$WORK/modules/$name/" ;; esac; done
    done
  done
  [ -d "$RES/iphoneos/$ARCH" ] && cp -R "$RES/iphoneos/$ARCH" "$WORK/modules/arch-$ARCH"
done

echo "== merging fat dylibs"
BASE_TC=${BASELINE_RUNTIME:-}
[ -n "$BASE_TC" ] || fail 'Set BASELINE_RUNTIME to the armv7 runtime tree (…/swift_ios5/iphoneos) being upgraded.'
[ -d "$BASE_TC" ] || fail "Missing armv7 runtime tree: $BASE_TC"
mkdir -p "$OUT/iphoneos"
for old in "$BASE_TC"/*.dylib; do
  name=$(basename "$old")
  parts=("$old")
  for ARCH in $EXTRA_ARCHS; do
    RES="$B/build/ios-stdlib-$ARCH/lib/swift"
    # The stdlib trees are rebuilt independently of this script (for example when the runtime
    # changes), so Core/Darwin always come from the freshly built per-arch tree, never from the
    # copy this script staged earlier into work-$ARCH/oldruntime.
    case "$name" in libswiftCore.dylib|libswiftDarwin.dylib|libswiftSwiftOnoneSupport.dylib|libswift_Concurrency.dylib)
      [ -f "$RES/iphoneos/$ARCH/$name" ] && { parts+=("$RES/iphoneos/$ARCH/$name"); continue; } ;;
    esac
    for candidate in "$STAGE/probes/linked510-$ARCH/$name" \
                     "$OUT/work-$ARCH/oldruntime/lib/swift/iphoneos/$name" \
                     "$RES/iphoneos/$ARCH/$name" \
                     "$B/build/ios-stdlib-$ARCH/lib/swift/iphoneos/$name"; do
      [ -f "$candidate" ] && { parts+=("$candidate"); break; }
    done
  done
  if [ "${#parts[@]}" -lt $(( $(echo $EXTRA_ARCHS | wc -w) + 1 )) ]; then
    echo "  keeping $name armv7-only (no $EXTRA_ARCHS build)" >&2
    cp "$old" "$OUT/iphoneos/$name"
  elif [ "$(lipo -archs "${parts[0]}")" = "$(lipo -archs "${parts[1]}" 2>/dev/null)" ] 2>/dev/null; then
    cp "${parts[0]}" "$OUT/iphoneos/$name"
  else
    lipo -create "${parts[@]}" -output "$OUT/iphoneos/$name" 2>/dev/null \
      || { echo "  merge failed for $name; keeping armv7" >&2; cp "$old" "$OUT/iphoneos/$name"; }
  fi
done
cp -R "$OUT/work-$BASELINE_ARCH/modules"/* "$OUT/iphoneos/" 2>/dev/null || true
for ARCH in $EXTRA_ARCHS; do
  cp -R "$OUT/work-$ARCH/modules"/. "$OUT/iphoneos/" 2>/dev/null || true
  [ -d "$OUT/work-$ARCH/modules/arch-$ARCH" ] && cp -R "$OUT/work-$ARCH/modules/arch-$ARCH" "$OUT/iphoneos/$ARCH"
done
fat=$(ls "$OUT/iphoneos"/*.dylib | wc -l | tr -d ' ')
echo "== $OUT/iphoneos: $fat dylibs merged"
