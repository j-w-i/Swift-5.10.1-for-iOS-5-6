#!/bin/bash
# Report the known lifecycle mismatch; --gate requires fit-before-display on both routes.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P); SRC="$HERE/.."; SIM=${1:?sim uuid}; MODE=${2:---report}
OUT=$(mktemp -d "${TMPDIR:-/tmp}/selfsizing-display.XXXXXX"); SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FLAGS=(-target arm64-apple-ios17.0-simulator -isysroot "$SDK" -O2 -fobjc-arc -fblocks -fno-modules -DPST_TOOLCHAIN_RUNTIME=1 -Wno-nullability-completeness -Wno-incompatible-pointer-types -I "$SRC")
OBJECTS=(); for s in "$SRC"/*.m; do o="$OUT/$(basename "$s" .m).o"; xcrun clang "${FLAGS[@]}" -c "$s" -o "$o" >>"$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; exit 1; }; OBJECTS+=("$o"); done
for m in native pst; do E=(); [[ $m == pst ]] && E=(-DTEST_PST=1 "${OBJECTS[@]}")
  xcrun clang "${FLAGS[@]}" "$HERE/selfsizing-display-lifecycle.m" ${E[@]+"${E[@]}"} -framework UIKit -framework QuartzCore -framework CoreGraphics -o "$OUT/$m"
  xcrun simctl spawn "$SIM" "$OUT/$m" > "$OUT/$m.json"
done
python3 - "$OUT" "$MODE" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); bad=False
for engine in ('native','pst'):
    rows=json.loads((p/f'{engine}.json').read_text())
    assert len(rows)==2
    for r in rows:
        assert r['displays']>0
        print(f"{engine:6} changed={r['changed']} displays={r['displays']} displayed-before-fit={r['unfittedDisplays']}")
        if engine=='native': assert r['unfittedDisplays']==0, 'Oracle no longer fits before display; investigate'
        bad |= r['unfittedDisplays']!=0
print(f'Artifacts: {p}')
if sys.argv[2]=='--gate' and bad: raise SystemExit(1)
PY
