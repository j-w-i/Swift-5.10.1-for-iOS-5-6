#!/bin/bash
# Build-only persistent GUI test with real Swift cell instances over the full engine.
# Usage: build-swift-instances.sh SDK CLANG CRT_DIR NEW_OUT FRONTEND RESOURCE_DIR COMPAT_DIR STDLIB_DIR
set -euo pipefail
SDK=${1:?SDK}; CC=${2:?clang}; CRT=${3:?crt}; OUT=${4:?new output}; FE=${5:?frontend}; RES=${6:?resources}; COMPAT=${7:?compat}; STDLIB=${8:?stdlib}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[[ "$OUT" = /* && ! -e "$OUT" ]] || { echo 'Use a new absolute output directory' >&2; exit 2; }
mkdir "$OUT"
bash "$HERE/build-full-engine.sh" "$SDK" "$CC" "$CRT" "$OUT/engine"
# Reuse its tested private Swift dependency staging; no globally installed runtime libraries.
bash "$HERE/build-swift.sh" "$SDK" "$CC" "$CRT" "$OUT/metadata" "$FE" "$RES" "$COMPAT" "$STDLIB"
"$FE" -frontend -c -parse-as-library -suppress-warnings -module-name SwiftEngineInstances \
 -target armv7-apple-ios5.0 -sdk "$SDK" -resource-dir "$RES" -enable-legacy-ios5-runtime \
 -module-cache-path "$OUT/cache" -import-objc-header "$HERE/swift-instance-types.h" \
 "$HERE/swift-instance.swift" -o "$OUT/swift-instance.o"
python3 "$HERE/make-swift-instance-driver.py" "$HERE/full-engine-ui.m" "$OUT/swift-instance-ui.m"
APP="$OUT/SwiftCellRoute.app"; mkdir "$APP"
cp "$OUT/engine/RuntimeFallback.dylib" "$APP/RuntimeFallback.dylib"
cp -R "$OUT/metadata/Frameworks" "$APP/Frameworks"
# No UICCollectionViewDisplay.m here: libswiftUIKit already contains/installs the runtime hooks.
"$CC" -target armv7-apple-ios5.0 -marm -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules \
 -Wno-unguarded-availability-new -L "$CRT" -Wl,-flat_namespace "$OUT/swift-instance-ui.m" "$OUT/swift-instance.o" \
 -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics "$APP/RuntimeFallback.dylib" \
 -L "$RES/iphoneos" -L "$COMPAT" -L "$STDLIB" \
 -lswiftCore -lswiftFoundation -lswiftObjectiveC -lswiftUIKit -lswiftDarwin -lswiftDispatch \
 -lswiftCoreFoundation -lswiftCoreGraphics -lswiftCoreImage -lswiftQuartzCore -lswiftMetal \
 -Wl,-rpath,@executable_path/Frameworks -o "$APP/SwiftCellRoute"
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
with open(pathlib.Path(sys.argv[1])/'Info.plist','wb') as f:
 plistlib.dump(dict(CFBundleExecutable='SwiftCellRoute',CFBundleIdentifier='org.example.SwiftCellRoute',
 CFBundleName='SwiftCellRoute',CFBundlePackageType='APPL',CFBundleVersion='1',MinimumOSVersion='5.0',
 UIDeviceFamily=[1],CFBundleDevelopmentRegion='en'),f)
PY
ldid -S "$APP/SwiftCellRoute"
otool -L "$APP/SwiftCellRoute" > "$OUT/dependencies.txt"
tar -czf "$OUT/swift-cell-route.tgz" -C "$OUT" SwiftCellRoute.app
echo "Built real Swift cell instance experiment: $OUT"
