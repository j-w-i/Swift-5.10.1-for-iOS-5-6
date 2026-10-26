#!/bin/bash
# Source-only iOS 5 Foundation backports. Usage: SDK CLANG AR OUT
set -euo pipefail
umask 022
fail() { printf 'build-foundation-runtime: %s\n' "$*" >&2; exit 1; }
[ "$#" = 4 ] || fail 'Usage: SDK CLANG AR OUT'
SDK=$1; CLANG=$2; AR=$3; OUT=$4
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SRC="$HERE/vendor/FoundationBackports"
for path in "$SDK" "$CLANG" "$AR" "$OUT"; do [[ "$path" = /* ]] || fail "Use absolute paths: $path"; done
[ -d "$SDK" ] && [ -x "$CLANG" ] && [ -x "$AR" ] || fail 'Missing SDK, clang or archive tool'
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || fail "Refusing existing output: $OUT"
mkdir "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)
mkdir "$OUT/objects" "$OUT/logs"
export ZERO_AR_DATE=1
for required in Core/FBPTimer.m Core/FBPURLComponents.m Core/FBPISO8601DateFormatter.m Extras/FBPExtrasInstaller.m Extras/FBPCharacterSetExtras.m Extras/FBPCalendarExtras.m Extras/FBPStringExtras.m Networking/FBPURLSession.m; do
  [ -f "$SRC/$required" ] || fail "Missing required source: $required"
done
OBJECTS=()
for source in "$SRC"/Core/*.m "$SRC"/Extras/*.m "$SRC"/Networking/FBPURLSession.m; do
  [ -f "$source" ] || fail "Missing source: $source"
  name=$(basename -- "$source" .m)
  command=("$CLANG" -target armv7-apple-ios5.0 -marm -isysroot "$SDK" -O2 -g0
    -fobjc-arc -fblocks -fno-modules -fvisibility=default
    "-ffile-prefix-map=$HERE=utils/legacy-ios5-mac" -Wno-deprecated-declarations
    -Werror=unguarded-availability -Werror=unguarded-availability-new
    -c "$source" -o "$OUT/objects/$name.o")
  (printf '%q ' "${command[@]}"; printf '\n') > "$OUT/logs/$name.command"
  if ! "${command[@]}" > "$OUT/logs/$name.log" 2>&1; then
    tail -40 "$OUT/logs/$name.log" >&2; fail "Compilation failed: $name"
  fi
  OBJECTS+=("$OUT/objects/$name.o")
done
[ "${#OBJECTS[@]}" -gt 0 ] || fail 'No source files found'
"$AR" rcs "$OUT/libswiftLegacyFoundationBackports.a" "${OBJECTS[@]}" > "$OUT/logs/archive.log" 2>&1
"${PYTHON:-python3}" - "$SRC" "$SDK" "$CLANG" "$OUT" <<'PY'
import hashlib,json,pathlib,subprocess,sys
src,sdk,clang,out=map(pathlib.Path,sys.argv[1:])
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
archive=out/'libswiftLegacyFoundationBackports.a'
undefined=subprocess.check_output(['/usr/bin/nm','-u',str(archive)],text=True)
(out/'logs/undefined-symbols.txt').write_text(undefined)
for forbidden in ('objc_storeWeak','objc_loadWeak','objc_initWeak','objc_destroyWeak','objc_copyWeak','objc_moveWeak','_OBJC_CLASS_$_NSURLSession','_OBJC_CLASS_$_NSURLComponents','_OBJC_CLASS_$_NSURLQueryItem','_OBJC_CLASS_$_NSISO8601DateFormatter'):
    if forbidden in undefined: raise SystemExit('Prohibited modern runtime import: '+forbidden)
symbols=subprocess.check_output(['/usr/bin/nm',str(archive)],text=True)
for cls in ('FBPURLSession','FBPURLSessionConfiguration','FBPURLSessionTask','FBPURLSessionDataTask','FBPURLSessionUploadTask','FBPURLSessionDownloadTask','FBPURLComponents','FBPURLQueryItem','FBPISO8601DateFormatter'):
    if '_OBJC_CLASS_$_'+cls not in symbols: raise SystemExit('Missing class export: '+cls)
(out/'logs/symbol-audit.txt').write_text('PASS required class symbols; no zeroing-weak runtime or modern Foundation class imports\n')
m={'target':'armv7-apple-ios5.0','instructionSet':'ARM','arc':True,'sdk':str(sdk.resolve()),'clang':str(clang.resolve()),'clangVersion':subprocess.check_output([str(clang),'--version'],text=True),'sourceSHA256':{str(p.relative_to(src)):h(p) for d in ('Core','Extras','Networking') for p in sorted((src/d).glob('*')) if p.suffix in ('.m','.h')},'archiveSHA256':h(out/'libswiftLegacyFoundationBackports.a'),'qualification':'Compilation only. Networking host deterministic tests are separate; iOS5 runtime/device not qualified.'}
(out/'build-manifest.json').write_text(json.dumps(m,indent=2)+'\n')
PY
for notice in "$SRC/LICENSE" "$HERE/FOUNDATION-BACKPORTS.md"; do
  [ -f "$notice" ] || fail "Missing required notice: $notice"
done
mkdir "$OUT/legacy-foundation"
cp "$SRC/LICENSE" "$OUT/legacy-foundation/LICENSE"
cp "$HERE/FOUNDATION-BACKPORTS.md" "$OUT/legacy-foundation/FOUNDATION-BACKPORTS.md"
cp "$OUT/build-manifest.json" "$OUT/legacy-foundation/build-manifest.json"
printf 'Built Foundation runtime: %s\n' "$OUT"
