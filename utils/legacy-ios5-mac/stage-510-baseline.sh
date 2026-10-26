#!/bin/bash
# Compose the complete Swift 5.10.1 host toolchain layout from build products.
#
# assemble-510-toolchain.sh copies a complete toolchain ("baseline") and then replaces the
# compiler, adds the iOS 5 resource slot and signs the result. This script produces that baseline
# entirely from this build: the host compiler tools compiled by swift-510/driver-510, the clang
# resource directory from llvm-510, the host Swift resources from the host build, and the iOS
# standard library built by build-ios-stdlib510.sh. No prebuilt toolchain package is involved.
#
# Output: <LEGACY_BUILD_ROOT>/out/swift-5.10.1-baseline.xctoolchain
set -euo pipefail

B="${LEGACY_BUILD_ROOT:?set LEGACY_BUILD_ROOT}"
L="$B/build/llvm"
S="$B/build/swift"
OUT="$B/out/swift-5.10.1-baseline.xctoolchain"
DRIVER="$B/src/swift-driver/.build/x86_64-apple-macosx/debug/swift-driver"

[ -x "$S/bin/swift-frontend" ] || { echo "missing built swift-frontend (run swift-510)" >&2; exit 1; }
[ -x "$DRIVER" ] || { echo "missing built swift-driver (run driver-510)" >&2; exit 1; }
[ -d "$B/out/ios-stdlib/lib/swift/iphoneos" ] || { echo "missing source-built iOS stdlib (run stdlib-510-ios)" >&2; exit 1; }
[ -d "$L/lib/clang" ] || { echo "missing clang resource directory (run llvm-510)" >&2; exit 1; }

echo "== composing $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/usr/bin" "$OUT/usr/lib/clang"

# Host Swift resources produced by the host build (host dylibs, migrator data, ABI baseline...).
# The build tree represents some of these as symlinks into the source checkout; a redistributable
# toolchain must be relocatable (the kit refuses absolute/escaping links), so copy the link targets.
if [ -x /usr/bin/rsync ]; then
  /usr/bin/rsync -a --copy-links "$S/lib/swift/" "$OUT/usr/lib/swift/"
else
  mkdir -p "$OUT/usr/lib/swift"
  cp -RL "$S/lib/swift/." "$OUT/usr/lib/swift/"
fi
rm -rf "$OUT/usr/lib/swift/iphoneos"

# The iOS standard library and the resource-tree scaffolding built from source.
cp -R "$B/out/ios-stdlib/lib/swift/iphoneos" "$OUT/usr/lib/swift/iphoneos"
cp -R "$B/out/ios-stdlib/lib/swift/apinotes" "$B/out/ios-stdlib/lib/swift/shims" \
      "$B/out/ios-stdlib/lib/swift/module.modulemap" "$OUT/usr/lib/swift/"

CLANG_VERSION="$(ls -1 "$L/lib/clang" | sort -V | tail -1)"
cp -R "$L/lib/clang/$CLANG_VERSION" "$OUT/usr/lib/clang/"
ln -sfn "../clang/$CLANG_VERSION" "$OUT/usr/lib/swift/clang"
[ -f "$OUT/usr/lib/clang/$CLANG_VERSION/include/stdarg.h" ] || { echo "clang resource directory lacks stdarg.h" >&2; exit 1; }

# Host compiler binaries built from source.
cp "$S/bin/swift-frontend" "$OUT/usr/bin/"
cp "$DRIVER" "$OUT/usr/bin/swift-driver"
for alias in swift swiftc; do cp "$DRIVER" "$OUT/usr/bin/$alias"; done
for tool in swift-demangle swift-api-digester; do
  [ -x "$S/bin/$tool" ] && cp "$S/bin/$tool" "$OUT/usr/bin/"
done
cp "$L/bin/clang" "$OUT/usr/bin/clang"
ln -s clang "$OUT/usr/bin/clang++"
for tool in llvm-ar llvm-nm llvm-ranlib llvm-objdump llvm-lipo; do
  [ -x "$L/bin/$tool" ] && cp "$L/bin/$tool" "$OUT/usr/bin/"
done

cat > "$OUT/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.swift.5101.baseline.fromsource</string>
  <key>CFBundleName</key><string>Swift 5.10.1 baseline (from source)</string>
  <key>CompatibilityVersion</key><integer>2</integer>
  <key>CompatibilityVersionDisplayString</key><string>Xcode 8.0</string>
  <key>DisplayName</key><string>Swift 5.10.1 baseline (from source)</string>
  <key>ShortDisplayName</key><string>Swift 5.10.1 baseline</string>
  <key>Version</key><string>5.10.1</string>
</dict></plist>
PL

# Any remaining absolute symlink would break relocation on the user's machine.
ABSOLUTE_LINKS="$(find "$OUT" -type l -exec sh -c 'case "$(readlink "$1")" in /*) echo "$1";; esac' _ {} \; | head -5)"
[ -z "$ABSOLUTE_LINKS" ] || { echo "refusing a toolchain with absolute symlinks:" >&2; printf '%s\n' "$ABSOLUTE_LINKS" >&2; exit 1; }

echo "composed $OUT ($(du -sh "$OUT" | cut -f1))"
echo "default resources: $(ls "$OUT/usr/lib/swift/iphoneos"/*.dylib 2>/dev/null | wc -l | tr -d ' ') fat dylibs, $(ls -d "$OUT/usr/lib/swift/iphoneos"/*.swiftmodule 2>/dev/null | wc -l | tr -d ' ') modules"
