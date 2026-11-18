# Toolchain-native UIKit backports: scope

The legacy iOS 5 toolchain exposes backported UIKit APIs as **part of `import UIKit`**,
not as a package a project must depend on. This file records which APIs qualify and how
version gating works.

## Included (API, not convenience)

| Family | Native availability | Backport provides |
|---|---|---|
| Auto Layout | iOS 6 (constraints); `UILayoutGuide` iOS 9 | Cassowary-based engine, `NSLayoutConstraint` (incl. VFL), `UIView` constraint members and anchors, `NSLayoutConstraint.activate`/`deactivate`, `UILayoutGuide` (+ `addLayoutGuide`, `layoutMarginsGuide`) |
| `UIStackView` | iOS 9 | stack view implementation with the documented iOS 9 API |
| Refresh control | iOS 6 | `UIRefreshControl` and `UIScrollView.refreshControl` |
| Compositional layout | iOS 13 | `UICollectionViewCompositionalLayout`(+`Configuration`), `NSCollectionLayout*` types, `NSDirectionalEdgeInsets`, orthogonal scrolling behaviour |
| Appearance containment | iOS 9 (`+appearanceWhenContainedInInstancesOfClasses:`) | the array form on `UIView` and `UIBarItem`, forwarded to UIKit's own variadic `+appearanceWhenContainedIn:` (iOS 5), which Swift cannot call: same proxy objects, same validation. Up to 15 container classes. The trait-collection forms stay native |

## Older API on legacy targets

On a legacy target (`-enable-legacy-ios5-runtime`, iOS 5..10, every slice):

* APIs deprecated in iOS 7 or earlier are available. Stock Swift makes them unavailable
  ("APIs deprecated as of iOS 7 and earlier are unavailable in Swift"), but on these systems they
  are the current API: `sizeWithFont:`, `drawInRect:withFont:`, `contentSizeForViewInPopover`,
  `AudioSessionSetProperty`, `useApplicationAudioSession` and the rest. They warn only from their
  deprecating version on (e.g. on the iOS 7 arm64 slice, not on the iOS 5 armv7 slice). Swift names
  of other declarations do not change.
* `NSTextAlignment`, `NSLineBreakMode` and `NSWritingDirection` (iOS 6 names of `UITextAlignment`,
  `UILineBreakMode` and `UITextWritingDirection`, same raw values) can be used in Swift signatures
  at iOS 5. `NSTextAlignment.justified` and `.natural` stay iOS 6.

Swift 5.10 crashed (SILGen or IRGen; also upstream 5.10.1) when a module both defines a C symbol
with `@_cdecl` and calls it through a bridging-header declaration whose Swift type differs, as with
`BOOL` (`Bool` on arm64) against an `ObjCBool` definition. The call now references the module's
definition and uses the header's signature, as Swift 6 does.

## Dispatch handles in C and Objective-C APIs

Stock Swift imports `dispatch_queue_t` as `DispatchQueue` because, from iOS 6, the Objective-C class
`OS_dispatch_queue` *is* `DispatchQueue`. The legacy Dispatch overlay wraps the handle in a Swift class
on every slice (iOS 5 has no dispatch classes), so the toolchain bridges instead. With
`-enable-legacy-ios5-runtime`, on every slice:

* `dispatch_queue_t`, `dispatch_group_t`, `dispatch_semaphore_t`, `dispatch_source_t` and `dispatch_io_t`
  in C function and Objective-C method parameters and results, properties (including the iOS 5
  `assign` form) and block parameters import as `DispatchQueue`, `DispatchGroup`, `DispatchSemaphore`,
  `DispatchSource` and `DispatchIO`, converted at the call. Argument labels are the same on every slice
  (`run(on:group:block:)` for `runOnQueue:group:block:`).
* A handle coming from Objective-C gets a wrapper that holds its own reference, so it stays valid
  after the Objective-C side releases it. A handle passed to Objective-C is borrowed for the call, as in
  Objective-C itself: a setter that keeps it must retain it (on iOS 5, `dispatch_retain`).
* Wrappers are not unique per handle: two reads of the same property give two `DispatchQueue` objects
  for one queue, so `===` compares wrappers, not queues.
* Struct fields keep the raw handle. libdispatch's own C functions (`dispatch_sync` and the rest) are
  unchanged: use the overlay's methods (`queue.sync { }`, `.sync(flags: .barrier)`, and so on).
* Swift classes cannot yet override Objective-C methods or implement `@objc` protocol requirements
  whose signatures contain dispatch handles.

## Excluded

* `UIFont` weight helpers and `UIFont.systemFont(ofSize:weight:)` — excluded by the user.
* `UIButton` inset/background helpers — excluded by the user.
* `UIVisualEffectView` / `UIBlurEffect` / `UIVibrancyEffect` — excluded by the user.
* `DeviceInfo` / `ChipsetClass` — an application utility, not a UIKit API.
* `CGColorShim` — a local helper type, not an API of a newer UIKit.

## Gating rule

For a declaration introduced in iOS `N`, availability is relaxed to the slice's
deployment floor only when:

1. the invocation opts into the legacy runtime (`-enable-legacy-ios5-runtime` on a
   native iOS device target), **and**
2. `N` is at or below the version that family's backport implements.

The floor is iOS 5 for the armv7 slice (which also uses the 32-bit class-marking
ABI) and iOS 7.0 for armv7s/arm64, since 64-bit hardware never ran iOS 5/6 and
keeps the standard Swift ABI. Declarations above a family's ceiling stay
unavailable on every slice, so a program cannot use an API the backport does not
implement.

Members introduced after the family's implemented version stay unavailable, so a
program cannot accidentally use an API the backport does not provide. Compiling for
iOS 6 or newer is untouched: it keeps the SDK's native declarations and availability.

The runtime side follows the same rule: a backport class or method is only installed
when the corresponding native API is absent, so an iOS 5-targeted binary running on a
newer OS behaves like the native API rather than replacing it.

## Runtime shape

Vendored, licensed sources build from the clone; no package dependency and no
client-side linker flags. Implementations are linked into the rebuilt
`libswiftUIKit.dylib`, and the Swift-only surface is compiled into the legacy
`UIKit` overlay module that the iOS 5 resource tree ships. Legacy output is compiled
in ARM instruction mode, because the pinned older linker loses ARM/Thumb interworking
bits on local function pointers.
