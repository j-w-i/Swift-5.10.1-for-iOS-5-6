#!/bin/bash
# Build only. Installs/runs nothing; generated app returns from launch and stays alive.
# Usage: build-modern-api.sh SDK CLANG CRT_DIRECTORY NEW_OUTPUT_DIRECTORY
set -euo pipefail
SDK=${1:?SDK}; CC=${2:?clang}; CRT=${3:?crt}; OUT=${4:?new output}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
BACKPORT=$(CDPATH= cd -- "$HERE/../../../UIKitBackports" && pwd -P)
[[ "$OUT" = /* && ! -e "$OUT" ]] || { echo 'Use a new absolute output directory' >&2; exit 2; }
mkdir "$OUT"
bash "$HERE/build-full-engine.sh" "$SDK" "$CC" "$CRT" "$OUT/engine"
python3 "$HERE/make-modern-api-driver.py" "$BACKPORT/Tests/apple_route_ios6_device_test.m" "$OUT/modern-api-ui.m"
APP="$OUT/ModernRouteAPIs.app";mkdir "$APP";cp "$OUT/engine/RuntimeFallback.dylib" "$APP/RuntimeFallback.dylib"
"$CC" -target armv7-apple-ios5.0 -marm -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules \
 -Wno-unguarded-availability-new -Wno-nullability-completeness -L "$CRT" -Wl,-flat_namespace \
 "$OUT/modern-api-ui.m" "$BACKPORT/Runtime/UICCollectionViewDisplay.m" \
 -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
 "$APP/RuntimeFallback.dylib" -o "$APP/ModernRouteAPIs" >"$OUT/app-build.log" 2>&1 || { tail -40 "$OUT/app-build.log" >&2;exit 1; }
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
with open(pathlib.Path(sys.argv[1])/'Info.plist','wb') as f:
 plistlib.dump(dict(CFBundleExecutable='ModernRouteAPIs',CFBundleIdentifier='org.example.ModernRouteAPIs',
  CFBundleName='ModernRouteAPIs',CFBundlePackageType='APPL',CFBundleVersion='1',MinimumOSVersion='5.0',
  UIDeviceFamily=[1],CFBundleDevelopmentRegion='en'),f)
PY
ldid -S "$APP/ModernRouteAPIs"
otool -L "$APP/ModernRouteAPIs" > "$OUT/dependencies.txt"
tar -czf "$OUT/modern-route-apis.tgz" -C "$OUT" ModernRouteAPIs.app
echo "Built persistent modern API gate: $OUT"
