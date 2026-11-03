#!/bin/bash
# Host differential only, not device qualification. No download/install steps.
# Usage: MACOS_SDK CLANG SWIFTC NEW_OUT
# Optional HOST_TARGET (default x86_64-apple-macosx11.0), PYTHON,
# CANONICAL_SWIFT_ROOT; ALLOW_NATIVE_DIFFERENCES=1 acknowledges newer-host drift.
set -euo pipefail
[ "$#" = 4 ] || { echo 'Usage: MACOS_SDK CLANG SWIFTC NEW_OUT' >&2; exit 1; }
SDK=$1; CLANG=$2; SWIFTC=$3; OUT=$4
SRC=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
for p in "$SDK" "$CLANG" "$SWIFTC" "$OUT"; do [[ "$p" = /* ]] || exit 1; done
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo 'Output must be new' >&2; exit 1; }
mkdir -p "$OUT/logs" "$OUT/cache" "$OUT/tmp"
export TMPDIR="$OUT/tmp" CLANG_MODULE_CACHE_PATH="$OUT/cache"
TARGET=${HOST_TARGET:-x86_64-apple-macosx11.0}
run() {
  local name=$1; shift
  (printf '%q ' "$@"; printf '\n') > "$OUT/logs/$name.command"
  if ! "$@" > "$OUT/logs/$name.log" 2>&1; then
    tail -60 "$OUT/logs/$name.log" >&2; exit 1
  fi
}
"$SWIFTC" --version > "$OUT/swift-version.txt"
/usr/bin/sw_vers > "$OUT/os-version.txt"
mkdir "$OUT/canonical"
ROOT=${CANONICAL_SWIFT_ROOT:-$(CDPATH= cd -- "$SRC/../../.." && pwd -P)}
"${PYTHON:-python3}" "$SRC/tests/extract-canonical-reference.py" "$ROOT" "$OUT/canonical"
run runtime-version "$CLANG" -target "$TARGET" -isysroot "$SDK" \
  "$SRC/tests/RuntimeVersion.c" "-L$SDK/usr/lib/swift" -lswiftCore -o "$OUT/runtime-version"
"$OUT/runtime-version" > "$OUT/loaded-runtime-version.txt"
run canonical-cxx "$CLANG" -target "$TARGET" -isysroot "$SDK" -std=c++11 -stdlib=libc++ \
  -O2 -g0 -fno-exceptions -fno-rtti -c "$OUT/canonical/CanonicalReference.cpp" \
  -o "$OUT/canonical/CanonicalReference.o"
run cxx "$CLANG" -target "$TARGET" -isysroot "$SDK" -std=c++11 -stdlib=libc++ \
  -O2 -g0 -fno-exceptions -fno-rtti -fvisibility=hidden \
  "-ffile-prefix-map=$SRC=native-numeric-runtime" \
  -c "$SRC/NumericParsing.cpp" -o "$OUT/NumericParsing.o"
for opt in Onone O; do
  flags=("-$opt" -parse-as-library -target "$TARGET" -sdk "$SDK"
    -module-cache-path "$OUT/cache" -runtime-compatibility-version none)
  run "reference-$opt" "$SWIFTC" "${flags[@]}" -D NATIVE_NUMERIC_REFERENCE \
    "$SRC/tests/Semantics.swift" -o "$OUT/reference-$opt"
  run "canonical-$opt" "$SWIFTC" "${flags[@]}" -D NATIVE_NUMERIC_CANONICAL_REFERENCE \
    -I "$OUT/canonical" "$OUT/canonical/CanonicalReference.swift" "$SRC/tests/Semantics.swift" \
    "$OUT/canonical/CanonicalReference.o" -o "$OUT/canonical-$opt"
  "$OUT/canonical-$opt" > "$OUT/canonical-$opt.txt"
  run "backport-$opt" "$SWIFTC" "${flags[@]}" -D NATIVE_NUMERIC_RUNTIME_TESTING \
    -I "$SRC/private" "$SRC/NativeNumeric.swift" "$SRC/tests/Semantics.swift" \
    "$OUT/NumericParsing.o" -o "$OUT/backport-$opt"
  DYLD_PRINT_LIBRARIES=1 "$OUT/reference-$opt" > "$OUT/reference-$opt.txt" 2> "$OUT/reference-$opt-runtime.txt"
  DYLD_PRINT_LIBRARIES=1 "$OUT/backport-$opt" > "$OUT/backport-$opt.txt" 2> "$OUT/backport-$opt-runtime.txt"
  /usr/bin/otool -L "$OUT/reference-$opt" > "$OUT/reference-$opt-libraries.txt"
done
"${PYTHON:-python3}" - "$OUT" <<'PY'
import os,pathlib,sys
out=pathlib.Path(sys.argv[1])
base=(out/'backport-Onone.txt').read_text().splitlines()
summary=[]
failed=False
for opt in ('Onone','O'):
    actual=(out/f'backport-{opt}.txt').read_text().splitlines()
    reference=(out/f'reference-{opt}.txt').read_text().splitlines()
    canonical=(out/f'canonical-{opt}.txt').read_text().splitlines()
    if actual != canonical:
        (out/f'canonical-differences-{opt}.txt').write_text('\n'.join(
            f'{a} != {c}' for a,c in zip(actual,canonical) if a != c)+'\n')
        raise SystemExit('Backport differs from exact canonical 5.10 source extraction')
    if actual != base:
        raise SystemExit('Backport optimization-dependent results')
    if len(actual) != len(reference):
        raise SystemExit('Mismatched differential output lengths')
    mismatches=[f'{a} != {r}' for a,r in zip(actual,reference) if a != r]
    (out/f'differences-{opt}.txt').write_text('\n'.join(mismatches)+ ('\n' if mismatches else ''))
    cases=sum(not line.startswith(('LOCALE','SKIP-LOCALE')) for line in actual)
    summary.append(f'{opt}: PASS {cases} Float/Double pairs match exact canonical 5.10 source; {len(mismatches)} differing rows vs native host runtime')
    failed |= bool(mismatches)
summary.append('Reference: native Substring initializer compiled by recorded compiler; OS-provided host runtime, NOT a pinned Swift 5.10 runtime. See runtime/libraries/version records.')
(out/'summary.txt').write_text('\n'.join(summary)+'\n')
print('\n'.join(summary))
if failed:
    print('DISCLOSED: native-host drift; inspect differences, loaded-runtime-version, and source-manifest records.')
    if os.environ.get('ALLOW_NATIVE_DIFFERENCES') != '1':
        raise SystemExit('Host native differential differs; use ALLOW_NATIVE_DIFFERENCES=1 only after reviewing drift. Canonical source equivalence passed.')
PY
