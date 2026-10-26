#!/bin/bash
# Source-only armv7 iOS 5 PST runtime; no network, installed toolchain writes, or xcrun.
# Usage: build-collection-runtime.sh SDK CLANG AR OUT
# OUT must not exist. Outputs: libswiftLegacyCollectionView.a and legacy-collection/.
set -euo pipefail
umask 022
fail() { printf 'build-collection-runtime: %s\n' "$*" >&2; exit 1; }
[ "$#" = 4 ] || fail 'Usage: build-collection-runtime.sh SDK CLANG AR OUT'
SDK=$1; CLANG=$2; AR=$3; OUT=$4
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SRC="$HERE/vendor/PSTCollectionView"
for path in "$SDK" "$CLANG" "$AR" "$OUT"; do
  [[ "$path" = /* ]] || fail "Use absolute paths: $path"
done
[ -d "$SDK" ] && [ -x "$CLANG" ] && [ -x "$AR" ] || fail 'Missing SDK, clang or archive tool.'
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || fail "Refusing existing output: $OUT"
# Atomic claim; parent must exist, and failures retain all diagnostic evidence.
mkdir "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)
mkdir "$OUT/objects" "$OUT/logs" "$OUT/legacy-collection"
export ZERO_AR_DATE=1
"${PYTHON:-python3}" "$HERE/generate-collection-headers.py" "$SRC" "$OUT/legacy-collection/Headers"
cp "$SRC/LICENSE" "$OUT/legacy-collection/LICENSE"
cp "$SRC/SNAPSHOT.json" "$OUT/legacy-collection/SNAPSHOT.json"
OBJECTS=()
for source in "$SRC"/*.m; do
  name=$(basename -- "$source" .m)
  command=("$CLANG" -target armv7-apple-ios5.0 -isysroot "$SDK" -O2 -g0
    -fobjc-arc -fblocks -fno-modules -fvisibility=default -DPST_TOOLCHAIN_RUNTIME=1
    "-ffile-prefix-map=$HERE=utils/legacy-ios5-mac"
    -Werror=unguarded-availability -Werror=unguarded-availability-new
    -I "$SRC" -c "$source" -o "$OUT/objects/$name.o")
  (printf '%q ' "${command[@]}"; printf '\n') > "$OUT/logs/$name.command"
  if ! /usr/bin/nice -n 15 "${command[@]}" > "$OUT/logs/$name.log" 2>&1; then
    tail -40 "$OUT/logs/$name.log" >&2
    fail "Compilation failed: $name (see $OUT/logs)"
  fi
  OBJECTS+=("$OUT/objects/$name.o")
done
(printf '%q ' "$AR" rcs "$OUT/libswiftLegacyCollectionView.a" "${OBJECTS[@]}"; printf '\n') > "$OUT/logs/archive.command"
"$AR" rcs "$OUT/libswiftLegacyCollectionView.a" "${OBJECTS[@]}" > "$OUT/logs/archive.log" 2>&1
"${PYTHON:-python3}" - "$SRC" "$SDK" "$CLANG" "$AR" "$OUT" <<'PY'
import hashlib, json, pathlib, subprocess, sys
src, sdk, clang, ar, out = map(pathlib.Path, sys.argv[1:])
hashfile = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
manifest = {
    'target': 'armv7-apple-ios5.0', 'arc': True, 'blocks': True,
    'sdk': str(sdk.resolve()), 'clang': str(clang.resolve()), 'ar': str(ar.resolve()),
    'clangVersion': subprocess.check_output([str(clang), '--version'], text=True),
    'sourceSHA256': {p.name: hashfile(p) for p in sorted(src.iterdir()) if p.is_file()},
    'archiveSHA256': hashfile(out / 'libswiftLegacyCollectionView.a'),
    'headerSHA256': hashfile(out / 'legacy-collection/Headers/UIKitLegacyCollection.h'),
    'qualification': 'Source compilation only; not device/runtime qualification.'}
(out / 'build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY
printf 'Built source runtime and importer headers: %s\n' "$OUT"
