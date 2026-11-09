#!/bin/bash
# Build the media overlays (CoreAudio, CoreMedia, AVFoundation) for the legacy armv7 slice and link them
# against the armv7 runtime. The multiarch stage builds these for armv7s/arm64; armv7 needs its own so
# the assembled toolchain ships the media dylibs the app autolinks.
# Usage: build-media-overlays-armv7.sh STAGE SDK SWIFT51_SOURCE FRONTEND LINKER OUT [RT] [LIBDIR]
set -euo pipefail
fail() { echo "build-media-overlays-armv7: $*" >&2; exit 1; }
STAGE=$1; SDK=$2; SWIFT51=$3; SWIFT=$4; LINKER=$5; OUT=$6; RT=${7:-}; LIBDIRS=${8:-$RT}
LIB_FLAGS=()
IFS=":" read -ra DIRS <<< "$LIBDIRS"
for D in "${DIRS[@]}"; do LIB_FLAGS+=(-L"$D"); done
[ -d "$STAGE/probes" ] || fail "missing stage"
mkdir -p "$OUT"; W="$OUT/work"; mkdir -p "$W"
RES="$STAGE/probes/modules510"
for NAME in CoreAudio CoreMedia AVFoundation; do
  # The Swift 5.1 media overlay sources annotate APIs newer than the iOS 5 floor; the shipped armv7
  # media slices have always been built at that floor (LC_VERSION_MIN_IPHONEOS 5.0). The suppression
  # is confined to these three vendored overlays; project builds never enable it.
  EXTRA_FLAGS=""
  [ "$NAME" = AVFoundation ] && EXTRA_FLAGS="-disable-availability-checking"
  SRC="$SWIFT51/stdlib/public/Darwin/$NAME"
  [ -d "$SRC" ] || fail "missing overlay sources: $SRC"
  /usr/bin/arch -x86_64 "$SWIFT" -parse-as-library -module-name "$NAME" \
    -autolink-force-load -module-link-name "swift$NAME" \
    -target armv7-apple-ios5.0 -sdk "$SDK" -resource-dir "$RES" \
    -swift-version 5 -O -enable-library-evolution -emit-object -o "$W/$NAME.o" \
    -I "$RES/shims" -I "$STAGE/probes/dispatch-shims" \
    -Xcc -DOS_OBJECT_USE_OBJC=0 -Xcc -fmodules-cache-path="$STAGE/probes/cc-modcache-armv7-$NAME" $EXTRA_FLAGS \
    "$SRC"/*.swift > "$OUT/log-$NAME.log" 2>&1 || { tail -20 "$OUT/log-$NAME.log" >&2; fail "$NAME compile"; }
done
[ -n "$RT" ] || fail "RT (armv7 runtime dir) required"
link() { # NAME DEPS...
  local NAME=$1; shift
  "$LINKER" -target armv7-apple-ios5.0 -isysroot "$SDK" -dynamiclib \
    -install_name "@rpath/libswift$NAME.dylib" -o "$RT/libswift$NAME.dylib" "$W/$NAME.o" \
    -L"$RT" ${LIB_FLAGS[@]+"${LIB_FLAGS[@]}"} -L"$STAGE/probes/linked510-legacy" $* -lc++ -lswiftCompatibility50 -lswiftCompatibility51 -lswiftCompatibility56 \
    -Xlinker -U -Xlinker '__swift_FORCE_LOAD_$_swiftCoreMIDI' \
    -Xlinker -U -Xlinker '__swift_FORCE_LOAD_$_swiftUniformTypeIdentifiers' \
    -Xlinker -U -Xlinker '__swift_FORCE_LOAD_$_swiftsimd' \
    >> "$OUT/link.log" 2>&1 || { tail -20 "$OUT/link.log" >&2; fail "$NAME link"; }
}
link CoreAudio -lswiftCore -lswiftDarwin -lswiftObjectiveC -framework CoreAudio
link CoreMedia -lswiftCore -lswiftDarwin -lswiftObjectiveC -lswiftCoreAudio -lswiftCoreFoundation -lswiftCoreGraphics -lswiftDispatch -lswiftFoundation -lswiftMetal -framework CoreMedia
link AVFoundation -lswiftCore -lswiftDarwin -lswiftObjectiveC -lswiftCoreAudio -lswiftCoreMedia -lswiftCoreFoundation -lswiftCoreGraphics -lswiftDispatch -lswiftFoundation -lswiftMetal -lswiftQuartzCore -framework AVFoundation -framework CoreMedia
echo "armv7 media overlays: $RT"
