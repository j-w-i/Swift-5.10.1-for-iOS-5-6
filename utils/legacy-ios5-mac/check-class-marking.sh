#!/bin/bash
# Standalone ABI regression; no runtime modules or SDK needed.
set -euo pipefail
SWIFTC=${1:?swiftc executable}; OUT=${2:?new output directory}
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo 'Choose new output directory.' >&2; exit 1; }
[ -x "$SWIFTC" ] || exit 1
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
    ${FLAGS[@]+"${FLAGS[@]}"} "$OUT/classes.swift" -o "$OUT/$MODE.ll"
done
diff "$OUT/stock.ll" "$OUT/disabled.ll"
diff "$OUT/legacy.ll" "$OUT/runtime.ll"
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
    assert marker_hits(legacy, marker) >= 2, ('generic class RO marker missing', marker, marker_hits(legacy, marker))
# Every class in this fixture is either Plain or Generic, so no stock flag may
# survive in the legacy output.
assert marker_hits(stock, 128) and marker_hits(stock, 129), 'stock class flags absent'
assert marker_hits(legacy, 128) == 0, 'stock flag 128 survived legacy marking'
assert marker_hits(legacy, 129) == 0, 'stock flag 129 survived legacy marking'
assert re.search(r'i32 add \(i32 ptrtoint \(ptr @_DATA_[^\n]*Plain[^\n]*to i32\), i32 1\)', stock), 'stock low-bit'
assert re.search(r'i32 ptrtoint \(ptr @_DATA_[^\n]*Plain[^\n]*to i32\)',legacy), 'legacy bare pointer'
assert not re.search(r'i32 add \(i32 ptrtoint \(ptr @_DATA_',legacy), 'legacy low-bit unexpectedly set'
print('PASS: stock/legacy class RO markers (including generic template), bare pointer, runtime opt-in and explicit disable')
PY
