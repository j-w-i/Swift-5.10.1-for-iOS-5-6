#!/bin/bash
# Source-only Swift 5.10 Float/Double Substring entries. No installation.
# Usage: ARCH SDK CLANG AR SWIFTC_OR_FRONTEND RES OUT [CORE] (absolute paths, OUT new)
#
# ARCH selects the slice: armv7 keeps the legacy iOS 5.0 floor in ARM mode, armv7s/arm64 build the
# same Swift/C sources at an iOS 7.0 floor (arm64 additionally drops the 32-bit ARM-mode flags).
set -euo pipefail
umask 022
fail() { printf 'build-native-numeric-runtime: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 7 ] || [ "$#" -eq 8 ] || fail 'Usage: ARCH SDK CLANG AR SWIFTC_OR_FRONTEND RES OUT [CORE]'
ARCH=$1; SDK=$2; CLANG=$3; AR=$4; SWIFTC=$5; RES=$6; OUT=$7
CORE=${8:-$RES/iphoneos/libswiftCore.dylib}
case "$ARCH" in
  armv7)  TARGET_SUFFIX=apple-ios5.0; ARCH_FLAGS=(-marm); ISET='ARM' ;;
  armv7s) TARGET_SUFFIX=apple-ios7.0; ARCH_FLAGS=(-marm); ISET='ARM' ;;
  arm64)  TARGET_SUFFIX=apple-ios7.0; ARCH_FLAGS=();      ISET='ARM64' ;;
  *) fail "Unsupported architecture: $ARCH" ;;
esac
TARGET="$ARCH-$TARGET_SUFFIX"
# The legacy ABI/runtime flag only exists for the armv7 iOS 5 slice; newer slices use the normal
# Swift 5 ABI so they must not enable it.
LEGACY_RUNTIME_FLAGS=()
[ "$ARCH" = armv7 ] && LEGACY_RUNTIME_FLAGS=(-enable-legacy-ios5-runtime)
[ -f "$CORE" ] || fail 'Missing selected legacy Core for ABI validation'
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
SRC="$HERE/native-numeric-runtime"
for path in "$SDK" "$CLANG" "$AR" "$SWIFTC" "$RES" "$OUT" "$CORE"; do
  [[ "$path" = /* ]] || fail "Use absolute paths: $path"
done
[ -d "$SDK" ] && [ -d "$RES/iphoneos" ] || fail 'Missing SDK or Swift resource directory'
[ -x "$CLANG" ] && [ -x "$AR" ] && [ -x "$SWIFTC" ] || fail 'Missing compiler/archive tool'
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || fail "Refusing existing output: $OUT"
mkdir -p "$OUT"
OUT=$(CDPATH= cd -- "$OUT" && pwd -P)
mkdir "$OUT/objects" "$OUT/logs" "$OUT/cache" "$OUT/tmp"
export TMPDIR="$OUT/tmp" CLANG_MODULE_CACHE_PATH="$OUT/cache" ZERO_AR_DATE=1
run() {
  local name=$1; shift
  (printf '%q ' "$@"; printf '\n') > "$OUT/logs/$name.command"
  if ! "$@" > "$OUT/logs/$name.log" 2>&1; then
    tail -60 "$OUT/logs/$name.log" >&2; fail "Failed: $name"
  fi
}
run cxx "$CLANG" -target "$TARGET" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} -isysroot "$SDK" \
  -std=c++11 -stdlib=libc++ -O2 -g0 -fno-exceptions -fno-rtti -fvisibility=hidden \
  "-ffile-prefix-map=$HERE=utils/legacy-ios5-mac" \
  -Werror=unguarded-availability -Werror=unguarded-availability-new \
  -c "$SRC/NumericParsing.cpp" -o "$OUT/objects/NumericParsing.o"
# No Swift module is emitted/installed. Clients already import the SDK's Swift.
# Explicit Core linkage is audited; do not autoload unrelated 5.6/concurrency libs.
AUTOLINK_FLAGS=(-Xfrontend -disable-all-autolinking)
if [[ "$(basename "$SWIFTC")" = swift-frontend ]]; then
  AUTOLINK_FLAGS=(-disable-all-autolinking)
fi
run swift "$SWIFTC" -O -parse-as-library -target "$TARGET" \
  -sdk "$SDK" -resource-dir "$RES" ${LEGACY_RUNTIME_FLAGS[@]+"${LEGACY_RUNTIME_FLAGS[@]}"} \
  -runtime-compatibility-version none -module-name SwiftLegacyNativeNumeric \
  -module-cache-path "$OUT/cache" -I "$SRC/private" \
  -file-prefix-map "$HERE=utils/legacy-ios5-mac" \
  "${AUTOLINK_FLAGS[@]}" \
  -emit-object "$SRC/NativeNumeric.swift" -o "$OUT/objects/NativeNumeric.o"
run archive "$AR" rcs "$OUT/libswiftLegacyNativeNumeric.a" \
  "$OUT/objects/NativeNumeric.o" "$OUT/objects/NumericParsing.o"
"${PYTHON:-python3}" "$SRC/tests/audit-archive.py" "$SRC" "$OUT" "$CORE"
"${PYTHON:-python3}" - "$SRC" "$SDK" "$CLANG" "$AR" "$SWIFTC" "$RES" "$OUT" "$CORE" <<'PY'
import hashlib, os,json,pathlib,subprocess,sys
src,sdk,clang,ar,swiftc,res,out,core=map(pathlib.Path,sys.argv[1:])
h=lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
manifest={
 'target':os.environ.get('NUMERIC_TARGET','armv7-apple-ios5.0'),'instructionSetC':os.environ.get('NUMERIC_ISET','ARM'),'swiftOptimization':'-O',
 'sdk':str(sdk),'resourceDir':str(res),'clang':str(clang),'ar':str(ar),'swiftc':str(swiftc),
 'clangVersion':subprocess.check_output([str(clang),'--version'],text=True),
 'swiftVersion':subprocess.check_output([str(swiftc),'--version'],text=True),
 'sourceSHA256':{str(p.relative_to(src)):h(p) for p in sorted(src.rglob('*')) if p.is_file()},
 'builderSHA256':h(src.parent/'build-native-numeric-runtime.sh'),
 'archiveSHA256':h(out/'libswiftLegacyNativeNumeric.a'),
 'selectedCore':str(core),'selectedCoreSHA256':h(core),
 'qualification':'Source-built additive Float/Double Substring entries only; no installation/device qualification. Old generic fallback and Core deployment floor unchanged.'}
(out/'build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
PY
cp "$SRC/LICENSE.txt" "$SRC/exports.txt" "$OUT/"
printf 'Built native numeric runtime: %s\n' "$OUT"
