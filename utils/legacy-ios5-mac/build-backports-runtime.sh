#!/bin/bash
# Build ObjC support and stage Swift engine/overlay sources; no network/prebuilt input.
# Usage: build-backports-runtime.sh SDK CLANG AR OUT (fresh absolute output)
# Swift sources are compiled as part of the UIKit overlay, not a client package.
set -euo pipefail
umask 022
fail() { printf 'build-backports-runtime: %s\n' "$*" >&2; exit 1; }
[ "$#" = 4 ] || fail 'Usage: build-backports-runtime.sh SDK CLANG AR OUT'
SDK=$1; CLANG=$2; AR=$3; OUT=$4
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
# Test/reproduction builds can select a small source snapshot without swapping
# files in the live checkout (for example, isolate engine changes from text work).
SRC=${LEGACY_UIKIT_SOURCE:-"$HERE/vendor/UIKitBackports"}
[[ "$SRC" = /* ]] && [ -d "$SRC/LegacyAutoLayout" ] && [ -d "$SRC/Runtime" ] || fail 'Invalid UIKit backport source root'
for path in "$SDK" "$CLANG" "$AR" "$OUT"; do [[ "$path" = /* ]] || fail "Use absolute paths: $path"; done
[ -d "$SDK" ] && [ -x "$CLANG" ] && [ -x "$AR" ] || fail 'Missing SDK/compiler/archive tool'
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || fail 'Refusing existing output'
mkdir "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)
mkdir "$OUT/objects" "$OUT/logs" "$OUT/Swift" "$OUT/Native" "$OUT/include" "$OUT/legacy-backports"
export ZERO_AR_DATE=1
"${PYTHON:-python3}" - "$SRC" "$OUT" <<'PY'
from pathlib import Path
import json, re, shutil, sys
src, out = map(Path, sys.argv[1:])
paths = []
for path in sorted((src / 'OAStackView').glob('*.m')):
    # A dynamically registered NSLayoutConstraint cannot satisfy a static weak
    # ObjC class-symbol reference already bound to nil by iOS 5 dyld.
    text = path.read_text().replace('[NSLayoutConstraint ', '[NSClassFromString(@"NSLayoutConstraint") ')
    (out / 'Native' / path.name).write_text(text)
for component in ('Cassowary', 'LegacyAutoLayout'):
    for path in sorted((src / component).glob('*.swift')):
        if path.name == 'SolverReference.swift':
            continue   # test oracle only (Tests/run-cassowary-c-diff.sh); the shipped Solver is the C-backed facade
        text = path.read_text()
        text = re.sub(r'^import (UIKit|Cassowary|LegacyAutoLayout)\s*$', '', text, flags=re.M)
        text = re.sub(r'^private typealias (Expression|Constraint|RelationalOperator) = Cassowary\.\w+\s*$', '', text, flags=re.M)
        text = text.replace('Cassowary.', '')
        destination = out / 'Swift' / (component + '-' + path.name)
        destination.write_text(text); paths.append(destination)
for path in sorted((src / 'Runtime').glob('*.swift')):
    destination = out / 'Swift' / path.name
    if path.suffix == '.swift':
        # The overlay must not depend on a C module at *client* compile time;
        # only one C entry point is used, so declare it directly. The symbol is
        # linked from the vendored runtime archive into libswiftUIKit.
        text = path.read_text()
        text = re.sub(r'^import CUIKitBackports\s*$',
                      '@_silgen_name("UICInstallConstraintClassMethods")\n'
                      'func UICInstallConstraintClassMethods()', text, flags=re.M)
        destination.write_text(text)
    else:
        shutil.copyfile(path, destination)
    paths.append(destination)
(out / 'swift-sources.txt').write_text(''.join('"' + str(path) + '"\n' for path in paths))
# Runtime declarations are consumed only while rebuilding UIKit, never required
# in client projects. Keep all headers self-contained at a stable stage path.
for component in ('Runtime', 'OAStackView'):
    for path in (src / component).glob('*.h'): shutil.copyfile(path, out / 'include' / path.name)
(out / 'include/module.modulemap').write_text('module CUIKitBackports {\n header "UIKitBackports.h"\n export *\n}\n')
for name in ('SNAPSHOT.json', 'THIRD-PARTY-NOTICES.md'):
    shutil.copyfile(src / name, out / 'legacy-backports' / name)
shutil.copytree(src / 'Licenses', out / 'legacy-backports/Licenses')
PY
OBJECTS=()
for source in "$OUT/Native/"*.m "$SRC/Runtime/"*.m; do
  name=$(basename -- "$source" .m)
  case "$name" in *Tests) continue ;; esac
  command=("$CLANG" -target armv7-apple-ios5.0 -marm -isysroot "$SDK" -O2 -g0
    -fobjc-arc -fblocks -fno-modules -fvisibility=default "-ffile-prefix-map=$HERE=utils/legacy-ios5-mac"
    "-ffile-prefix-map=$OUT=utils/legacy-ios5-mac/generated-backports" -include "$SRC/Runtime/UICObjCCompatibility.h"
    -Wunguarded-availability -Wunguarded-availability-new
    -I "$SRC/OAStackView" -I "$SRC/Runtime" -c "$source" -o "$OUT/objects/$name.o")
  (printf '%q ' "${command[@]}"; printf '\n') > "$OUT/logs/$name.command"
  if ! /usr/bin/nice -n 15 "${command[@]}" > "$OUT/logs/$name.log" 2>&1; then
    tail -50 "$OUT/logs/$name.log" >&2; fail "$name compilation failed"
  fi
  OBJECTS+=("$OUT/objects/$name.o")
done
# The C solver core: plain C (no ObjC prefix header, no ARC). -ffp-contract=off keeps every double identical to the
# host differential test (Tests/run-cassowary-c-diff.sh); ARM mode like every other backport object.
command=("$CLANG" -target armv7-apple-ios5.0 -marm -isysroot "$SDK" -O2 -g0 -ffp-contract=off -fvisibility=default
  "-ffile-prefix-map=$HERE=utils/legacy-ios5-mac" -I "$SRC/CassowaryC"
  -c "$SRC/CassowaryC/CassowaryC.c" -o "$OUT/objects/CassowaryC.o")
(printf '%q ' "${command[@]}"; printf '\n') > "$OUT/logs/CassowaryC.command"
/usr/bin/nice -n 15 "${command[@]}" > "$OUT/logs/CassowaryC.log" 2>&1 || { tail -50 "$OUT/logs/CassowaryC.log" >&2; fail 'CassowaryC compilation failed'; }
OBJECTS+=("$OUT/objects/CassowaryC.o")
# Apple's incremental-simplex engine (clean-room C port, NSISC): used when the layout solver
# backend is switched to "nsis" (LEGACY_AUTOLAYOUT_SOLVER=nsis). Kept separate from CassowaryC
# so the accepted engine remains the default and unmodified.
for source in "$SRC/NSISC/"*.c; do
  name=$(basename -- "$source" .c)
  # The legacy Swift frontend emits AAPCS soft-float argument marshalling for its C
  # declarations, so this C side must use the same convention or mixed int/float calls
  # arrive corrupted (verified on device: a -3787 probe returned 213.49).
  command=("$CLANG" -target armv7-apple-ios5.0 -marm -mfloat-abi=softfp -isysroot "$SDK" -O2 -g0 -ffp-contract=off -fvisibility=default
    "-ffile-prefix-map=$HERE=utils/legacy-ios5-mac" -I "$SRC/NSISC"
    -c "$source" -o "$OUT/objects/NSISC-$name.o")
  (printf '%q ' "${command[@]}"; printf '\n') > "$OUT/logs/NSISC-$name.command"
  /usr/bin/nice -n 15 "${command[@]}" > "$OUT/logs/NSISC-$name.log" 2>&1 || { tail -50 "$OUT/logs/NSISC-$name.log" >&2; fail "NSISC $name compilation failed"; }
  OBJECTS+=("$OUT/objects/NSISC-$name.o")
done
"${PYTHON:-python3}" - "$OUT" "${OBJECTS[@]}" <<'PY'
from pathlib import Path
import json, struct, sys
out = Path(sys.argv[1]); audited = []
for raw in sys.argv[2:]:
    path = Path(raw); data = path.read_bytes()
    magic, cpu, subtype, kind, count, size, flags = struct.unpack_from('<7I', data)
    if magic != 0xfeedface or cpu != 12 or kind != 1:
        raise SystemExit('Expected ARM32 Mach-O object: ' + str(path))
    cursor = 28; symtab = None
    for _ in range(count):
        command, length = struct.unpack_from('<2I', data, cursor)
        if command == 2: symtab = struct.unpack_from('<6I', data, cursor)[2:]
        cursor += length
    if not symtab: raise SystemExit('Missing symbol table: ' + str(path))
    offset, symbols, strings, string_size = symtab
    for index in range(symbols):
        name_index, typ, section, description, value = struct.unpack_from('<IBBHI', data, offset + index * 12)
        name = data[strings + name_index:data.index(b'\0', strings + name_index)].decode(errors='replace')
        if typ & 0xe0: continue
        if (typ & 0x0e) == 0x0e and description & 8:
            raise SystemExit('Thumb code forbidden in backport runtime: ' + name)
        if (typ & 0x0e) == 0:
            for cls in ('NSLayoutConstraint', 'UIStackView', 'UILayoutGuide', 'NSLayoutAnchor', 'NSLayoutXAxisAnchor', 'NSLayoutYAxisAnchor', 'NSLayoutDimension', 'UIRefreshControl'):
                if name in ('_OBJC_CLASS_$_' + cls, '_OBJC_METACLASS_$_' + cls):
                    raise SystemExit('Static reference to runtime-registered class: ' + name)
            if name == '__NSDictionaryOfVariableBindings':
                raise SystemExit('Absent iOS 6 C helper reference: ' + name)
    for selector in (b'objectAtIndexedSubscript:', b'objectForKeyedSubscript:', b'setObject:atIndexedSubscript:', b'setObject:forKeyedSubscript:'):
        if selector + b'\0' in data: raise SystemExit('Unsafe iOS 6 subscript selector: ' + selector.decode())
    audited.append(path.name)
(out / 'logs/object-audit.json').write_text(json.dumps({'objects': audited, 'thumbCode': False, 'staticDynamicClassReferences': False, 'iOS6Subscripts': False}, indent=2) + '\n')
print('PASS: ARM-only objects; no static dynamically registered class references, absent iOS6 helper, or Foundation subscripts')
PY
"$AR" rcs "$OUT/libswiftLegacyUIKitBackports.a" "${OBJECTS[@]}" > "$OUT/logs/archive.log" 2>&1
"${PYTHON:-python3}" - "$SRC" "$SDK" "$CLANG" "$AR" "$OUT" <<'PY'
from pathlib import Path
import hashlib, json, subprocess, sys
src, sdk, clang, ar, out = map(Path, sys.argv[1:])
hashfile = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
manifest = {'target': 'armv7-apple-ios5.0', 'instructionSet': 'ARM', 'swiftPayload': 'compiled in UIKit overlay',
            'sourceRoot': str(src.resolve()),
            'sdk': str(sdk.resolve()), 'clang': str(clang.resolve()), 'ar': str(ar.resolve()),
            'clangVersion': subprocess.check_output([str(clang), '--version'], text=True),
            'sourceSHA256': {str(p.relative_to(src)): hashfile(p) for p in sorted(src.rglob('*')) if p.is_file()},
            'archiveSHA256': hashfile(out / 'libswiftLegacyUIKitBackports.a'),
            'qualification': 'Compile evidence only; requires Swift overlay link and device qualification'}
(out / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
printf 'Built ObjC runtime archive and staged UIKit Swift sources: %s\n' "$OUT"
