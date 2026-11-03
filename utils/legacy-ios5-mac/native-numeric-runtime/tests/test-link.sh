#!/bin/bash
# SDK-only ABI/link proof. Does not build/change/install any application.
# Usage: SDK CLANG SWIFTC RES ARCHIVE_BUILD NEW_OUT
set -euo pipefail
[ "$#" = 6 ] || { echo 'Usage: SDK CLANG SWIFTC RES ARCHIVE_BUILD NEW_OUT' >&2; exit 1; }
SDK=$1; CLANG=$2; SWIFTC=$3; RES=$4; BUILD=$5; OUT=$6
SRC=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
for p in "$SDK" "$CLANG" "$SWIFTC" "$RES" "$BUILD" "$OUT"; do [[ "$p" = /* ]] || exit 1; done
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo 'Output must be new' >&2; exit 1; }
mkdir -p "$OUT/logs" "$OUT/cache" "$OUT/tmp"
export TMPDIR="$OUT/tmp" CLANG_MODULE_CACHE_PATH="$OUT/cache"
ARCHIVE="$BUILD/libswiftLegacyNativeNumeric.a"
[ -f "$ARCHIVE" ] || exit 1
run() {
  local name=$1; shift
  (printf '%q ' "$@"; printf '\n') > "$OUT/logs/$name.command"
  if ! "$@" > "$OUT/logs/$name.log" 2>&1; then
    tail -60 "$OUT/logs/$name.log" >&2; exit 1
  fi
}
"${PYTHON:-python3}" "$SRC/tests/audit-archive.py" "$SRC" "$BUILD" "$RES/iphoneos/libswiftCore.dylib"
common=(-parse-as-library -target armv7-apple-ios5.0 -sdk "$SDK" -resource-dir "$RES"
  -enable-legacy-ios5-runtime -runtime-compatibility-version none
  -module-cache-path "$OUT/cache" -Xfrontend -disable-all-autolinking)
link=(-target armv7-apple-ios5.0 -isysroot "$SDK" -dynamiclib
  "-L$RES/iphoneos" -lswiftCore -Wl,-undefined,error)
for opt in Onone O; do
  for name in OriginalCalls SubstringCalls; do
    run "$name-$opt" "$SWIFTC" "${common[@]}" "-$opt" -module-name "${name}${opt}" \
      -emit-object "$SRC/tests/$name.swift" -o "$OUT/$name-$opt.o"
    run "$name-$opt-sil" "$SWIFTC" "${common[@]}" "-$opt" -module-name "${name}${opt}" \
      -emit-sil "$SRC/tests/$name.swift" -o "$OUT/$name-$opt.sil"
    run "$name-$opt-link" "$CLANG" "${link[@]}" "$OUT/$name-$opt.o" "$ARCHIVE" \
      "-Wl,-map,$OUT/$name-$opt.map" -o "$OUT/$name-$opt.dylib"
  done
  # Optimized specialization reproduces the missing entries. At -Onone the
  # unchanged String caller can instead use the existing old generic entry.
  command=("$CLANG" "${link[@]}" "$OUT/OriginalCalls-$opt.o" -o "$OUT/without-$opt.dylib")
  (printf '%q ' "${command[@]}"; printf '\n') > "$OUT/logs/negative-$opt.command"
  if "${command[@]}" > "$OUT/logs/negative-$opt.log" 2>&1; then
    [ "$opt" = Onone ] || { echo 'Optimized negative control unexpectedly linked' >&2; exit 1; }
    printf '0\n' > "$OUT/logs/negative-$opt.exit"
  else
    printf '1\n' > "$OUT/logs/negative-$opt.exit"
  fi
done
# Force-load is test-only: inspect an overlay-shaped image with no caller exports.
run overlay "$CLANG" "${link[@]}" "-Wl,-force_load,$ARCHIVE" -o "$OUT/numeric-overlay.dylib"
"${PYTHON:-python3}" - "$SRC" "$OUT" <<'PY'
import pathlib,subprocess,sys
src,out=map(pathlib.Path,sys.argv[1:])
expected=set((src/'exports.txt').read_text().splitlines())
for opt in ('Onone','O'):
    status=(out/f'logs/negative-{opt}.exit').read_text().strip()
    if status == '0':
        if opt != 'Onone':
            raise SystemExit('Optimized negative control unexpectedly linked')
        continue
    text=(out/f'logs/negative-{opt}.log').read_text()
    if not all(f'Swift.{name}.init(Swift.Substring)' in text for name in ('Double','Float')):
        raise SystemExit('Negative control failed for a reason other than both native entries')
for image in sorted(out.glob('*.dylib')):
    loads=subprocess.check_output(['/usr/bin/otool','-L',str(image)],text=True)
    (out/(image.name+'.libraries.txt')).write_text(loads)
    commands=subprocess.check_output(['/usr/bin/otool','-l',str(image)],text=True)
    (out/(image.name+'.load-commands.txt')).write_text(commands)
    if any(x in loads for x in ('Concurrency','Compatibility56','StringProcessing')):
        raise SystemExit('Unexpected modern runtime dependency')
    imports=set(subprocess.check_output(['/usr/bin/nm','-uj',str(image)],text=True).splitlines())
    if imports & expected:
        raise SystemExit('Missing initializer remains undefined')
exports=set(subprocess.check_output(['/usr/bin/nm','-gUj',str(out/'numeric-overlay.dylib')],text=True).splitlines())
(out/'overlay-exports.txt').write_text('\n'.join(sorted(exports))+'\n')
if exports != expected:
    raise SystemExit('Overlay exports unexpected public helpers: '+repr(exports))
(out/'summary.txt').write_text('PASS: unchanged Double(String)/Float(String) and genuine Substring callers link at -Onone/-O with -undefined,error; optimized negative control misses both native entries (Onone may use old generic entry); overlay exports exactly two native symbols; no modern runtime autoload. Selected old Core iOS7 floor warning remains unmodified. No device execution.\n')
print((out/'summary.txt').read_text(),end='')
PY
