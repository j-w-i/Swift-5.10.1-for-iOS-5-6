#!/bin/bash
# Compile only this runtime twice; check deterministic archive and ObjC exports.
# Usage: test-collection-runtime.sh SDK CLANG AR NM OUT (fresh OUT; parent exists)
set -euo pipefail
[ "$#" = 5 ] || { echo 'Usage: test-collection-runtime.sh SDK CLANG AR NM OUT' >&2; exit 64; }
SDK=$1; CLANG=$2; AR=$3; NM=$4; OUT=$5
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[[ "$OUT" = /* && "$NM" = /* ]] && [ -x "$NM" ] || exit 64
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo 'Output exists; refusing reuse.' >&2; exit 1; }
mkdir "$OUT"
for n in one two; do
  bash "$HERE/build-collection-runtime.sh" "$SDK" "$CLANG" "$AR" "$OUT/$n"
done
cmp "$OUT/one/libswiftLegacyCollectionView.a" "$OUT/two/libswiftLegacyCollectionView.a"
cmp "$OUT/one/legacy-collection/Headers/UIKitLegacyCollection.h" "$OUT/two/legacy-collection/Headers/UIKitLegacyCollection.h"
"$NM" -g "$OUT/one/libswiftLegacyCollectionView.a" > "$OUT/symbols.txt"
"${PYTHON:-python3}" - "$OUT" <<'PY'
from pathlib import Path
import re, sys
out = Path(sys.argv[1]); symbols = (out / 'symbols.txt').read_text()
for name in ('UICollectionView', 'UICollectionViewCell', 'UICollectionReusableView',
             'UICollectionViewLayout', 'UICollectionViewFlowLayout',
             'UICollectionViewLayoutAttributes', 'UICollectionViewController',
             'UICollectionViewUpdateItem'):
    for prefix in ('_OBJC_CLASS_$_', '_OBJC_METACLASS_$_'):
        symbol = prefix + name.replace('UICollection', 'PSTCollection')
        assert re.search(r'^[0-9a-fA-F]+ [A-Z] ' + re.escape(symbol) + r'$', symbols, re.M), symbol
    assert not re.search(r' [A-Z] _OBJC_CLASS_\$_' + re.escape(name) + r'$', symbols, re.M), name
for path in (out / 'one/objects').glob('*.o'):
    data = path.read_bytes()
    for selector in (b'objectAtIndexedSubscript:', b'objectForKeyedSubscript:',
                     b'setObject:atIndexedSubscript:', b'setObject:forKeyedSubscript:'):
        assert selector + b'\0' not in data, (path.name, selector)
assert '_objc_storeWeak' not in symbols
assert '_class_setSuperclass' not in symbols
print('PASS: deterministic archives, all eight PST class/metaclass exports, no native UI class exports, no iOS6 subscript/weak or superclass-mutation references')
PY
# Exercise declarations in the real SDK's textual UIKit include graph, without
# touching SDK files or needing a rebuilt Swift compiler. Include early because
# later SDK headers (e.g. UIDiffableDataSource) depend on the collection types.
"${PYTHON:-python3}" - "$SDK" "$OUT" <<'PY'
import json
from pathlib import Path
import sys
sdk, out = map(Path, sys.argv[1:])
headers = sdk / 'System/Library/Frameworks/UIKit.framework/Headers'
replacement = out / 'collection-replacement.h'
replacement.write_text('#include "' + str(out / 'one/legacy-collection/Headers/UIKitLegacyCollection.h') + '"\n')
roots = [{'type': 'file', 'name': str(p), 'external-contents': str(replacement)}
         for p in sorted(headers.iterdir()) if p.name in (
             'UICollectionView.h', 'UICollectionViewCell.h', 'UICollectionViewController.h',
             'UICollectionViewLayout.h', 'UICollectionViewFlowLayout.h', 'UICollectionViewUpdateItem.h')]
assert roots, 'SDK has no UICollectionView headers'
(out / 'overlay.json').write_text(json.dumps({'version': 0, 'roots': roots}))
(out / 'declarations.m').write_text('''#import <UIKit/UIKit.h>
@interface Cell : UICollectionViewCell @end
@implementation Cell @end
UICollectionView *create(UICollectionViewLayout *layout) {
    return [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
}
NSString *headerKind(void) { return UICollectionElementKindSectionHeader; }
UICollectionElementCategory category(UICollectionViewLayoutAttributes *attrs) {
    return attrs.representedElementCategory;
}
''')
PY
"$CLANG" -target armv7-apple-ios5.0 -isysroot "$SDK" -fobjc-arc -fblocks -fno-modules \
  -ivfsoverlay "$OUT/overlay.json" -c "$OUT/declarations.m" -o "$OUT/declarations.o" \
  > "$OUT/declarations.log" 2>&1
"$NM" -u "$OUT/declarations.o" > "$OUT/declaration-symbols.txt"
"${PYTHON:-python3}" - "$OUT/declaration-symbols.txt" <<'PY'
from pathlib import Path
import sys
symbols = Path(sys.argv[1]).read_text()
for name in ('_OBJC_CLASS_$_PSTCollectionView', '_OBJC_CLASS_$_PSTCollectionViewCell',
             '_OBJC_METACLASS_$_PSTCollectionViewCell', '_PSTCollectionElementKindSectionHeader'):
    assert name in symbols, name
assert '_OBJC_CLASS_$_UICollectionView' not in symbols
print('PASS: fallback UIKit spelling emits linkable PST class/metaclass and C constant references')
PY
# Inspect the *linked* image, not just nm's Thumb symbol annotations or .o
# relocations. Old armv7 dyld calls raw __mod_init_func pointers and needs bit0
# to agree with N_ARM_THUMB_DEF. A correct symbol alone does not prove this.
"${PYTHON:-python3}" "$HERE/check-macho-initializers.py" --self-test > "$OUT/initializer-audit-self-test.log" 2>&1
# Minimal source-runtime-only link reproduces the final relocation step without
# rebuilding overlays or touching installed toolchains. No undefined suppression.
"$CLANG" -target armv7-apple-ios5.0 -isysroot "$SDK" -dynamiclib \
  -Xlinker -force_load -Xlinker "$OUT/one/libswiftLegacyCollectionView.a" \
  -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
  -lobjc -lSystem -Xlinker -install_name -Xlinker @rpath/libPSTInitializerProbe.dylib \
  -o "$OUT/libPSTInitializerProbe.dylib" > "$OUT/initializer-link.log" 2>&1
"${PYTHON:-python3}" "$HERE/check-macho-initializers.py" "$OUT/libPSTInitializerProbe.dylib" \
  > "$OUT/initializer-audit.log" 2>&1 || { cat "$OUT/initializer-audit.log" >&2; exit 1; }
if [ -n "${COLLECTION_LINKED_DYLIB:-}" ]; then
  "${PYTHON:-python3}" "$HERE/check-macho-initializers.py" "$COLLECTION_LINKED_DYLIB" \
    > "$OUT/integrated-initializer-audit.log" 2>&1 || { cat "$OUT/integrated-initializer-audit.log" >&2; exit 1; }
fi
echo 'PASS: linked runtime initializer pointer audit'
# Reusing output must fail rather than silently accepting stale objects.
if bash "$HERE/build-collection-runtime.sh" "$SDK" "$CLANG" "$AR" "$OUT/one" > "$OUT/reuse.log" 2>&1; then
  echo 'FAIL: runtime builder accepted stale output' >&2; exit 1
fi
