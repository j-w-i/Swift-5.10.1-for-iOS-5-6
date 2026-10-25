#!/bin/bash
# Build real legacy Swift overlays from a prepared isolated stage, serially.
# Usage: build-overlay-stage.sh STAGE SWIFTC SDK [--legacy-marking]
set -euo pipefail
STAGE=${1:?stage}; SWIFTC=${2:?swiftc}; SDK=${3:?sdk}; MODE=${4:-}
[[ "$STAGE" = /* && "$SWIFTC" = /* && "$SDK" = /* ]] || { echo 'Use absolute paths.' >&2; exit 64; }
[ -d "$STAGE/probes/modules510" ] && [ -x "$SWIFTC" ] && [ -d "$SDK" ] || { echo 'Missing prepared stage/compiler/SDK.' >&2; exit 1; }
[ -z "$MODE" ] || [ "$MODE" = --legacy-marking ] || { echo 'Unknown mode.' >&2; exit 64; }
R="$STAGE/probes/modules510"
EXTRA=()
[ -z "$MODE" ] || EXTRA=(-enable-legacy-ios5-class-marking)
mkdir -p "$STAGE/logs"
for NAME in Dispatch Foundation CoreGraphics Metal QuartzCore CoreImage UIKit; do
  lower=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')
  [ -s "$STAGE/probes/${lower}510-sources.txt" ] || { echo "Missing source response: $NAME" >&2; exit 1; }
  mkdir -p "$R/iphoneos/$NAME.swiftmodule"
  FLAGS=()
  if [ "$NAME" = Dispatch ]; then
    FLAGS=(-Xcc -DOS_OBJECT_USE_OBJC=0 -Xcc -DSWIFT_LEGACY_IOS5_CDISPATCH=1)
  fi
  # The SDK FileProvider overlay has no declarations, only a reexport and a
  # forced Swift-runtime-library dependency. Do not replace its module; suppress
  # that unused library for legacy clients which cannot use FileProvider anyway.
  /usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$SWIFTC" -j1 -parse-as-library -module-name "$NAME" \
    -target armv7-apple-ios7.0 -sdk "$SDK" -resource-dir "$R" -D LEGACY_IOS5 \
    -I "$STAGE/probes/dispatch-shims" \
    -Xfrontend -disable-autolink-library -Xfrontend swiftFileProvider \
    -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements \
    -enable-library-evolution -O -whole-module-optimization -emit-object -o "$STAGE/probes/${NAME}510.o" \
    -emit-module -emit-module-path "$R/iphoneos/$NAME.swiftmodule/armv7.swiftmodule" \
    -module-link-name "swift$NAME" -swift-version 5 \
    ${EXTRA[@]+"${EXTRA[@]}"} ${FLAGS[@]+"${FLAGS[@]}"} @"$STAGE/probes/${lower}510-sources.txt" \
    > "$STAGE/logs/${NAME}.log" 2>&1 || { tail -40 "$STAGE/logs/${NAME}.log" >&2; exit 1; }
  echo "$NAME module/object built (not runtime-qualified)"
done
