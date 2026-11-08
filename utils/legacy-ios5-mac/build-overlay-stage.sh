#!/bin/bash
# Build real Swift overlays from a prepared isolated stage, serially.
# Usage: build-overlay-stage.sh STAGE SWIFTC SDK [--legacy-marking] [ARCH] [RESOURCE_DIR]
#
# ARCH defaults to armv7, the legacy iOS 5 target: legacy ABI flag, ARM mode and the backport
# sources. Any other architecture (armv7s, arm64) is built without the legacy ABI flag at an
# iOS 7.0 floor, because those slices run on systems that have Apple's own runtime, and it may
# use a different resource tree (RESOURCE_DIR) so it compiles against that arch's stdlib.
set -euo pipefail
STAGE=${1:?stage}; SWIFTC=${2:?swiftc}; SDK=${3:?sdk}; MODE=${4:-}
ARCH=${5:-armv7}
RESOURCE_OVERRIDE=${6:-}
[[ "$STAGE" = /* && "$SWIFTC" = /* && "$SDK" = /* ]] || { echo 'Use absolute paths.' >&2; exit 64; }
[ -d "$STAGE/probes/modules510" ] && [ -x "$SWIFTC" ] && [ -d "$SDK" ] || { echo 'Missing prepared stage/compiler/SDK.' >&2; exit 1; }
[ -z "$MODE" ] || [ "$MODE" = --legacy-marking ] || { echo 'Unknown mode.' >&2; exit 64; }
R="${RESOURCE_OVERRIDE:-$STAGE/probes/modules510}"
EXTRA=(); TARGET=7.0
LEGACY_ARCH=0
case "$ARCH" in
  armv7|armv7s) if [ "$MODE" = --legacy-marking ] && [ "$ARCH" = armv7 ]; then LEGACY_ARCH=1; fi ;;
  arm64) LEGACY_ARCH=0 ;;
  *) echo "Unsupported overlay architecture: $ARCH" >&2; exit 64 ;;
esac
if [ "$LEGACY_ARCH" = 1 ]; then
  [ -s "$R/legacy-collection/Headers/UIKitLegacyCollection.h" ] || { echo 'Missing source-built legacy UIKit collection declarations.' >&2; exit 1; }
  EXTRA=(-enable-legacy-ios5-runtime); TARGET=5.0
fi
# Wide slices take the same backported declarations (they no longer use the
# 32-bit ABI, so no -marm and no iOS 5 floor).
[ "$LEGACY_ARCH" = 1 ] || EXTRA=(-enable-legacy-ios5-runtime)
# Every slice ships the same backported declaration surface: armv7s/arm64 run on
# systems that also lack the newer UIKit/Foundation/Dispatch declarations. Only
# the ABI differs, and that is what LEGACY_ARCH (runtime flag, -marm) controls.
LEGACY_DEFINE=(-D LEGACY_IOS5)
mkdir -p "$STAGE/logs"
# Modules are independent (separate modules, separate objects, separate logs), so they build
# concurrently. JOBS defaults to 4; the old serial behaviour was the slow path.
build_one() {
  local NAME="$1"
  local lower rc=0
    lower=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')
    [ -s "$STAGE/probes/${lower}510-sources.txt" ] || { echo "Missing source response: $NAME" >&2; exit 1; }
    mkdir -p "$R/iphoneos/$NAME.swiftmodule"
    # The SDK FileProvider overlay has no declarations, only a reexport and a
    # forced Swift-runtime-library dependency. Do not replace its module; suppress
    # that unused library for legacy clients which cannot use FileProvider anyway.
    # Accept either a driver (swiftc) or a bare swift-frontend: only the driver
    # takes -j and forwards -Xfrontend.
    case "$(basename -- "$SWIFTC")" in
      swift-frontend) JOB_FLAGS=(-disable-autolink-library swiftFileProvider) ;;
      *) JOB_FLAGS=(-j1 -Xfrontend -disable-autolink-library -Xfrontend swiftFileProvider) ;;
    esac
    # OS_OBJECT_USE_OBJC must agree between our CDispatch shim, the SDK's Dispatch
    # Clang module, and every overlay that imports dispatch headers; otherwise
    # clang reports dispatch_object_t as two incompatible module definitions.
    # A per-stage Clang module cache keeps builds reproducible and avoids stale
    # dispatch/os_object modules built under different macro state.
    # A per-invocation module cache keeps slices from sharing PCMs built under another target.
    CC_FLAGS=(-Xcc -DOS_OBJECT_USE_OBJC=0 -Xcc -fmodules-cache-path="${CLANG_MODULE_CACHE:-$STAGE/probes/cc-modcache}")
    if [ "$NAME" = Dispatch ]; then CC_FLAGS+=(-Xcc -DSWIFT_LEGACY_IOS5_CDISPATCH=1); fi
    # The legacy iOS 5 linker drops ARM/Thumb interworking bits from local
    # relocations, so Thumb code in these dylibs produces pointers that enter
    # Thumb instructions in ARM mode. Build every legacy overlay in ARM mode.
    if [ "$LEGACY_ARCH" = 1 ] && [ "$MODE" = --legacy-marking ]; then CC_FLAGS+=(-Xcc -marm); fi
    # Backported UIKit API that is Swift-only (anchors, activate/deactivate,
    # layout-guide conveniences) belongs to the UIKit overlay module, so client
    # code sees it from `import UIKit` alone. The backport builder stages those
    # sources and, when its Objective-C facades need a build-only module, a
    # module map; both are optional so older stages keep building.
    SOURCES_FILE="$STAGE/probes/${lower}510-sources.txt"
    # 64-bit slices need the sources generated with 64-bit pointer assumptions.
    if [ "$ARCH" = arm64 ] && [ -s "$STAGE/probes/${lower}510-sources-64.txt" ]; then
      SOURCES_FILE="$STAGE/probes/${lower}510-sources-64.txt"
    fi
    if [ "$NAME" = UIKit ] && [ -s "$STAGE/probes/backports-runtime/swift-sources.txt" ]; then
      # Appending must be idempotent: a re-run restores the prepared base list so
      # backport sources are never listed twice.
      if [ -s "$STAGE/probes/${lower}510-sources.base.txt" ]; then
        cp "$STAGE/probes/${lower}510-sources.base.txt" "$SOURCES_FILE"
      else
        awk '!seen[$0]++' "$SOURCES_FILE" > "$STAGE/probes/${lower}510-sources.base.txt"
      fi
      { cat "$STAGE/probes/${lower}510-sources.base.txt"; cat "$STAGE/probes/backports-runtime/swift-sources.txt"; } \
        | awk '!seen[$0]++' > "$SOURCES_FILE"
      CC_FLAGS+=(-I "$STAGE/probes/backports-runtime/Swift")
      if [ -f "$STAGE/probes/backports-runtime/include/module.modulemap" ]; then
        CC_FLAGS+=(-Xcc -fmodule-map-file="$STAGE/probes/backports-runtime/include/module.modulemap"
                   -Xcc -I"$STAGE/probes/backports-runtime/include")
      fi
    fi
    /usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$SWIFTC" ${JOB_FLAGS[@]+"${JOB_FLAGS[@]}"} \
      -parse-as-library -module-name "$NAME" -autolink-force-load \
      -target "$ARCH-apple-ios$TARGET" -sdk "$SDK" -resource-dir "$R" ${LEGACY_DEFINE[@]+"${LEGACY_DEFINE[@]}"} \
      -I "$STAGE/probes/dispatch-shims" \
      -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements \
      -enable-library-evolution -O -whole-module-optimization -emit-object -o "$STAGE/probes/${NAME}510-$ARCH.o" \
      -emit-module -emit-module-path "$R/iphoneos/$NAME.swiftmodule/$ARCH.swiftmodule" \
      -module-link-name "swift$NAME" -swift-version 5 \
      ${EXTRA[@]+"${EXTRA[@]}"} ${CC_FLAGS[@]+"${CC_FLAGS[@]}"} @"$SOURCES_FILE" \
      > "$STAGE/logs/${NAME}.log" 2>&1 || { tail -40 "$STAGE/logs/${NAME}.log" >&2; exit 1; }
}
JOBS=${JOBS:-4}
FAILED=0
for NAME in Dispatch CoreGraphics Foundation Metal QuartzCore CoreImage UIKit; do
  while [ "$(jobs -rp | wc -l | tr -d " ")" -ge "$JOBS" ]; do sleep 1; done
  ( build_one "$NAME" ) &
done
for pid in $(jobs -p); do wait "$pid" || FAILED=1; done
[ "$FAILED" = 0 ] || { echo "overlay build failed; see the per-module logs" >&2; exit 1; }
ls "$STAGE/logs"/*.log >/dev/null 2>&1 || true
