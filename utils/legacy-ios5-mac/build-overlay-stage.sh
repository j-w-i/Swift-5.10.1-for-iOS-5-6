#!/bin/bash
# Build real legacy Swift overlays from a prepared isolated stage, serially.
# Usage: build-overlay-stage.sh STAGE SWIFTC SDK [--legacy-marking]
set -euo pipefail
STAGE=${1:?stage}; SWIFTC=${2:?swiftc}; SDK=${3:?sdk}; MODE=${4:-}
[[ "$STAGE" = /* && "$SWIFTC" = /* && "$SDK" = /* ]] || { echo 'Use absolute paths.' >&2; exit 64; }
[ -d "$STAGE/probes/modules510" ] && [ -x "$SWIFTC" ] && [ -d "$SDK" ] || { echo 'Missing prepared stage/compiler/SDK.' >&2; exit 1; }
[ -z "$MODE" ] || [ "$MODE" = --legacy-marking ] || { echo 'Unknown mode.' >&2; exit 64; }
R="$STAGE/probes/modules510"
EXTRA=(); TARGET=7.0
if [ "$MODE" = --legacy-marking ]; then
  [ -s "$R/legacy-collection/Headers/UIKitLegacyCollection.h" ] || { echo 'Missing source-built legacy UIKit collection declarations.' >&2; exit 1; }
  EXTRA=(-enable-legacy-ios5-runtime); TARGET=5.0
fi
mkdir -p "$STAGE/logs"
for NAME in Dispatch CoreGraphics Foundation Metal QuartzCore CoreImage UIKit; do
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
  CC_FLAGS=(-Xcc -DOS_OBJECT_USE_OBJC=0 -Xcc -fmodules-cache-path="$STAGE/probes/cc-modcache")
  if [ "$NAME" = Dispatch ]; then CC_FLAGS+=(-Xcc -DSWIFT_LEGACY_IOS5_CDISPATCH=1); fi
  # The legacy iOS 5 linker drops ARM/Thumb interworking bits from local
  # relocations, so Thumb code in these dylibs produces pointers that enter
  # Thumb instructions in ARM mode. Build every legacy overlay in ARM mode.
  if [ "$MODE" = --legacy-marking ]; then CC_FLAGS+=(-Xcc -marm); fi
  /usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$SWIFTC" ${JOB_FLAGS[@]+"${JOB_FLAGS[@]}"} \
    -parse-as-library -module-name "$NAME" -autolink-force-load \
    -target "armv7-apple-ios$TARGET" -sdk "$SDK" -resource-dir "$R" -D LEGACY_IOS5 \
    -I "$STAGE/probes/dispatch-shims" \
    -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements \
    -enable-library-evolution -O -whole-module-optimization -emit-object -o "$STAGE/probes/${NAME}510.o" \
    -emit-module -emit-module-path "$R/iphoneos/$NAME.swiftmodule/armv7.swiftmodule" \
    -module-link-name "swift$NAME" -swift-version 5 \
    ${EXTRA[@]+"${EXTRA[@]}"} ${CC_FLAGS[@]+"${CC_FLAGS[@]}"} @"$STAGE/probes/${lower}510-sources.txt" \
    > "$STAGE/logs/${NAME}.log" 2>&1 || { tail -40 "$STAGE/logs/${NAME}.log" >&2; exit 1; }
  echo "$NAME module/object built (not runtime-qualified)"
done
