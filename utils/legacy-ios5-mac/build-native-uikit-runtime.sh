#!/bin/bash
# SDK implementation globals for actual UIKit APIs; no public helper module.
# Usage: build-native-uikit-runtime.sh SDK CLANG AR NEW_OUT
set -euo pipefail
[ "$#" -eq 4 ] || { echo "Usage: $0 SDK CLANG AR NEW_OUT" >&2; exit 64; }
SDK="$1"; CLANG="$2"; AR="$3"; OUT="$4"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
[ -d "$SDK" ] && [ -x "$CLANG" ] && [ -x "$AR" ] || { echo 'Missing build input.' >&2; exit 1; }
[ ! -e "$OUT" ] || { echo "Refusing existing output: $OUT" >&2; exit 1; }
case "$OUT" in /*) ;; *) echo 'Output must be absolute.' >&2; exit 64;; esac
mkdir -p "$OUT"
"$CLANG" -target armv7-apple-ios5.0 -marm -isysroot "$SDK" -O2 -g0 \
  -fobjc-arc -fno-modules -Werror=unguarded-availability \
  -ffile-prefix-map="$HERE"=legacy-ios5 \
  -c "$HERE/native-uikit-runtime/UIKitGlobals.m" -o "$OUT/UIKitGlobals.o"
ZERO_AR_DATE=1 "$AR" rcs "$OUT/libswiftLegacyNativeUIKit.a" "$OUT/UIKitGlobals.o"
python3 - "$OUT" "$HERE/native-uikit-runtime/UIKitGlobals.m" "$SDK" <<'PY'
from pathlib import Path
import hashlib,json,subprocess,sys
out,source,sdk=map(Path,sys.argv[1:])
archive=out/'libswiftLegacyNativeUIKit.a'
symbols=subprocess.check_output(['/usr/bin/nm','-gU',str(archive)],text=True)
assert '_SwiftLegacyUIViewNoIntrinsicMetric' in symbols,symbols
manifest={'schema':1,'target':'armv7-apple-ios5.0','instructionSet':'arm','sdk':str(sdk),
          'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),
          'archiveSHA256':hashlib.sha256(archive.read_bytes()).hexdigest(),
          'publicAPIs':['UIView.noIntrinsicMetric'],
          'privateImplementationSymbols':['_SwiftLegacyUIViewNoIntrinsicMetric']}
(out/'build-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('Built SDK-private storage for UIView.noIntrinsicMetric; no helper API declared.')
PY
