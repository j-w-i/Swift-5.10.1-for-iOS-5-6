#!/bin/bash
# Build-only experiment with the real PST implementation. No installation or system changes.
# Usage: build-full-engine.sh SDK CLANG CRT_DIRECTORY NEW_OUTPUT_DIRECTORY
set -euo pipefail
SDK=${1:?SDK}; CC=${2:?clang}; CRT=${3:?crt directory}; OUT=${4:?new output}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SRC=$(CDPATH= cd -- "$HERE/../.." && pwd -P)
RUNTIME=$(CDPATH= cd -- "$SRC/../UIKitBackports/Runtime" && pwd -P)
[[ "$OUT" = /* && ! -e "$OUT" ]] || { echo 'Use a new absolute output directory' >&2; exit 2; }
mkdir "$OUT" "$OUT/objects"
python3 "$HERE/generate-engine.py" "$SRC" "$OUT/generated"
FLAGS=(-target armv7-apple-ios5.0 -marm -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules
 -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -Wno-unguarded-availability-new)
for source in "$OUT/generated"/*.m; do
 "$CC" "${FLAGS[@]}" -I "$OUT/generated" -c "$source" -o "$OUT/objects/$(basename "$source" .m).o" >>"$OUT/build.log" 2>&1 || { tail -40 "$OUT/build.log" >&2; exit 1; }
done
"$CC" "${FLAGS[@]}" -dynamiclib -install_name @executable_path/RuntimeFallback.dylib "$OUT/objects"/*.o \
 -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics -o "$OUT/RuntimeFallback.dylib"
python3 - "$HERE" "$OUT" <<'PY'
import pathlib,sys
here,out=map(pathlib.Path,sys.argv[1:]);text=(here/'hierarchy.m').read_text()
old='class_getInstanceMethod(classes[i],sel_registerName("routeFallbackMarker"))!=NULL'
assert old in text
text=text.replace(old,'strstr(class_getImageName(classes[i]),"RuntimeFallback.dylib")!=NULL')
(out/'engine-identity.m').write_text(text)
PY
"$CC" "${FLAGS[@]}" -L "$CRT" -Wl,-flat_namespace "$OUT/engine-identity.m" \
 -framework UIKit -framework Foundation "$OUT/RuntimeFallback.dylib" -o "$OUT/engine-identity"
APP="$OUT/FullEngineRoute.app"; mkdir "$APP"; cp "$OUT/RuntimeFallback.dylib" "$APP/RuntimeFallback.dylib"
"$CC" "${FLAGS[@]}" -L "$CRT" -Wl,-flat_namespace "$HERE/full-engine-ui.m" "$RUNTIME/UICCollectionViewDisplay.m" \
 -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
 "$APP/RuntimeFallback.dylib" -o "$APP/FullEngineRoute" >>"$OUT/app-build.log" 2>&1 || { tail -40 "$OUT/app-build.log" >&2; exit 1; }
python3 - "$APP" <<'PY'
import pathlib,plistlib,sys
with open(pathlib.Path(sys.argv[1])/'Info.plist','wb') as f:
 plistlib.dump(dict(CFBundleExecutable='FullEngineRoute',CFBundleIdentifier='org.example.FullEngineRoute',
  CFBundleName='FullEngineRoute',CFBundlePackageType='APPL',CFBundleVersion='1',MinimumOSVersion='5.0',
  UIDeviceFamily=[1],CFBundleDevelopmentRegion='en'),f)
PY
for file in "$OUT/RuntimeFallback.dylib" "$OUT/engine-identity" "$APP/RuntimeFallback.dylib" "$APP/FullEngineRoute"; do ldid -S "$file"; done
otool -L "$APP/FullEngineRoute" > "$OUT/dependencies.txt"
tar -czf "$OUT/full-engine-route.tgz" -C "$OUT" FullEngineRoute.app
echo "Built isolated full-engine experiment: $OUT"
