#!/bin/bash
# Compile the compositional-layout runtime twice, prove the archive, mapping and
# manifests are deterministic, audit every mapped symbol and the class hierarchy,
# and (with CRT_ARCHIVE and PST_ARCHIVE set) link the integrated UIKit probe and
# run the image-level initializer/Thumb-pointer audits.
#
# Usage: test-compositional-layout.sh SDK CLANG AR NM OUT
# OUT must not exist; its parent must exist. Set CRT_ARCHIVE (toolchain
# compiler-rt builtins for armv7 iOS 5) and PST_ARCHIVE
# (.../libswiftLegacyCollectionView.a) to enable the link probe.
set -euo pipefail
[ "$#" = 5 ] || { echo 'Usage: test-compositional-layout.sh SDK CLANG AR NM OUT' >&2; exit 64; }
SDK=$1; CLANG=$2; AR=$3; NM=$4; OUT=$5
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
PY=${PYTHON:-python3}
OTOOL=${OTOOL:-/usr/bin/otool}
for path in "$SDK" "$CLANG" "$AR" "$NM" "$OUT"; do
  [[ "$path" = /* ]] || { echo "Use absolute paths: $path" >&2; exit 64; }
done
[ -d "$SDK" ] && [ -x "$CLANG" ] && [ -x "$AR" ] && [ -x "$NM" ] && [ -x "$OTOOL" ] || exit 64
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo "Output exists; refusing reuse: $OUT" >&2; exit 1; }
mkdir "$OUT"

# 1. Two independent builds must be byte-identical, including the generated
#    mapping contract and the hash manifest.
bash "$HERE/build-compositional-layout.sh" "$SDK" "$CLANG" "$AR" "$OUT/one" > "$OUT/build-one.log" 2>&1
bash "$HERE/build-compositional-layout.sh" "$SDK" "$CLANG" "$AR" "$OUT/two" > "$OUT/build-two.log" 2>&1
cmp "$OUT/one/libswiftLegacyCompositionalLayout.a" "$OUT/two/libswiftLegacyCompositionalLayout.a"
cmp "$OUT/one/legacy-compositional-layout/compositional-layout-mapping.json" \
  "$OUT/two/legacy-compositional-layout/compositional-layout-mapping.json"
cmp "$OUT/one/build-manifest.json" "$OUT/two/build-manifest.json"
echo 'PASS: deterministic archive, mapping contract and build manifest'

ARCHIVE="$OUT/one/libswiftLegacyCompositionalLayout.a"
MAPPING="$OUT/one/legacy-compositional-layout/compositional-layout-mapping.json"
"$NM" -g "$ARCHIVE" > "$OUT/symbols.txt"
"$NM" -m "$ARCHIVE" > "$OUT/symbols-m.txt"

# 2. Every mapping entry exists, no public-named class is defined, no native
#    collection/compositional class is referenced at all, no superclass mutation.
"$PY" - "$MAPPING" "$OUT/symbols.txt" "$OUT/symbols-m.txt" <<'PY'
import json, re, sys
mapping = json.load(open(sys.argv[1]))
symbols = open(sys.argv[2]).read()
detailed = open(sys.argv[3]).read()
defined = set(re.findall(r'^[0-9a-fA-F]+ [A-Z] (\S+)$', symbols, re.M))

for entry in mapping['classes']:
    for prefix in ('_OBJC_CLASS_$_', '_OBJC_METACLASS_$_'):
        symbol = prefix + entry['runtime']
        assert symbol in defined, 'missing mapped symbol ' + symbol
for entry in mapping['protocols']:
    symbol = '__OBJC_PROTOCOL_$_' + entry['runtime']
    assert symbol in defined, 'missing protocol object ' + symbol
for entry in mapping['cSymbols']:
    assert '_' + entry['runtime'] in defined, 'missing C symbol ' + entry['runtime']

# Nothing in this archive may define (hence replace) a native UIKit class, and
# nothing may reference one: every collection object must stay in the PST graph.
for name in defined:
    if name.startswith('_OBJC_CLASS_$_'):
        runtime = name[len('_OBJC_CLASS_$_'):]
        assert runtime.startswith('IBP'), 'non-prefixed class defined: ' + runtime
native = ('UICollectionView', 'NSCollectionLayout', 'UICollectionLayout', 'UITraitCollection')
for name in re.findall(r'_OBJC_CLASS_\$_\w+', detailed):
    assert not name.startswith('_OBJC_CLASS_$_' + 'UICollectionView'), name
    assert not name.startswith('_OBJC_CLASS_$_' + 'NSCollectionLayout'), name
    assert not name.startswith('_OBJC_CLASS_$_' + 'UICollectionLayout'), name
    assert name != '_OBJC_CLASS_$_UITraitCollection', name
for required in ('_OBJC_CLASS_$_PSTCollectionView', '_OBJC_CLASS_$_PSTCollectionViewLayout',
                 '_OBJC_CLASS_$_PSTCollectionViewLayoutAttributes'):
    assert required in detailed, 'archive does not reference the PST runtime: ' + required
assert 'class_setSuperclass' not in detailed, 'runtime mutates class hierarchies'
assert 'objc_allocateClassPair' not in detailed, 'runtime synthesises classes'

# The capability filter is part of the contract; gating consumes it verbatim.
unimplemented = ' | '.join(entry['member'] for entry in mapping['unimplemented'])
for required in ('traitCollection', 'visibleItemsInvalidationHandler', 'visualDescription'):
    assert required in unimplemented, 'capability filter lost ' + required
assert mapping['nativeDelegation'].startswith('disabled'), 'native delegation not disabled'
print('PASS: %d classes, %d protocols, %d C symbols exported; no public-named class; '
      'no native compositional reference; PST runtime referenced'
      % (len(mapping['classes']), len(mapping['protocols']), len(mapping['cSymbols'])))
PY

# 3. Every object is ARM code (the pinned linker loses interworking bits on local
#    Thumb relocations, so ARM mode is the primary guarantee; the linked-image
#    audit below is the second line of defence).
"$PY" - "$OTOOL" "$NM" "$OUT/one/objects" <<'PY'
import pathlib, subprocess, sys
otool, nm, objects = sys.argv[1], sys.argv[2], pathlib.Path(sys.argv[3])
count = 0
for obj in sorted(objects.glob('*.o')):
    header = subprocess.check_output([otool, '-hv', str(obj)], text=True).splitlines()
    fields = next(line.split() for line in header if 'MH_MAGIC' in line)
    assert fields[1] == 'ARM' and fields[2].startswith('V7'), 'object is not ARMv7: %s' % obj.name
    detailed = subprocess.check_output([nm, '-m', str(obj)], text=True)
    assert '[Thumb]' not in detailed, 'Thumb code in %s' % obj.name
    count += 1
assert count > 0
print('PASS: %d object files are ARMv7 with no Thumb code' % count)
PY

# 4. Reusing an output must fail rather than silently accepting stale objects.
if bash "$HERE/build-compositional-layout.sh" "$SDK" "$CLANG" "$AR" "$OUT/one" > "$OUT/reuse.log" 2>&1; then
  echo 'FAIL: builder accepted a stale output directory' >&2; exit 1
fi

# 5. Integrated link probe: this is the link the pipeline performs for a 5.x
#    deployment target (PST archive + compositional archive + compiler-rt
#    builtins force-loaded into libswiftUIKit), so verify the image metadata.
if [ -z "${CRT_ARCHIVE:-}" ] || [ -z "${PST_ARCHIVE:-}" ]; then
  echo 'SKIP: integrated link probe needs CRT_ARCHIVE and PST_ARCHIVE (runtime qualification still pending either way)'
else
  [[ "$CRT_ARCHIVE" = /* && "$PST_ARCHIVE" = /* ]] || { echo 'Use absolute CRT_ARCHIVE/PST_ARCHIVE' >&2; exit 64; }
  [ -s "$CRT_ARCHIVE" ] && [ -s "$PST_ARCHIVE" ] || { echo 'Missing probe archives' >&2; exit 64; }
  "$CLANG" -target armv7-apple-ios5.0 -isysroot "$SDK" -dynamiclib \
    -Xlinker -force_load -Xlinker "$PST_ARCHIVE" \
    -Xlinker -force_load -Xlinker "$ARCHIVE" \
    -Xlinker -force_load -Xlinker "$CRT_ARCHIVE" \
    -framework UIKit -framework Foundation -framework QuartzCore -framework CoreGraphics \
    -lobjc -lSystem -Xlinker -install_name -Xlinker @rpath/libCompositionalProbe.dylib \
    -o "$OUT/libCompositionalProbe.dylib" > "$OUT/probe-link.log" 2>&1 \
    || { tail -20 "$OUT/probe-link.log" >&2; exit 1; }
  "$OTOOL" -oV "$OUT/libCompositionalProbe.dylib" > "$OUT/probe-classes.txt"
  "$NM" -gU "$OUT/libCompositionalProbe.dylib" > "$OUT/probe-symbols.txt"
  "$NM" "$OUT/libCompositionalProbe.dylib" > "$OUT/probe-all-symbols.txt"
  "$PY" - "$MAPPING" "$OUT/probe-classes.txt" "$OUT/probe-symbols.txt" "$OUT/probe-all-symbols.txt" <<'PY'
import json, re, sys
mapping = json.load(open(sys.argv[1]))
image = open(sys.argv[2]).read()
exports = open(sys.argv[3]).read()
all_symbols = open(sys.argv[4]).read()
# Map class symbol -> superclass from otool's ObjC class listing.
superclasses = {}
current = None
for line in image.splitlines():
    match = re.match(r'^[0-9a-f]+ 0x[0-9a-f]+ _OBJC_CLASS_\$_(\w+)$', line)
    if match:
        current = match.group(1)
        continue
    match = re.match(r'^    superclass 0x[0-9a-f]+ _OBJC_CLASS_\$_(\w+)$', line)
    if match and current:
        superclasses[current] = match.group(1)
for entry in mapping['classes']:
    runtime = entry['runtime']
    assert runtime in superclasses, 'class missing from linked image: ' + runtime
    assert superclasses[runtime] == entry['runtimeSuperclass'], (
        '%s superclass is %s, expected %s'
        % (runtime, superclasses[runtime], entry['runtimeSuperclass']))
    for prefix in ('_OBJC_CLASS_$_', '_OBJC_METACLASS_$_'):
        assert prefix + runtime in exports, 'class identity not exported: ' + runtime
# ld64 makes ObjC protocol metadata local in a dylib (the PST protocols already
# behave this way); the identity must be present and registered in the image, not
# necessarily exported.
for entry in mapping['protocols']:
    symbol = '__OBJC_PROTOCOL_$_' + entry['runtime']
    assert symbol in all_symbols, 'protocol object missing from linked image: ' + symbol
for name in re.findall(r'_OBJC_CLASS_\$_(\w+)', exports):
    assert not name.startswith(('UICollectionView', 'NSCollectionLayout', 'UICollectionLayout')), (
        'linked image exports a native-named class: ' + name)
print('PASS: linked image preserves the %d-class inheritance graph and exports every mapped identity'
      % len(mapping['classes']))
PY
  "$PY" "$HERE/check-macho-initializers.py" "$OUT/libCompositionalProbe.dylib" > "$OUT/initializer-audit.log" 2>&1 \
    || { cat "$OUT/initializer-audit.log" >&2; exit 1; }
  "$PY" "$HERE/check-thumb-pointers.py" "$OUT/libCompositionalProbe.dylib" > "$OUT/thumb-audit.log" 2>&1 \
    || { cat "$OUT/thumb-audit.log" >&2; exit 1; }
  echo 'PASS: linked runtime initializer and Thumb-pointer audits'
fi
echo 'PASS: compositional-layout runtime tests (static evidence only; device execution remains pending)'
