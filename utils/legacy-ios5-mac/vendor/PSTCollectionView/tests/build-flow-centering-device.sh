#!/bin/bash
# Build only: persistent shared test app, no installation/removal/launching.
# Usage: build-flow-centering-device.sh SDK CLANG CRT_DIR NEW_OUT
# FLOW_CENTERING_NAME/ID allow side-by-side before/after installations.
set -euo pipefail
SDK=${1:?SDK};CC=${2:?clang};CRT=${3:?crt};OUT=${4:?new output}
NAME=${FLOW_CENTERING_NAME:-FlowCentering};ID=${FLOW_CENTERING_ID:-org.example.FlowCentering}
[[ "$NAME" =~ ^[A-Za-z][A-Za-z0-9]*$ && "$ID" =~ ^[A-Za-z0-9.-]+$ ]] || exit 64
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[[ "$OUT" = /* && ! -e "$OUT" ]] || { echo 'Use a new absolute output directory' >&2;exit 2; }
mkdir "$OUT"
bash "$HERE/runtime-selection-spike/build-full-engine.sh" "$SDK" "$CC" "$CRT" "$OUT/engine"
APP="$OUT/$NAME.app";mkdir "$APP";cp "$OUT/engine/RuntimeFallback.dylib" "$APP/RuntimeFallback.dylib"
"$CC" -target armv7-apple-ios5.0 -marm -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules \
 -DDEVICE_APP=1 -Wno-unguarded-availability-new -L "$CRT" -Wl,-flat_namespace "$HERE/flow-row-centering.m" \
 -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
 "$APP/RuntimeFallback.dylib" -o "$APP/$NAME" >"$OUT/app-build.log" 2>&1 || { tail -30 "$OUT/app-build.log" >&2;exit 1; }
python3 - "$APP" "$NAME" "$ID" <<'PY'
import pathlib,plistlib,sys
with open(pathlib.Path(sys.argv[1])/'Info.plist','wb') as f:
 plistlib.dump(dict(CFBundleExecutable=sys.argv[2],CFBundleIdentifier=sys.argv[3],CFBundleName=sys.argv[2],
 CFBundlePackageType='APPL',CFBundleVersion='1',MinimumOSVersion='5.0',UIDeviceFamily=[1],CFBundleDevelopmentRegion='en'),f)
PY
ldid -S "$APP/$NAME"
otool -L "$APP/$NAME" > "$OUT/dependencies.txt"
tar -czf "$OUT/flow-centering.tgz" -C "$OUT" "$NAME.app"
echo "Built persistent flow centering gate: $OUT ($ID)"
