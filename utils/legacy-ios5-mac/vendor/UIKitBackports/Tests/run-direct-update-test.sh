#!/bin/bash
# Same-process native/forced-backport callback differential. No boot, cleanup, or device install.
# Usage: bash run-direct-update-test.sh NEW_OUTPUT_DIRECTORY BOOTED_SIMULATOR_UUID
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
VENDOR=$(CDPATH= cd -- "$HERE/.." && pwd -P)
OUT=${1:?new output directory required}
UDID=${2:?explicit booted simulator UUID required}
python3 - "$VENDOR" "$OUT" <<'PY'
import hashlib,json,re,sys,os
from pathlib import Path
vendor,out=map(Path,sys.argv[1:])
out.mkdir(parents=True,exist_ok=False)
(out/'src').mkdir()
hashes={}
for component in ('Cassowary','LegacyAutoLayout'):
 for path in sorted((vendor/component).glob('*.swift')):
  if path.stem in ('LegacyAutoLayoutIOS5','UILayoutGuideShim','UIViewAnchorShims'):continue
  source=Path(os.environ['LSDK_UIVIEW_SOURCE_OVERRIDE']) if path.name=='UIView+LegacyAutoLayout.swift' and os.environ.get('LSDK_UIVIEW_SOURCE_OVERRIDE') else path
  text=source.read_text()
  hashes[str(path.relative_to(vendor))]=hashlib.sha256(source.read_bytes()).hexdigest()
  text=re.sub(r'^import (UIKit|Cassowary|LegacyAutoLayout)\s*$','',text,flags=re.M)
  text=re.sub(r'^private typealias (Expression|Constraint|RelationalOperator) = \w+\.\w+\s*$','',text,flags=re.M)
  text=text.replace('Cassowary.','')
  (out/'src'/(component+'-'+path.name)).write_text('import UIKit\n'+text)
for path in sorted((vendor/'Runtime').glob('*.swift')):
 text=path.read_text()
 hashes[str(path.relative_to(vendor))]=hashlib.sha256(path.read_bytes()).hexdigest()
 text=re.sub(r'^import CUIKitBackports\s*$', '@_silgen_name("UICInstallConstraintClassMethods")\nfunc UICInstallConstraintClassMethods()',text,flags=re.M)
 (out/'src'/path.name).write_text('import UIKit\n'+text)
for path in sorted((vendor/'NSISC').glob('*')):
 if path.is_file():hashes[str(path.relative_to(vendor))]=hashlib.sha256(path.read_bytes()).hexdigest()
for name in ('Tests/autolayout_direct_update.swift','CassowaryC/CassowaryC.c','Runtime/UICLabelPreferredWidth.m'):
 hashes[name]=hashlib.sha256((vendor/name).read_bytes()).hexdigest()
main=(vendor/'Tests/autolayout_direct_update.swift').read_text()
main='import Darwin\nsetbuf(stdout, nil)\nlet centeredNative = MainActor.assumeIsolated { centeredIntrinsicFrames(legacy: false) }\nlet fittingNative = MainActor.assumeIsolated { intrinsicRootFitting(legacy: false) }\n'+main
# Append existing fixture definitions, not their standalone top-level drivers.
for name in ('autolayout_update_order.swift','autolayout_simulator_layout_test.swift','autolayout_scroll_content_root.swift'):
 path=vendor/'Tests'/name
 hashes['Tests/'+name]=hashlib.sha256(path.read_bytes()).hexdigest()
 main+='\n'+path.read_text().split('MainActor.assumeIsolated',1)[0]
for name in ('autolayout_centered_intrinsic_root.swift','autolayout_intrinsic_root_fitting.swift'):
 path=vendor/'Tests'/name
 hashes['Tests/'+path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
 main+='\n'+path.read_text()
main+='''\nMainActor.assumeIsolated {
    precondition(checkIntrinsicRootFitting(fittingNative), "fitting root must retain intrinsic metrics")
    precondition(checkCenteredIntrinsicFrames(centeredNative, centeredIntrinsicFrames(legacy: true)), "centered intrinsic resizing parity")
    precondition(observeUpdates() == [["C","P"],[],["C"],["P"]], "existing callback regression")
    precondition(runLayoutTest(), "existing layout regression")
    precondition(checkScrollRoot(), "accepted narrow scroll-root regression")
    print("direct-update integration regressions: PASS")
}
'''
import os
if os.environ.get('LSDK_LAYOUT_FIXTURE') == 'native-parity':
 path=vendor/'Tests/autolayout_native_parity.swift'
 hashes['Tests/'+path.name]=hashlib.sha256(path.read_bytes()).hexdigest()
 token=hashlib.sha256(str(out.resolve()).encode()).hexdigest()[:16]
 (out/'run-token.txt').write_text(token)
 fixture=path.read_text()
 entry='MainActor.assumeIsolated { runNativeParitySuite() }'
 assert fixture.count(entry)==1, 'native parity app entrypoint changed'
 main=fixture.replace(entry, '''
@objc(ParitySceneDelegate) @MainActor final class ParitySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
}
@MainActor final class ParityDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let file = NSHomeDirectory() + "/Documents/{RUN_TOKEN}-" + (legacyMode ? "legacy" : "native") + ".txt"
        guard freopen(file, "w", stdout) != nil else { exit(90) }
        DispatchQueue.main.async {
            runNativeParitySuite()
            guard fflush(stdout) == 0 else { exit(92) }
            guard FileManager.default.createFile(atPath: file + ".complete", contents: Data("PASS".utf8), attributes: nil) else { exit(91) }
            exit(0)
        }
        return true
    }
}
UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(ParityDelegate.self))
''').replace('{RUN_TOKEN}',token)
(out/'source-hashes.json').write_text(json.dumps(hashes,indent=2)+'\n')
(out/'main.swift').write_text(main)
(out/'stub.c').write_text('void UICInstallConstraintClassMethods(void) {}\n')
PY
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
export SDKROOT="$SDK"
TARGET=$(uname -m)-apple-ios15.0-simulator
clang -target "$TARGET" -isysroot "$SDK" -c "$OUT/stub.c" -o "$OUT/stub.o"
clang -target "$TARGET" -isysroot "$SDK" -O2 -ffp-contract=off -c "$VENDOR/CassowaryC/CassowaryC.c" -o "$OUT/CassowaryC.o"
clang -target "$TARGET" -isysroot "$SDK" -fobjc-arc -O2 -c "$VENDOR/Runtime/UICLabelPreferredWidth.m" -o "$OUT/label-preferred-width.o"
NATIVE_OBJECTS=("$OUT/label-preferred-width.o")
for SOURCE in "$VENDOR/NSISC/"*.c; do
  OBJECT="$OUT/nsis-$(basename "$SOURCE" .c).o"
  clang -target "$TARGET" -isysroot "$SDK" -O2 -ffp-contract=off -I"$VENDOR/NSISC" -c "$SOURCE" -o "$OBJECT"
  NATIVE_OBJECTS+=("$OBJECT")
done
xcrun swiftc -swift-version 5 -target "$TARGET" -sdk "$SDK" -O \
  "$OUT"/src/*.swift "$OUT/main.swift" "$OUT/stub.o" "$OUT/CassowaryC.o" "${NATIVE_OBJECTS[@]}" -o "$OUT/simrun" > "$OUT/build.log" 2>&1
if [[ "${LSDK_LAYOUT_FIXTURE:-direct-update}" == native-parity ]]; then
  python3 - "$OUT" <<'APP'
import plistlib,shutil,sys
from pathlib import Path
out=Path(sys.argv[1]);app=out/'NativeParity.app';app.mkdir()
shutil.copy2(out/'simrun',app/'ParityProbe')
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'ParityProbe','CFBundleIdentifier':'org.jwi.lsdk.nativeparity','CFBundleName':'NativeParity','CFBundlePackageType':'APPL','CFBundleVersion':'1','CFBundleShortVersionString':'1.0','MinimumOSVersion':'15.0','CFBundleSupportedPlatforms':['iPhoneSimulator'],'UIDeviceFamily':[1,2],'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Parity','UISceneDelegateClassName':'ParitySceneDelegate'}]}}}))
APP
  codesign --sign - "$OUT/NativeParity.app" > "$OUT/sign.log" 2>&1
  xcrun simctl install "$UDID" "$OUT/NativeParity.app"
  TOKEN=$(<"$OUT/run-token.txt")
  for MODE in native legacy; do
    xcrun simctl launch --console --terminate-running-process "$UDID" org.jwi.lsdk.nativeparity "$MODE" > "$OUT/$MODE-launch.log" 2>&1
    CONTAINER=$(xcrun simctl get_app_container "$UDID" org.jwi.lsdk.nativeparity data)
    python3 - "$CONTAINER/Documents/$TOKEN-$MODE.txt.complete" <<'VERIFY'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_text()=='PASS', 'suite did not complete'
VERIFY
    cp "$CONTAINER/Documents/$TOKEN-$MODE.txt" "$OUT/$MODE.txt"
  done
  python3 - "$OUT" <<'CASES'
from pathlib import Path
import sys
out=Path(sys.argv[1])
required={'settled','text-viewport-320','text-content-320','text-viewport-240','text-content-240','text-viewport-400','text-content-400','owned-progress-320','owned-progress-240','owned-progress-400','owned-slider-320','owned-button-320','owned-field-320','owned-label-320','geometry-setters','geometry-setter-calls'}
for mode in ('native','legacy'):
 seen={line.split('\t',1)[0] for line in (out/(mode+'.txt')).read_text().splitlines()}
 assert required <= seen, (mode, 'missing cases', required-seen)
CASES
  diff -u "$OUT/native.txt" "$OUT/legacy.txt" > "$OUT/native.diff"
  printf 'PASS: native/backport frame parity; evidence in %s\n' "$OUT"
else
  xcrun simctl spawn "$UDID" "$OUT/simrun" > "$OUT/run.log" 2>&1
  printf 'PASS: direct-update differential; evidence in %s\n' "$OUT"
fi
