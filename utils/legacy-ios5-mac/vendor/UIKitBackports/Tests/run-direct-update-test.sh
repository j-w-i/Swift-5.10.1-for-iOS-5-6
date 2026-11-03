#!/bin/bash
# Same-process native/forced-backport callback differential. No boot, cleanup, or device install.
# Usage: bash run-direct-update-test.sh NEW_OUTPUT_DIRECTORY BOOTED_SIMULATOR_UUID
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
VENDOR=$(CDPATH= cd -- "$HERE/.." && pwd -P)
OUT=${1:?new output directory required}
UDID=${2:?explicit booted simulator UUID required}
python3 - "$VENDOR" "$OUT" <<'PY'
import hashlib,json,re,sys
from pathlib import Path
vendor,out=map(Path,sys.argv[1:])
out.mkdir(parents=True,exist_ok=False)
(out/'src').mkdir()
hashes={}
for component in ('Cassowary','LegacyAutoLayout'):
 for path in sorted((vendor/component).glob('*.swift')):
  if path.stem in ('LegacyAutoLayoutIOS5','UILayoutGuideShim','UIViewAnchorShims'):continue
  text=path.read_text()
  hashes[str(path.relative_to(vendor))]=hashlib.sha256(path.read_bytes()).hexdigest()
  text=re.sub(r'^import (UIKit|Cassowary|LegacyAutoLayout)\s*$','',text,flags=re.M)
  text=re.sub(r'^private typealias (Expression|Constraint|RelationalOperator) = \w+\.\w+\s*$','',text,flags=re.M)
  text=text.replace('Cassowary.','')
  (out/'src'/(component+'-'+path.name)).write_text('import UIKit\n'+text)
for path in sorted((vendor/'Runtime').glob('*.swift')):
 text=path.read_text()
 hashes[str(path.relative_to(vendor))]=hashlib.sha256(path.read_bytes()).hexdigest()
 text=re.sub(r'^import CUIKitBackports\s*$', '@_silgen_name("UICInstallConstraintClassMethods")\nfunc UICInstallConstraintClassMethods()',text,flags=re.M)
 (out/'src'/path.name).write_text('import UIKit\n'+text)
for name in ('Tests/autolayout_direct_update.swift','CassowaryC/CassowaryC.c'):
 hashes[name]=hashlib.sha256((vendor/name).read_bytes()).hexdigest()
main=(vendor/'Tests/autolayout_direct_update.swift').read_text()
# Append existing fixture definitions, not their standalone top-level drivers.
for name in ('autolayout_update_order.swift','autolayout_simulator_layout_test.swift','autolayout_scroll_content_root.swift'):
 path=vendor/'Tests'/name
 hashes['Tests/'+name]=hashlib.sha256(path.read_bytes()).hexdigest()
 main+='\n'+path.read_text().split('MainActor.assumeIsolated',1)[0]
main+='''\nMainActor.assumeIsolated {
    precondition(observeUpdates() == [["C","P"],[],["C"],["P"]], "existing callback regression")
    precondition(runLayoutTest(), "existing layout regression")
    precondition(checkScrollRoot(), "accepted narrow scroll-root regression")
    print("direct-update integration regressions: PASS")
}
'''
(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
(out/'main.swift').write_text(main)
(out/'stub.c').write_text('void UICInstallConstraintClassMethods(void) {}\n')
PY
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET=$(uname -m)-apple-ios15.0-simulator
clang -target "$TARGET" -isysroot "$SDK" -c "$OUT/stub.c" -o "$OUT/stub.o"
clang -target "$TARGET" -isysroot "$SDK" -O2 -ffp-contract=off -c "$VENDOR/CassowaryC/CassowaryC.c" -o "$OUT/CassowaryC.o"
xcrun swiftc -swift-version 5 -target "$TARGET" -sdk "$SDK" -O \
  "$OUT"/src/*.swift "$OUT/main.swift" "$OUT/stub.o" "$OUT/CassowaryC.o" -o "$OUT/simrun" > "$OUT/build.log" 2>&1
xcrun simctl spawn "$UDID" "$OUT/simrun" > "$OUT/run.log" 2>&1
printf 'PASS: direct-update differential; evidence in %s\n' "$OUT"
