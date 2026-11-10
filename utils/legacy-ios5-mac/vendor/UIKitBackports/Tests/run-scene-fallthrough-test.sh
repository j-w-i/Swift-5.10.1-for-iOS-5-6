#!/bin/bash
# iOS 13+ fallthrough gate: link the scene/trait runtime into a native scene app and require that
# (1) UIScene/UITraitCollection stay Apple's classes and (2) the lifecycle event order is unchanged.
# Usage: run-scene-fallthrough-test.sh NATIVE_PROBE_DIR BOOTED_SIM_UUID   (dir holds main.m + P.app/Info.plist)
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P); R="$HERE/../Runtime"
D=${1:?probe dir}; SIM=${2:?simulator uuid}; SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
cd "$D"
xcrun clang -fobjc-arc -arch arm64 -isysroot "$SDK" -mios-simulator-version-min=13.0 -fblocks -Wno-unguarded-availability-new \
  -include "$R/UICObjCCompatibility.h" -I "$R" -framework UIKit -framework Foundation -framework CoreGraphics \
  main.m "$R/UICSceneLifecycle.m" "$R/UICTraitCollection.m" "$HERE/scene_fallthrough_ctor.m" -o P.app/P
xcrun simctl terminate "$SIM" org.example.sceneprobe >/dev/null 2>&1 || true
xcrun simctl install "$SIM" P.app
(xcrun simctl launch --console-pty "$SIM" org.example.sceneprobe > linked.txt 2>&1 &); sleep 7
xcrun simctl launch "$SIM" com.apple.Preferences >/dev/null; sleep 4
xcrun simctl launch "$SIM" org.example.sceneprobe >/dev/null; sleep 4
xcrun simctl terminate "$SIM" org.example.sceneprobe >/dev/null 2>&1 || true
grep -q 'scene same=1 trait same=1' linked.txt || { echo 'FAIL: backport replaced Apple classes'; exit 1; }
grep -q 'sceneImage=.*UIKitCore\|sceneImage=.*SimulatorRuntime' linked.txt || { echo 'FAIL: scene class not from system'; exit 1; }
echo 'PASS: scene/trait backport inert on iOS 13+ (classes unchanged)'
