#!/bin/bash
# Source-only Foundation backports. Usage: SDK CLANG AR OUT [ARCH]
#
# ARCH defaults to armv7 (iOS 5.0 floor, ARM mode). armv7s/arm64 build the same
# sources at an iOS 7.0 floor, where the native classes they emulate exist, so
# their audit does not treat those imports as prohibited.
set -euo pipefail
umask 022
fail() { printf 'build-foundation-runtime: %s\n' "$*" >&2; exit 1; }
[ "$#" = 4 ] || [ "$#" = 5 ] || fail 'Usage: SDK CLANG AR OUT [ARCH]'
SDK=$1; CLANG=$2; AR=$3; OUT=$4; ARCH=${5:-armv7}
case "$ARCH" in
  armv7)  TARGET=armv7-apple-ios5.0; ARCH_FLAGS=(-marm) ;;
  armv7s) TARGET=armv7s-apple-ios7.0; ARCH_FLAGS=(-marm) ;;
  arm64)  TARGET=arm64-apple-ios7.0;  ARCH_FLAGS=() ;;
  *) fail "Unsupported architecture: $ARCH" ;;
esac
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SRC="$HERE/vendor/FoundationBackports"
for path in "$SDK" "$CLANG" "$AR" "$OUT"; do [[ "$path" = /* ]] || fail "Use absolute paths: $path"; done
[ -d "$SDK" ] && [ -x "$CLANG" ] && [ -x "$AR" ] || fail 'Missing SDK, clang or archive tool'
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || fail "Refusing existing output: $OUT"
mkdir "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)
mkdir "$OUT/objects" "$OUT/logs"
export ZERO_AR_DATE=1
for required in "$HERE/native-foundation-runtime/HashTable/FBPHashTable.m" Core/FBPTimer.m Core/FBPURLComponents.m Core/FBPISO8601DateFormatter.m Extras/FBPExtrasInstaller.m Extras/FBPCharacterSetExtras.m Extras/FBPCalendarExtras.m Extras/FBPStringExtras.m Networking/FBPURLSession.m; do
  [ -f "$SRC/$required" ] || [ -f "$required" ] || fail "Missing required source: $required"
done
OBJECTS=()
for source in "$SRC"/Core/*.m "$SRC"/Extras/*.m "$SRC"/Networking/FBPURLSession.m "$HERE"/native-foundation-runtime/HashTable/FBPHashTable.m; do
  [ -f "$source" ] || fail "Missing source: $source"
  name=$(basename -- "$source" .m)
  # The weak-object table stores zeroing-weak slots with explicit runtime calls
  # and owns its slot objects manually, so it is compiled without ARC.
  ARC_FLAG=-fobjc-arc
  case "$name" in FBPHashTable) ARC_FLAG=-fno-objc-arc ;; esac
  command=("$CLANG" -target "$TARGET" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} -isysroot "$SDK" -O2 -g0
    $ARC_FLAG -fblocks -fno-modules -fvisibility=default
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
"${PYTHON:-python3}" - "$SRC" "$SDK" "$CLANG" "$OUT" "$ARCH" "$TARGET" <<'PY'
import hashlib,json,pathlib,subprocess,sys
src,sdk,clang,out=map(pathlib.Path,sys.argv[1:5]); arch=sys.argv[5]; target=sys.argv[6]
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
archive=out/'libswiftLegacyFoundationBackports.a'
undefined=subprocess.check_output(['/usr/bin/nm','-u',str(archive)],text=True)
(out/'logs/undefined-symbols.txt').write_text(undefined)
# The zeroing-weak runtime functions exist in iOS 5's objc4 but only the object
# table backend may use them; every other object must stay free of them.
weak_in_table=subprocess.check_output(['/usr/bin/nm','-u',str(out/'objects'/'FBPHashTable.o')],text=True)
weak_names=('objc_storeWeak','objc_loadWeak','objc_initWeak','objc_destroyWeak',
            'objc_copyWeak','objc_moveWeak')
for name in weak_names:
    if '_'+name in undefined and '_'+name not in weak_in_table:
        raise SystemExit('Prohibited modern runtime import: '+name)
for forbidden in (() if arch != 'armv7' else ('_OBJC_CLASS_$_NSURLSession','_OBJC_CLASS_$_NSURLComponents',
                  '_OBJC_CLASS_$_NSURLQueryItem','_OBJC_CLASS_$_NSISO8601DateFormatter',
                  '_OBJC_CLASS_$_NSHashTable','_OBJC_CLASS_$_NSPointerFunctions')):
    if forbidden in undefined: raise SystemExit('Prohibited modern runtime import: '+forbidden)
symbols=subprocess.check_output(['/usr/bin/nm',str(archive)],text=True)
for cls in ('FBPURLSession','FBPURLSessionConfiguration','FBPURLSessionTask','FBPURLSessionDataTask','FBPURLSessionUploadTask','FBPURLSessionDownloadTask','FBPURLComponents','FBPURLQueryItem','FBPISO8601DateFormatter'):
    if '_OBJC_CLASS_$_'+cls not in symbols: raise SystemExit('Missing class export: '+cls)
(out/'logs/symbol-audit.txt').write_text('PASS required class symbols; zeroing-weak runtime only in the object table; no modern Foundation class imports\n')
m={'target':target,'instructionSet':'ARM','arc':True,'sdk':str(sdk.resolve()),'clang':str(clang.resolve()),'clangVersion':subprocess.check_output([str(clang),'--version'],text=True),'sourceSHA256':{str(p.relative_to(src)):h(p) for d in ('Core','Extras','Networking') for p in sorted((src/d).glob('*')) if p.suffix in ('.m','.h')},'archiveSHA256':h(out/'libswiftLegacyFoundationBackports.a'),'qualification':'Compilation only. Networking host deterministic tests are separate; iOS5 runtime/device not qualified.'}
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
