#!/bin/bash
# Package the from-source Swift 5.1.5 iOS runtime (the `runtime-default` build) as a runtime-only
# .xctoolchain: the Swift 5.1.5 slot the iOS 6 guide route bundles into an app.
#
# Why this exact build: a stock swift.org 5.1.5 dylib imports C11 atomics (___atomic_store & friends)
# from /usr/lib/libSystem.dylib, which only provides them from iOS 7. The iOS 6 device dyld stops at
# launch with "Symbol not found: ___atomic_store". compiler-rt's atomic.c is what defines those symbols;
# it is only compiled in when the tree keeps the unconditional `set(GENERIC_SOURCES ... atomic.c)` in
# compiler-rt/lib/builtins/CMakeLists.txt (the author's iOS 6 patch, committed in the llvm-project fork)
# and the runtime is linked with `-Wl,-force_load,<libclang_rt.ios.a>` (configure-ios-runtime.sh does).
# This script refuses to package a runtime that still imports them.
#
# Usage: package-runtime-515.sh [OUTPUT.xctoolchain]
#   Defaults to $LEGACY_BUILD_ROOT/out/swift-5.1.5-ios6-runtime.xctoolchain, plus a .tar.gz beside it.
set -euo pipefail

ROOT="${LEGACY_BUILD_ROOT:?set LEGACY_BUILD_ROOT}"
SRC="$ROOT/b515/build/runtime-default/lib/swift"
OUT="${1:-$ROOT/out/swift-5.1.5-ios6-runtime.xctoolchain}"

[ -d "$SRC/iphoneos" ] || { echo "missing $SRC/iphoneos; run the runtime-515 stage first" >&2; exit 1; }
[ ! -e "$OUT" ] || { echo "refusing to overwrite existing $OUT" >&2; exit 1; }

# Verification tools come from the host Xcode selected for the build (a macOS host is already required
# by the runtime-515 stage), so a valid armv7 Mach-O reader is always available.
NM="${NM:-/usr/bin/nm}"
LIPO="${LIPO:-/usr/bin/lipo}"

# 1. Every armv7 image must be free of C11 atomic imports; that is the property iOS 6 needs.
ATOMIC_IMPORTS="$(
  for f in "$SRC"/iphoneos/*.dylib; do
    "$LIPO" -verify_arch armv7 "$f" 2>/dev/null || continue
    "$NM" -arch armv7 -u "$f" 2>/dev/null | /usr/bin/grep -E '^___atomic_(load|store|compare_exchange|exchange|fetch)' || true
  done
)"
if [ -n "$ATOMIC_IMPORTS" ]; then
  echo 'Refusing to package a runtime that imports C11 atomics (iOS 6 has no such libSystem exports):' >&2
  printf '%s\n' "$ATOMIC_IMPORTS" >&2
  echo 'Rebuild compiler-rt with atomic.c (build-compiler-rt.sh) and relink the runtime (configure-ios-runtime.sh).' >&2
  exit 1
fi

# 2. Assemble the runtime-only toolchain. Test-only libraries are dropped: an app runtime never loads
#    them, and their XCTest/StdlibUnittest counterparts are not part of the shipped product.
mkdir -p "$OUT/usr/lib/swift"
cp -R "$SRC/iphoneos" "$SRC/shims" "$SRC/apinotes" "$OUT/usr/lib/swift/"
for d in libswiftRuntimeUnittest.dylib libswiftStdlibUnittest.dylib \
         libswiftStdlibUnittestFoundationExtras.dylib libswiftSwiftPrivate.dylib \
         libswiftSwiftPrivateLibcExtras.dylib libswiftSwiftPrivateThreadExtras.dylib; do
  /bin/rm -f "$OUT/usr/lib/swift/iphoneos/$d"
done
for m in RuntimeUnittest StdlibUnittest StdlibUnittestFoundationExtras SwiftPrivate \
         SwiftPrivateLibcExtras SwiftPrivateThreadExtras; do
  /bin/rm -rf "$OUT/usr/lib/swift/iphoneos/$m.swiftmodule"
done

cat > "$OUT/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.swift.515120200323a</string>
  <key>CompatibilityVersion</key><integer>2</integer>
  <key>CompatibilityVersionDisplayString</key><string>Xcode 8.0</string>
  <key>DisplayName</key><string>Swift 5.1.5 iOS runtime (iOS 6 guide route, from source)</string>
  <key>ShortDisplayName</key><string>Swift 5.1.5 iOS6 runtime</string>
  <key>Version</key><string>5.1.5</string>
  <key>Aliases</key><array><string>swift</string></array>
  <key>OverrideBuildSettings</key><dict><key>ENABLE_BITCODE</key><string>NO</string></dict>
</dict></plist>
PL

# 2b. Version stamps. The runtime libraries are linked by different tools, so their
# LC_ID_DYLIB versions can disagree with what their consumers require (iOS 5/6 dyld
# refuses the image: "libswiftos.dylib requires version 1.0.0 ... but
# libswiftDispatch.dylib provides version 0.0.0"). Raise them to the highest
# compatibility version any packaged library requires.
/usr/bin/python3 "$(dirname "$0")/normalize-dylib-versions.py" "$OUT/usr/lib/swift/iphoneos"

# 3. Release-importable archive (the SDK imports a single .xctoolchain from an archive).
(cd "$(dirname "$OUT")" && /usr/bin/tar -czf "$(basename "$OUT").tar.gz" "$(basename "$OUT")")
echo "packaged $(ls "$OUT/usr/lib/swift/iphoneos"/*.dylib | wc -l | tr -d ' ') dylibs into $OUT"
echo "archive: $OUT.tar.gz"
