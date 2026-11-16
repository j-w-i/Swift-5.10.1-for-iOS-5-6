#!/bin/bash
# check-binary-gates.sh APP.app
# Static gates every shipped legacy app must pass; each one is a class of launch failure seen on
# real devices. They are OS-agnostic on purpose: the properties must hold for any iOS version.
set -u
APP=${1:?usage: check-binary-gates.sh APP.app}
[ -d "$APP" ] && [ -f "$APP/Info.plist" ] || { echo 'GATE FAIL: expected an extracted .app bundle' >&2; exit 1; }
NAME=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist") || exit 1
EXE="$APP/$NAME"
ARCHS=$(lipo -archs "$EXE") || exit 1
[ -n "$ARCHS" ] && [ -f "$APP/Frameworks/libswiftCore.dylib" ] || { echo 'GATE FAIL: missing executable slices or embedded core' >&2; exit 1; }
FW="$APP/Frameworks"; FAIL=0
bad() { echo "GATE FAIL: $*" >&2; FAIL=1; }
for ARCH in $(lipo -archs "$EXE"); do
  [ "$ARCH" = armv7 ] && continue   # legacy ABI slice: covered by the armv7 qualification
  # 1. no /usr/lib/swift dependency or rpath: the system Swift runtime must never shadow the embedded one
  otool -arch "$ARCH" -L "$EXE" "$FW"/*.dylib 2>/dev/null | grep -q '/usr/lib/swift/' && bad "$ARCH: references /usr/lib/swift"
  for IMG in "$EXE" "$FW"/*.dylib; do
    otool -arch "$ARCH" -l "$IMG" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/path /{print $2; r=0}' | grep -qx '/usr/lib/swift' && bad "$ARCH: $(basename "$IMG") has /usr/lib/swift rpath"
    # 2. no duplicate LC_RPATH (dyld aborts on current iOS)
    D=$(otool -arch "$ARCH" -l "$IMG" 2>/dev/null | awk '/LC_RPATH/{r=1} r&&/path /{print $2; r=0}' | grep -v '^/.unavailable$' | sort | uniq -d)
    [ -z "$D" ] || bad "$ARCH: $(basename "$IMG") has duplicate LC_RPATH $D"
    # 3. every weak/strong @rpath dylib the image asks for is shipped (or deliberately neutralised)
    for DEP in $(otool -arch "$ARCH" -L "$IMG" 2>/dev/null | awk 'NR>1{print $1}' | grep '^@rpath/'); do
      [ -f "$FW/$(basename "$DEP")" ] || bad "$ARCH: $(basename "$IMG") needs missing $DEP"
    done
  done
  # 4. the 64-bit executable is tagged with a current linked SDK (UIKit layout rules key on it)
  if [ "$ARCH" = arm64 ]; then
    SDK=$(otool -arch arm64 -l "$EXE" | awk '/sdk /{print $2; exit}'); MAJOR=${SDK%%.*}
    [ "${MAJOR:-0}" -ge 19 ] || bad "arm64 executable linked-SDK tag is $SDK (<19): modern UIKit layout would not apply"
  fi
  # 5. embedded stdlib exports the runtime's class-bit switch (wide slices)
  nm -arch "$ARCH" -gU "$FW/libswiftCore.dylib" 2>/dev/null | grep -q '__swift_classIsSwiftMask' || bad "$ARCH: libswiftCore lacks the load-time class-bit switch"
done
[ "$FAIL" = 0 ] && echo "PASS: binary gates ($(lipo -archs "$EXE"))"
exit $FAIL
