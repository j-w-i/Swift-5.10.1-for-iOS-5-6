#!/bin/bash
# Build-only experiment. Does not install, launch, respring, or alter the production runtime.
# Usage: bash build.sh SDK CLANG CRT_DIRECTORY NEW_OUTPUT_DIRECTORY
set -euo pipefail
SDK=${1:?SDK}; CC=${2:?clang}; CRT=${3:?directory containing crt1.3.1.o}; OUT=${4:?new output directory}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[[ "$OUT" = /* && ! -e "$OUT" ]] || { echo 'Use a new absolute output directory' >&2; exit 2; }
mkdir "$OUT"
FLAGS=(-target armv7-apple-ios5.0 -marm -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules -Wno-unguarded-availability-new)
"$CC" "${FLAGS[@]}" -dynamiclib -install_name @executable_path/SpikeEngine.dylib "$HERE/stand-in.m" -framework UIKit -framework Foundation -o "$OUT/SpikeEngine.dylib"
# Positive: system libraries BEFORE fallback in LC_LOAD_DYLIB order.
"$CC" "${FLAGS[@]}" -L "$CRT" -Wl,-flat_namespace "$HERE/binding.m" -framework UIKit -framework Foundation "$OUT/SpikeEngine.dylib" -o "$OUT/binding-uikit-first"
# Negative: reproduces split class identity on iOS 6. Run only this non-UI program.
"$CC" "${FLAGS[@]}" -L "$CRT" -Wl,-flat_namespace "$HERE/binding.m" "$OUT/SpikeEngine.dylib" -framework UIKit -framework Foundation -o "$OUT/binding-engine-first"
mkdir "$OUT/RouteBinding.app"
cp "$OUT/SpikeEngine.dylib" "$OUT/RouteBinding.app/SpikeEngine.dylib"
"$CC" "${FLAGS[@]}" -L "$CRT" -Wl,-flat_namespace "$HERE/persistent-ui.m" -framework UIKit -framework Foundation "$OUT/RouteBinding.app/SpikeEngine.dylib" -o "$OUT/RouteBinding.app/RouteBinding"
python3 - "$OUT" <<'PY'
import plistlib,sys
with open(sys.argv[1]+'/RouteBinding.app/Info.plist','wb') as f:
    plistlib.dump(dict(CFBundleExecutable='RouteBinding', CFBundleIdentifier='org.example.RouteBinding',
        CFBundleName='RouteBinding', CFBundlePackageType='APPL', CFBundleVersion='1',
        MinimumOSVersion='5.0', UIDeviceFamily=[1], CFBundleDevelopmentRegion='en'), f)
PY
for file in "$OUT/SpikeEngine.dylib" "$OUT/binding-uikit-first" "$OUT/binding-engine-first" "$OUT/RouteBinding.app/SpikeEngine.dylib" "$OUT/RouteBinding.app/RouteBinding"; do ldid -S "$file"; done
otool -L "$OUT/binding-uikit-first" > "$OUT/dependencies.txt"
"$CC" "${FLAGS[@]}" -dynamiclib -install_name @executable_path/HierarchyFallback.dylib "$HERE/hierarchy-stand-in.m" -framework UIKit -framework Foundation -o "$OUT/HierarchyFallback.dylib"
"$CC" "${FLAGS[@]}" -L "$CRT" -Wl,-flat_namespace "$HERE/hierarchy.m" -framework UIKit -framework Foundation "$OUT/HierarchyFallback.dylib" -o "$OUT/hierarchy"
ldid -S "$OUT/HierarchyFallback.dylib"
ldid -S "$OUT/hierarchy"
echo "Built isolated experiment: $OUT"
