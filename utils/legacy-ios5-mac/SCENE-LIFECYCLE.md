# UIScene lifecycle backport (iOS 5 – 12)

Compile time: the iOS 13 scene declarations (and the iOS 14/15 members the runtime implements) are
lowered to the deployment target only below iOS 13 (`lib/ClangImporter/ImportDecl.cpp`,
`ClangIncludePaths.cpp`). The classes are runtime-only foreign classes resolved by name; notification
and role constants bind to `SwiftLegacy…` copies. `NSUserActivity` (iOS 8) is supplied the same way.

Run time: `vendor/UIKitBackports/Runtime/UICSceneLifecycle.m` registers each class **only when UIKit lacks
it** and drives launch / foreground / background / URL / user-activity delivery from the
`UIApplicationSceneManifest` in Info.plist. On iOS 13+ nothing is registered or driven.

## Verified (oracle = iOS 27 simulator UIKit)
* Lifecycle + notification order: launch, activate, resign, background, foreground — event names match.
* Descriptions/equality/copy/secure coding of UISceneConfiguration and UISceneActivationConditions.
* Public method surface of the scene classes (private Apple-only methods are not replicated).
* iPod touch 3 (iOS 5.1.1, armv7): full launch + background/foreground + URL delivery.
* iPhone 6 (iOS 10.3.3, arm64): launch, resign, background, foreground, activate, and URL delivery on return.
* Scene-request errors (`UISceneErrorDomain` code 0, "does not support multiple scenes"), `supportsMultipleScenes`, defaults of
  `activationConditions`/`userInfo`/`stateRestorationActivity` match the simulator (iPod).
* Layout gates (native-parity, direct stack, first-use) and the TestingAPIs device run pass with this build.

## Known differences / not verified
* `windowScene(_:didUpdateCoordinateSpace:…)` cannot be written in Swift below iOS 8 (UITraitCollection);
  the runtime sends it with nil traits and it was not observed firing. Native fires it repeatedly at launch.
* iPhone 6: rotation not run. armv7s: built, not run.
* The simulator's URL-while-backgrounded run did not reach the probe, so URL ordering around activation is unverified against it.
* Not exercised: sceneDidDisconnect, state restoration, shortcut items, storyboard scene windows,
  requestSceneSession* calls, multiple scenes (always reports unsupported, as an iPhone does natively).
* Probe apps were installed as system apps (/Applications) on jailbroken devices, not as sandboxed user apps.
