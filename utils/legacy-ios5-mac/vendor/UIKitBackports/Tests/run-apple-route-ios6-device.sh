#!/bin/bash
# Usage: bash run-apple-route-ios6-device.sh [SSH_PORT]
#
# Builds apple_route_ios6_device_test as an armv7 app, installs it on a jailbroken iOS 6/7 device
# over an iproxy port (default 2227), runs it and prints its results. This is the only test that
# exercises the collection-view hooks against real UIKit 6/7: the newer simulator cannot stand in,
# because the hooks observe UIKit 6/7 behaviour (an update pass that calls
# -_addControlledSubview:atZIndex:) that later releases do not have.
#
# Requires: a device on SSH (root, key below or DEVICE_KEY), n2launch and uicache on the device.
# Exits non-zero when the app reports a failure.
set -euo pipefail
PORT=${1:-2227}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
RUNTIME="$HERE/../Runtime"
KEY=${DEVICE_KEY:-/Users/jwalr/Developer/Neocord2-iOS5-Work/device-bridge/device-key}
DEV=${DEVICE:-root@127.0.0.1}
CLANG=${CLANG:-/Users/jwalr/Applications/Xcode-13.4.1.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang}
SDK=${SDK:-/Users/jwalr/Applications/Xcode-13.4.1.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk}
[ -x "$CLANG" ] && [ -d "$SDK" ] && [ -f "$KEY" ] || { echo "missing clang, SDK or device key" >&2; exit 2; }
OUT=$(mktemp -d "${TMPDIR:-/tmp}/apple-route.XXXXXX")
SSH=(ssh -p "$PORT" -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa)
SCP=(scp -O -P "$PORT" -i "$KEY" -o BatchMode=yes -o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa)

# The runtime keeps its iOS 5.0 floor; the app is an iOS 6 app (it needs Apple's UICollectionView).
RUNTIME_FLAGS=(-target armv7-apple-ios5.0 -marm -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules
  -Wno-unguarded-availability -Wno-unguarded-availability-new -Wno-nullability-completeness -Wno-incompatible-pointer-types)
APP_FLAGS=("${RUNTIME_FLAGS[@]/armv7-apple-ios5.0/armv7-apple-ios6.0}")
"$CLANG" "${RUNTIME_FLAGS[@]}" -I "$RUNTIME" -c "$RUNTIME/UICCollectionViewDisplay.m" -o "$OUT/display.o" 2>"$OUT/build.log" \
  || { tail -30 "$OUT/build.log" >&2; exit 1; }
APP="$OUT/AppleRoute.app"
mkdir -p "$APP"
"$CLANG" "${APP_FLAGS[@]}" -I "$RUNTIME" -L /Users/jwalr/Developer/Legacy-Build-Inputs \
  "$HERE/apple_route_ios6_device_test.m" "$OUT/display.o" \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
  -o "$APP/AppleRoute" 2>>"$OUT/build.log" || { tail -30 "$OUT/build.log" >&2; exit 1; }
ldid -S "$APP/AppleRoute" 2>/dev/null || true
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>AppleRoute</string><key>CFBundleIdentifier</key><string>org.example.AppleRoute</string><key>CFBundleName</key><string>AppleRoute</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleVersion</key><string>1</string><key>CFBundleShortVersionString</key><string>1</string><key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array><key>MinimumOSVersion</key><string>6.0</string><key>UIDeviceFamily</key><array><integer>1</integer></array><key>CFBundleDevelopmentRegion</key><string>en</string></dict></plist>
PLIST
( cd "$OUT" && tar czf app.tgz AppleRoute.app )
"${SCP[@]}" "$OUT/app.tgz" "$DEV:/tmp/" >/dev/null
# The app ends with "RESULT: ..." but only after two real animations, so wait for that line instead
# of a fixed sleep; a short sleep races it and reports a spurious failure.
"${SSH[@]}" "$DEV" 'rm -f /var/mobile/Documents/apple-route-out.txt; rm -rf /Applications/AppleRoute.app;
  cd /Applications && tar xzf /tmp/app.tgz && chown -R root:wheel AppleRoute.app && chmod 755 AppleRoute.app/AppleRoute;
  uicache; sleep 2; PATH=$PATH:/usr/local/bin n2launch org.example.AppleRoute >/dev/null 2>&1;
  for i in $(seq 1 40); do sleep 1; grep -q "^RESULT:" /var/mobile/Documents/apple-route-out.txt 2>/dev/null && break; done;
  cat /var/mobile/Documents/apple-route-out.txt; rm -rf /Applications/AppleRoute.app /tmp/app.tgz; uicache' 2>/dev/null | tee "$OUT/result.txt"
grep -q "^RESULT: PASS" "$OUT/result.txt" || { echo "Apple route device test FAILED (artifacts: $OUT)" >&2; exit 1; }
echo "PASS: Apple route (real UIKit) on the attached iOS 6/7 device"
