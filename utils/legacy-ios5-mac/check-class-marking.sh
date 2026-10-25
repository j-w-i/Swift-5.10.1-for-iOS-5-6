#!/bin/bash
# Standalone ABI regression; needs real armv7 layout data but no stdlib modules.
# Usage: check-class-marking.sh SWIFT_FRONTEND NEW_OUT [RESOURCE_DIR]
# Build-tree frontends have no generated iphoneos layouts; pass an installed
# Swift 5.10 usr/lib/swift (or any tree containing iphoneos/layouts-armv7.yaml).
set -euo pipefail
SWIFTC=${1:?swiftc executable}; OUT=${2:?new output directory}; RESOURCE_DIR=${3:-}
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo 'Choose new output directory.' >&2; exit 1; }
[ -x "$SWIFTC" ] || exit 1
RESOURCE_ARGS=()
if [ -n "$RESOURCE_DIR" ]; then
  [[ "$RESOURCE_DIR" = /* ]] && [ -s "$RESOURCE_DIR/iphoneos/layouts-armv7.yaml" ] || {
    echo 'RESOURCE_DIR must be absolute and contain iphoneos/layouts-armv7.yaml.' >&2; exit 1; }
  RESOURCE_ARGS=(-resource-dir "$RESOURCE_DIR")
fi
mkdir "$OUT"
printf 'public class Plain {}\npublic class Generic<T> {}\n' > "$OUT/classes.swift"
for MODE in stock legacy runtime disabled; do
  FLAGS=()
  case "$MODE" in
    legacy) FLAGS=(-enable-legacy-ios5-class-marking);;
    runtime) FLAGS=(-enable-legacy-ios5-runtime);;
    disabled) FLAGS=(-enable-legacy-ios5-class-marking -disable-legacy-ios5-class-marking);;
  esac
  /usr/bin/nice -n 15 /usr/bin/arch -x86_64 "$SWIFTC" -target armv7-apple-ios7.0 \
    -parse-stdlib -parse-as-library -module-name LegacyClasses -emit-ir \
    ${RESOURCE_ARGS[@]+"${RESOURCE_ARGS[@]}"} \
    ${FLAGS[@]+"${FLAGS[@]}"} "$OUT/classes.swift" -o "$OUT/$MODE.ll"
done
# The emitted IR embeds the input filename; compare module content only.
normalize() { /usr/bin/grep -v -E '^(; ModuleID|source_filename)' "$1"; }
diff <(normalize "$OUT/stock.ll") <(normalize "$OUT/disabled.ll")
diff <(normalize "$OUT/legacy.ll") <(normalize "$OUT/runtime.ll")
python3 - "$OUT" <<'PY'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
stock = (root/'stock.ll').read_text()
legacy = (root/'legacy.ll').read_text()
def ro_flag(text, prefix, name):
    # Concrete non-generic classes own named RO globals.
    pattern = r'@'+prefix+r'[^\n]*'+name+r'[^\n]*= [^\n]*\{ i32 ' + r'(\d+)'
    return [int(x) for x in re.findall(pattern, text)]

for prefix, normal, old in (('_DATA_',128,65664),('_METACLASS_DATA_',129,65665)):
    assert ro_flag(stock, prefix, 'Plain') == [normal], (prefix, 'stock Plain')
    assert ro_flag(legacy, prefix, 'Plain') == [old], (prefix, 'legacy Plain')
# The generic class RO objects live in the copied extra-data pattern and may be
# unnamed or byte-packed; count both i32 and little-endian i8 encodings instead
# of inventing a symbol name.
def marker_hits(text, value):
    hits = len(re.findall(r'\bi32 '+str(value)+r'\b', text))
    octets = [(value >> (8 * i)) & 0xFF for i in range(4)]
    signed = [(o - 256 if o >= 128 else o) for o in octets]
    packed = ', '.join('i8 '+str(x) for x in signed)
    return hits + len(re.findall(re.escape(packed), text))

for marker in (65664, 65665):
    assert marker_hits(stock, marker) == 0, ('unexpected legacy marker in stock', marker)
    assert marker_hits(legacy, marker) >= 2, ('legacy RO marker missing', marker, marker_hits(legacy, marker))

# Two marked occurrences per flag are expected: Plain's own RO global and the
# generic class metadata template's embedded RO object. Exact IR formatting is
# not asserted, so a formatting change cannot masquerade as an ABI failure.
assert marker_hits(legacy, 65664) >= 2 and marker_hits(legacy, 65665) >= 2, 'generic template marker missing'

assert stock.count('@_DATA__TtC13LegacyClasses5Plain'), 'stock Plain RO global absent'
assert re.search(r'@_DATA_[^\n]*Plain[^\n]*\{ i32 128', stock), 'stock Plain flag changed'
assert re.search(r'@_DATA_[^\n]*Plain[^\n]*\{ i32 65664', legacy), 'legacy Plain flag missing'
assert re.search(r'@_METACLASS_DATA_[^\n]*Plain[^\n]*\{ i32 65665', legacy), 'legacy Plain metaclass flag missing'
# Every class in this fixture is either Plain or Generic; the legacy output must
# not keep Plain's stock flags. Unrelated constants are not asserted absent, so
# the generic pattern's non-RO bytes never cause a false failure.
assert stock.count('@_DATA__TtC13LegacyClasses5Plain') , 'stock Plain RO global absent'
assert re.search(r'@_DATA_[^\n]*Plain[^\n]*\{ i32 128', stock), 'stock Plain flag changed'
assert re.search(r'@_DATA_[^\n]*Plain[^\n]*\{ i32 65664', legacy), 'legacy Plain flag missing'
assert re.search(r'@_METACLASS_DATA_[^\n]*Plain[^\n]*\{ i32 65665', legacy), 'legacy Plain metaclass flag missing'
assert re.search(r'i32 add \(i32 ptrtoint \(ptr @_DATA_[^\n]*Plain[^\n]*to i32\), i32 1\)', stock), 'stock low-bit'
assert re.search(r'i32 ptrtoint \(ptr @_DATA_[^\n]*Plain[^\n]*to i32\)',legacy), 'legacy bare pointer'
assert not re.search(r'i32 add \(i32 ptrtoint \(ptr @_DATA_',legacy), 'legacy low-bit unexpectedly set'
print('PASS: stock/legacy class RO markers (including generic template), bare pointer, runtime opt-in and explicit disable')
PY
