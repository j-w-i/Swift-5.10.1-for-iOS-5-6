#!/bin/bash
# Build-only metadata experiment; never launches a GUI or installs/changes system files.
# Usage: build-swift.sh SDK CLANG CRT_DIR NEW_OUT FRONTEND RESOURCE_DIR COMPAT_DIR STDLIB_DIR
# RESOURCE_DIR is the legacy swift_ios5 tree; COMPAT_DIR contains legacy compatibility .a files;
# STDLIB_DIR supplies the remaining autolink libraries. These are explicit to avoid host-SDK fallbacks.
set -euo pipefail
SDK=${1:?SDK}; CC=${2:?clang}; CRT=${3:?crt directory}; OUT=${4:?new output}
FE=${5:?legacy swift-frontend}; RES=${6:?resource directory}; COMPAT=${7:?compatibility archives}; STDLIB=${8:?stdlib autolink directory}
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
bash "$HERE/build.sh" "$SDK" "$CC" "$CRT" "$OUT"
"$FE" -frontend -c -parse-as-library -suppress-warnings -module-name SwiftRouteProbe \
  -target armv7-apple-ios5.0 -sdk "$SDK" -resource-dir "$RES" -enable-legacy-ios5-runtime \
  -module-cache-path "$OUT/swift-cache" -import-objc-header "$HERE/swift-types.h" \
  "$HERE/swift-probe.swift" -o "$OUT/swift-probe.o"
"$CC" -target armv7-apple-ios5.0 -marm -isysroot "$SDK" -fobjc-arc -L "$CRT" -Wl,-flat_namespace \
  "$HERE/swift-driver.m" "$OUT/swift-probe.o" -framework UIKit -framework Foundation \
  "$OUT/HierarchyFallback.dylib" -L "$RES/iphoneos" -L "$COMPAT" -L "$STDLIB" \
  -lswiftCore -lswiftFoundation -lswiftObjectiveC -lswiftUIKit -lswiftDarwin -lswiftDispatch \
  -lswiftCoreFoundation -lswiftCoreGraphics -lswiftCoreImage -lswiftQuartzCore -lswiftMetal \
  -Wl,-rpath,@executable_path/Frameworks -o "$OUT/swift-probe"
# Stage the exact armv7 dependency closure from the selected legacy runtime, not from Xcode.
python3 - "$OUT" "$RES/iphoneos" <<'PY'
import pathlib,re,shutil,subprocess,sys
out,src=map(pathlib.Path,sys.argv[1:]); dest=out/'Frameworks';dest.mkdir()
pending=[out/'swift-probe'];seen=set()
while pending:
    binary=pending.pop()
    deps=subprocess.check_output(['otool','-arch','armv7','-L',str(binary)],text=True)
    for name in re.findall(r'@rpath/(libswift[^\s/]+\.dylib)',deps):
        if name in seen:continue
        seen.add(name); original=src/name
        if not original.is_file():raise SystemExit('Missing legacy runtime dependency: '+str(original))
        target=dest/name
        archs=subprocess.check_output(['lipo','-archs',str(original)],text=True).split()
        if len(archs)>1:subprocess.run(['lipo',str(original),'-thin','armv7','-output',str(target)],check=True)
        else:shutil.copy2(original,target)
        subprocess.run(['ldid','-S',str(target)],check=True);pending.append(target)
PY
ldid -S "$OUT/swift-probe"
otool -L "$OUT/swift-probe" > "$OUT/swift-dependencies.txt"
echo "Built Swift metadata probe with private runtime dependencies: $OUT"
