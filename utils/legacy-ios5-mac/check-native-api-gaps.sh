#!/bin/bash
# Verify actual SDK API spellings, not application substitutes. No installation.
# Usage: TOOLCHAIN SDK NEW_OUT
set -euo pipefail
[ "$#" -eq 3 ] || { echo 'Usage: TOOLCHAIN SDK NEW_OUT' >&2; exit 64; }
TC="$1"; SDK="$2"; OUT="$3"
[ -x "$TC/usr/bin/swift-frontend" ] && [ -d "$SDK" ] || exit 1
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo 'Output already exists.' >&2; exit 1; }
mkdir -p "$OUT/cache"
python3 - "$TC" "$SDK" "$OUT" <<'PY'
from pathlib import Path
import json,subprocess,sys
TC,SDK,OUT=map(Path,sys.argv[1:])
res=TC/'usr/lib/swift_ios5'
base=[str(TC/'usr/bin/swift-frontend'),'-sdk',str(SDK),'-target','armv7-apple-ios5.0',
      '-resource-dir',str(res),'-enable-legacy-ios5-runtime','-runtime-compatibility-version','none',
      '-Xcc','-resource-dir','-Xcc',str(res/'clang'),'-Xcc','-I'+str(res/'legacy-overlay-shims'),
      '-module-cache-path',str(OUT/'cache'),'-parse-as-library']
checks={
 'priorities':('import UIKit\nfunc f() -> [UILayoutPriority] { [.required, .defaultHigh, .defaultLow, .fittingSizeLevel] }\n',None),
 'intrinsicSentinel':('import UIKit\nfunc f() -> CGFloat { UIView.noIntrinsicMetric }\n',None),
 'main':('import UIKit\n@main final class EntryProbe: UIResponder, UIApplicationDelegate {}\n',None),
 'optionalInherited':('import UIKit\nfinal class GestureProbe: UIView, UIGestureRecognizerDelegate {}\n',None),
 'directGestureStillUnavailable':('import UIKit\nfunc f(_ v: UIView, _ g: UIGestureRecognizer) { _ = v.gestureRecognizerShouldBegin(g) }\n','only available in iOS 6.0'),
 'safeAreaStillUnavailable':('import UIKit\nfunc f(_ v: UIView) { _ = v.safeAreaLayoutGuide }\n','only available in iOS 11.0'),
}
rows=[]
for name,(source,error) in checks.items():
 p=OUT/(name+'.swift'); p.write_text(source)
 command=base+['-emit-ir',str(p),'-o',str(OUT/(name+'.ll'))]
 run=subprocess.run(command,text=True,capture_output=True)
 (OUT/(name+'.log')).write_text(run.stdout+run.stderr)
 passed=(run.returncode!=0 and error in run.stderr) if error else run.returncode==0
 rows.append({'name':name,'passed':passed,'returncode':run.returncode,'expectedDiagnostic':error,'command':command})
 print(('PASS ' if passed else 'FAIL ')+name)
 if passed and not error and name=='priorities':
  ir=(OUT/(name+'.ll')).read_text()
  assert 'internal constant float 1.000000e+03' in ir, 'required priority must be the literal 1000'
  assert 'internal constant float 7.500000e+02' in ir, 'defaultHigh priority must be the literal 750'
  assert 'internal constant float 2.500000e+02' in ir, 'defaultLow priority must be the literal 250'
  assert 'external global' not in ir and '@UILayoutPriorityRequired = external' not in ir, \
      'priorities must not import absent native UIKit globals'
 if passed and name=='intrinsicSentinel':
  ir=(OUT/(name+'.ll')).read_text()
  assert '_SwiftLegacyUIViewNoIntrinsicMetric' in ir, 'sentinel must bind to the SDK-owned definition'
  assert '"_UIViewNoIntrinsicMetric"' not in ir, 'sentinel must not bind to the absent iOS 6 global'
(OUT/'results.json').write_text(json.dumps({'checks':rows,'deviceExecution':'pending'},indent=2)+'\n')
if not all(row['passed'] for row in rows): raise SystemExit(1)
PY
