#!/bin/bash
# Source-only bounded private NSHashTable backend. No SDK/toolchain installation.
# Usage: SDK CLANG AR OUT. OUT must be new and under the designated artifact root.
set -euo pipefail
fail() { printf 'build-native-hashtable-runtime: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 4 ] || fail 'Usage: SDK CLANG AR OUT'
SDK=$1; CLANG=$2; AR=$3; OUT=$4
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SRC="$HERE/native-foundation-runtime/HashTable"
for p in "$SDK" "$CLANG" "$AR" "$OUT"; do [[ "$p" = /* ]] || fail 'Absolute paths required'; done
[ -d "$SDK" ] && [ -x "$CLANG" ] && [ -x "$AR" ] || fail 'Missing SDK/compiler/archive tool'
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || fail 'Refusing existing output'
# No install operation. The source checkout need not contain a Work directory.
[[ "$OUT" = */sdk-build/hashtable/* ]] || fail 'OUT must be below Work/sdk-build/hashtable'
mkdir -p "$OUT/objects" "$OUT/logs" "$OUT/tmp" "$OUT/cache"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)
export TMPDIR="$OUT/tmp" CLANG_MODULE_CACHE_PATH="$OUT/cache" ZERO_AR_DATE=1
run() {
  local name=$1; shift
  (printf '%q ' "$@"; printf '\n') > "$OUT/logs/$name.command"
  if ! "$@" > "$OUT/logs/$name.log" 2>&1; then tail -60 "$OUT/logs/$name.log" >&2; fail "Failed: $name"; fi
}
run compile "$CLANG" -target armv7-apple-ios5.0 -marm -isysroot "$SDK" \
  -fno-objc-arc -fno-modules -fvisibility=hidden -O2 -g0 \
  -Wall -Wextra -Wno-unused-parameter -Werror=unguarded-availability \
  -Werror=unguarded-availability-new "-ffile-prefix-map=$HERE=utils/legacy-ios5-mac" \
  -c "$SRC/FBPHashTable.m" -o "$OUT/objects/FBPHashTable.o"
run archive "$AR" rcs "$OUT/libswiftLegacyNativeHashTable.a" "$OUT/objects/FBPHashTable.o"
"${PYTHON:-python3}" - "$SRC" "$SDK" "$CLANG" "$OUT" "$HERE/build-native-hashtable-runtime.sh" <<'PY'
import hashlib,json,pathlib,sys
src,sdk,clang,out,builder=map(pathlib.Path,sys.argv[1:])
h=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
manifest={'target':'armv7-apple-ios5.0','sdk':str(sdk),'clang':str(clang),
 'sources':{str(p.relative_to(src)):h(p) for p in sorted(src.rglob('*')) if p.is_file()},
 'builderSHA256':h(builder),'archiveSHA256':h(out/'libswiftLegacyNativeHashTable.a'),
 'qualification':'EXPERIMENTAL bounded backend; no installation, importer integration, device qualification or complete NSPointerFunctions equivalence. See source README.'}
(out/'build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
printf 'Built experimental private backend: %s\n' "$OUT"
