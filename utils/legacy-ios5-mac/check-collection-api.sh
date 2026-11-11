#!/bin/bash
# Verify compiler-native UIKit collection APIs, serialization and runtime linkage.
# No bridging header, PST import, package, collection include path or archive flag.
# Usage: check-collection-api.sh TOOLCHAIN SDK NEW_OUTPUT
set -euo pipefail
TC=${1:?toolchain}; SDK=${2:?SDK}; OUT=${3:?new output directory}
[[ "$TC" = /* && "$SDK" = /* && "$OUT" = /* ]] || { echo 'Use absolute paths.' >&2; exit 64; }
[ ! -e "$OUT" ] || { echo "Refusing to overwrite $OUT" >&2; exit 1; }
RES="$TC/usr/lib/swift_ios5"
[ -x "$TC/usr/bin/swiftc" ] && [ -d "$SDK" ] && [ -d "$RES" ] || exit 1
mkdir -p "$OUT"
report_failure() {
  local status=$?
  /usr/bin/python3 - "$OUT" <<'PY'
from pathlib import Path
import sys
for path in sorted(Path(sys.argv[1]).glob('ios*/build.log')):
    print(str(path) + ':', file=sys.stderr)
    lines = path.read_bytes().replace(b'\0', b'').decode('utf-8', errors='replace').splitlines()
    print('\n'.join(lines[-30:]), file=sys.stderr)
PY
  exit "$status"
}
trap report_failure ERR
COMMON=(-sdk "$SDK" -resource-dir "$RES" -enable-legacy-ios5-runtime
  -Xcc -I"$RES/legacy-overlay-shims" -module-cache-path "$OUT/module-cache"
  -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements
  -Xfrontend -disable-autolink-library -Xfrontend swiftFileProvider)
cat > "$OUT/CollectionClient.swift" <<'SWIFT'
import UIKit

open class CompilerCollectionCell: UICollectionViewCell {}
public class CompilerCollectionController: UICollectionViewController {}
public final class CompilerCollectionSource: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    public func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { 1 }
    public func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        return collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
    }
}
@MainActor public func makeCollectionView() -> UICollectionView {
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
    view.register(CompilerCollectionCell.self, forCellWithReuseIdentifier: "cell")
    view.register(UICollectionReusableView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "header")
    let _: [UICollectionViewCell] = view.visibleCells
    view.scrollToItem(at: IndexPath(item: 0, section: 0), at: .centeredHorizontally, animated: false)
    return view
}
SWIFT
cat > "$OUT/Consumer.swift" <<'SWIFT'
import UIKit
import CollectionClient
public final class DownstreamCell: CompilerCollectionCell {}
@MainActor public func consume(_ view: UICollectionView) {
    let sameType: UICollectionView = makeCollectionView()
    sameType.reloadData()
    view.reloadData()
}
SWIFT
for MIN in 5.0 6.0; do
  mkdir -p "$OUT/ios$MIN"
  "$TC/usr/bin/swiftc" "${COMMON[@]}" -target "armv7-apple-ios$MIN" -parse-as-library \
    -module-name CollectionClient -emit-module -emit-module-path "$OUT/ios$MIN/CollectionClient.swiftmodule" \
    -emit-object "$OUT/CollectionClient.swift" -o "$OUT/ios$MIN/CollectionClient.o" \
    > "$OUT/ios$MIN/build.log" 2>&1
  "$TC/usr/bin/swiftc" "${COMMON[@]}" -target "armv7-apple-ios$MIN" -parse-as-library \
    -I "$OUT/ios$MIN" -emit-object "$OUT/Consumer.swift" -o "$OUT/ios$MIN/Consumer.o" \
    >> "$OUT/ios$MIN/build.log" 2>&1
  /usr/bin/nm -u "$OUT/ios$MIN/CollectionClient.o" > "$OUT/ios$MIN/references.txt"
done
cat > "$OUT/main.swift" <<'SWIFT'
import CollectionClient
@main struct CollectionProbe {
    @MainActor static func main() { print(makeCollectionView()) }
}
SWIFT
"$TC/usr/bin/swiftc" "${COMMON[@]}" -target armv7-apple-ios5.0 -I "$OUT/ios5.0" \
  -parse-as-library -emit-object "$OUT/main.swift" -o "$OUT/ios5.0/main.o" >> "$OUT/ios5.0/build.log" 2>&1
# Link exactly as the existing iOS5 qualification app does. No collection-specific
# library switch: object autolinking selects the toolchain's UIKit overlay.
"$TC/usr/bin/clang" -target armv7-apple-ios5.0 -isysroot "$SDK" \
  -nostartfiles -Wl,-no_new_main -L "$RES/iphoneos" \
  "$OUT/ios5.0/main.o" "$OUT/ios5.0/CollectionClient.o" "$OUT/ios5.0/Consumer.o" \
  "$RES/iphoneos/crt1.3.1.o" "$RES/iphoneos/libswiftLegacyIOS5Backports.a" \
  -lobjc -lSystem -Wl,-rpath,@executable_path/Frameworks -o "$OUT/ios5.0/App" \
  >> "$OUT/ios5.0/build.log" 2>&1
/usr/bin/otool -L "$OUT/ios5.0/App" > "$OUT/ios5.0/dependencies.txt"
/usr/bin/python3 - "$OUT" "$RES/iphoneos/libswiftUIKit.dylib" <<'PY'
from pathlib import Path
import subprocess, sys
out, runtime = Path(sys.argv[1]), Path(sys.argv[2])
legacy = (out / 'ios5.0/references.txt').read_text()
native = (out / 'ios6.0/references.txt').read_text()
for name in ('PSTCollectionView', 'PSTCollectionViewCell', 'PSTCollectionViewController', 'PSTCollectionViewFlowLayout'):
    if '_OBJC_CLASS_$_' + name not in legacy:
        raise SystemExit('iOS5 did not use toolchain class: ' + name)
if 'PSUICollection' in native or 'PSTCollection' in native:
    raise SystemExit('iOS6 incorrectly uses legacy collection implementation')
if '_OBJC_CLASS_$_UICollectionView' not in native:
    raise SystemExit('iOS6 did not use native UIKit')
# The runtime is fat (armv7 + armv7s + arm64); nm with no -arch defaults to the host slice,
# so the armv7 slice must be named explicitly to audit the legacy collection support.
symbols = subprocess.check_output(['/usr/bin/nm', '-arch', 'armv7', '-gU', str(runtime)], text=True)
for name in ('PSTCollectionView', 'PSTCollectionViewCell', 'PSTCollectionReusableView',
             'PSTCollectionViewLayout', 'PSTCollectionViewFlowLayout',
             'PSTCollectionViewLayoutAttributes', 'PSTCollectionViewController',
             'PSTCollectionViewUpdateItem', 'PSTCollectionViewLayoutInvalidationContext',
             'PSTCollectionViewFlowLayoutInvalidationContext'):
    if '_OBJC_CLASS_$_' + name not in symbols:
        raise SystemExit('UIKit runtime does not contain collection support: ' + name)
print('PASS: UIKit collection API, downstream modules, iOS5 runtime definitions and native iOS6 references')
PY
