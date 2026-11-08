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
