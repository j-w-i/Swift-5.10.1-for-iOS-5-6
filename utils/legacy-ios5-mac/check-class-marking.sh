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
# unnamed; require an increased marked count rather than inventing a name.
for marker in (65664, 65665):
    stock_hits = len(re.findall(r'\bi32 '+str(marker)+r'\b', stock))
    legacy_hits = len(re.findall(r'\bi32 '+str(marker)+r'\b', legacy))
    assert stock_hits == 0, ('unexpected legacy marker in stock', marker)
    assert legacy_hits >= 2, ('generic class RO marker missing', marker, legacy_hits)
assert re.search(r'i32 add \(i32 ptrtoint \(ptr @_DATA_[^\n]*Plain[^\n]*to i32\), i32 1\)', stock), 'stock low-bit'
assert re.search(r'i32 ptrtoint \(ptr @_DATA_[^\n]*Plain[^\n]*to i32\)',legacy), 'legacy bare pointer'
assert not re.search(r'i32 add \(i32 ptrtoint \(ptr @_DATA_',legacy), 'legacy low-bit unexpectedly set'
print('PASS: stock/legacy class RO markers (including generic template), bare pointer, runtime opt-in and explicit disable')
PY
