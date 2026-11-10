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
* `windowScene(_:didUpdateCoordinateSpace:interfaceOrientation:traitCollection:)` is delivered on orientation change
  (verified: iPod 5.1.1 via a runtime-added method; iPhone 6 at an iOS 10 deployment, with real `UITraitCollection`).
  Below an iOS 8 deployment the method cannot be declared in Swift (needs `UITraitCollection`); an Objective-C or
  runtime-added implementation works. Native fires it repeatedly during launch; the backport fires only on a real
  orientation change, so launch-time call counts differ.
* armv7s: built, not run.
* The simulator's URL-while-backgrounded run did not reach the probe, so URL ordering around activation is unverified against it.
* Not exercised: sceneDidDisconnect, state restoration, shortcut items, storyboard scene windows,
  requestSceneSession* calls, multiple scenes (always reports unsupported, as an iPhone does natively).
* Probe apps were installed as system apps (/Applications) on jailbroken devices, not as sandboxed user apps.

## UITraitCollection (iOS 8) — `Runtime/UICTraitCollection.m`
Registered only when UIKit lacks the class (iOS < 8). Oracle: iOS 27 simulator.
* Verified on the iPod (iOS 5.1.1): unspecified defaults, per-trait factories, later-wins merge, `containsTraitsInCollection:`,
  equality/hash/copy, descriptions, secure coding round trip, enum values, screen/window/view-controller/subview/child-override
  resolution (iPhone/iPod: compact width, regular height portrait, compact height landscape), override readback, and
  `traitCollectionDidChange:` on rotation (controller + view).
* Not replicated: `currentTraitCollection`/`performAsCurrentTraitCollection:`, dynamic appearance, image configuration,
  `traitCollectionWithTraits:`/`ByModifyingTraits:`, and Apple's private traits (image dynamic range, HDR headroom, scene capture).
* Not run on: iPhone 6, armv7s. Screen values come from the device (scale 1, sRGB on the iPod) so they differ from the simulator's.
