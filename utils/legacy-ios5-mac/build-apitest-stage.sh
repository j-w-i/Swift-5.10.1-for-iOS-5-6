#!/bin/bash
# Compile/link full smoke source using a matched stage; no signing/deployment.
# Args: STAGE SWIFTC SDK OLD_RUNTIME_DIR CRT1 BUILTINS_ARCHIVE CLANG SOURCE [--legacy]
set -euo pipefail
[ "$#" -ge 8 ] && [ "$#" -le 9 ] || { echo 'Expected eight explicit paths and optional --legacy.' >&2; exit 64; }
STAGE=$1; SWIFTC=$2; SDK=$3; OLD=$4; CRT1=$5; BUILTINS=$6; CLANG=$7; SOURCE=$8; MODE=${9:-}
for p in "$STAGE" "$SWIFTC" "$SDK" "$OLD" "$CRT1" "$BUILTINS" "$CLANG" "$SOURCE"; do
  [[ "$p" = /* ]] || { echo 'Use absolute paths.' >&2; exit 64; }
done
[ -z "$MODE" ] || [ "$MODE" = --legacy ] || exit 64
L="$STAGE/probes/${LINK_OUTPUT_NAME:-linked510}"
[[ "${LINK_OUTPUT_NAME:-linked510}" != */* && "${LINK_OUTPUT_NAME:-linked510}" != .* ]] || exit 64
OUT_NAME=${APITEST_NAME:-ApiTest-qualified}
case "$OUT_NAME" in */*|.*) echo 'APITEST_NAME must be a simple non-hidden name.' >&2; exit 64 ;; esac
[ ! -e "$STAGE/probes/$OUT_NAME" ] && [ ! -L "$STAGE/probes/$OUT_NAME" ] || { echo 'Output already exists.' >&2; exit 1; }
OLDLIB="$OLD/lib/swift/iphoneos"; [ -d "$OLDLIB" ] || OLDLIB=$OLD
[ -s "$L/libLegacyRuntimeBackports.a" ] && [ -s "$SOURCE" ] && [ -s "$CRT1" ] && [ -s "$BUILTINS" ] || { echo 'Missing real inputs.' >&2; exit 1; }
FLAGS=(); TARGET=7.0
if [ "$MODE" = --legacy ]; then FLAGS=(-enable-legacy-ios5-runtime); TARGET=5.0; fi
# The full runtime option validates archive/CRT resources even when producing
# objects only in some drivers; the stage is the selected explicit resource root.
# A bare swift-frontend has no -j and takes -disable-autolink-library directly.
case "$(basename -- "$SWIFTC")" in
  swift-frontend) JOB_FLAGS=(-disable-autolink-library swiftFileProvider) ;;
  *) JOB_FLAGS=(-j1 -Xfrontend -disable-autolink-library -Xfrontend swiftFileProvider) ;;
esac
/usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$SWIFTC" ${JOB_FLAGS[@]+"${JOB_FLAGS[@]}"} -target "armv7-apple-ios$TARGET" \
 -sdk "$SDK" -resource-dir "$STAGE/probes/modules510" -I "$STAGE/probes/dispatch-shims" \
 -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements \
 ${FLAGS[@]+"${FLAGS[@]}"} -O -emit-object -module-name ApiTest "$SOURCE" -o "$STAGE/probes/$OUT_NAME.o"
/usr/bin/nice -n 15 "$CLANG" -target armv7-apple-ios5.0 -isysroot "$SDK" -nostartfiles \
 "$STAGE/probes/$OUT_NAME.o" "$CRT1" "$L/libLegacyRuntimeBackports.a" \
 -L "$L" -L "$OLDLIB" -lswiftCore -lswiftFoundation -lswiftDispatch -lswiftUIKit \
 -lswiftDarwin -lswiftObjectiveC -lswiftCoreFoundation -lswiftCoreGraphics -lswiftCoreImage -lswiftQuartzCore -lswiftMetal \
 -framework UIKit -framework Foundation -lobjc -lSystem -lc++ \
 -Wl,-rpath,@executable_path/Frameworks -Wl,-no_new_main -Wl,-force_load,"$BUILTINS" \
 -o "$STAGE/probes/$OUT_NAME"
echo 'ApiTest linked; static imports/metadata/startup audit and device execution remain separate.'
