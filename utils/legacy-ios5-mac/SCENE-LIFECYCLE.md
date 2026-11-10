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
* Verified (iPhone 6): shortcut items reach `windowScene(_:performActionForShortcutItem:completionHandler:)` and the completion handler runs;
  user-activity (`willContinue`) routes to the scene delegate (iPod + iPhone 6). Shortcut items do not exist on iOS 5 (class absent).
* State restoration: `stateRestorationActivityForScene:` is requested twice before `sceneDidEnterBackground:` and
  `restoreInteractionState…` is delivered on every foreground entry, in the native order (iPod).
* Not exercised: sceneDidDisconnect (the simulator did not send it either when the app was killed), storyboard scene windows (NOT verified: the Kit's Xcode 13.4.1/27 `ibtool` only emits the modern compiled-storyboard layout, which iOS 5's
  `UIStoryboard` rejects — "no valid compiled storyboard" — so a storyboard scene app cannot be built for iOS 5 here; the runtime loads the
  storyboard if present and survives a failed load with an empty window),
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
* iPhone 6 (iOS 10.3.3): Apple's real class is used. It lacks the newer accessors (`userInterfaceStyle`, `accessibilityContrast`,
  `userInterfaceLevel`, `legibilityWeight`, `activeAppearance`), which the runtime adds as "unspecified"; without that, reading them
  from a binary built against the newer SDK raised unrecognized selector and aborted the app at launch (fixed, verified). Merge,
  containment, equality, coding and override behaviour match; description text is iOS 10's own format, and a detached view controller
  reports empty traits there where iOS 27 reports screen traits.
* Not run on armv7s. Screen values come from the device (scale 1, sRGB on the iPod), so they differ from the simulator's.

## Compile-time drop-out (verified from emitted IR)
Scene / trait class references are runtime lookups (`objc_lookUpClass`) only while the deployment target predates the OS
that ships the class (scene classes < 13, `UITraitCollection` < 8). At or above that deployment the compiler links the SDK's own
class directly (`OBJC_CLASS_$_UIWindowScene` at 13.0, `OBJC_CLASS_$_UITraitCollection` at 8.0 and 10.0). Before this check the
trait/scene classes were runtime-only at every deployment — a bug, now fixed.
