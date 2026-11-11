# Collection-view backport: verified release

Modern UICollectionView API backported to iOS 5 on both routes, with native-matching behaviour and native-level
performance. Verified state at the commit this note was added.

## API surface

* `collectionView:willDisplayCell:forItemAtIndexPath:` and `willDisplaySupplementaryView:...` - on PST natively,
  on Apple's `UICollectionView` below iOS 8 by hooking the point UIKit adds a view (present natively from iOS 8).
* `visibleSupplementaryViewsOfKind:` and `indexPathsForVisibleSupplementaryElementsOfKind:` (iOS 9) - added to
  Apple's class only where it lacks them.
* `UICollectionViewDataSourcePrefetching` / `prefetchDataSource` (iOS 10) - same rule.
* Self-sizing: `estimatedItemSize`, `preferredLayoutAttributesFittingAttributes:`, `systemLayoutSizeFitting`
  fitting priorities, `automaticSize`.
* Invalidation contexts (`UICollectionViewLayoutInvalidationContext`, flow subclass) exported from PST so the same
  code compiles on both routes.

## Behaviour

Differential oracle: iOS 27 simulator, 8 layout shapes x 4 steps x 2 (as-is and settled).

* display lifecycle exact: `displays 9 / displayed-before-fit 0` and `8 / 0`, identical to native;
* visible cell frames: **0 of 420 differ**; fitted-item parity 64/64;
* content size: 62 of 64 steps exact; the two that differ are the same known case - native returns placeholder
  attributes for a section it has not laid out, PST returns a real layout for it (documented in COLLECTION-VIEW.md).

## Performance (iPod touch 5, iOS 6.1.3, paired in one process, median of 9)

PST/native ratio across 21 scenarios: **0.08 to 1.00 - never slower than Apple's route**. Cold layout 0.88, reload
0.79, batch 0.50 at 200 items; 0.08-0.49 for the self-sizing scenarios. On the iPod touch 3 (iOS 5.1.1) the
no-delegate path is 149.0 / 16.8 / 148.6 ms at 5,000 items.

## Gates

28 of 28 collection gates, plus the Auto Layout solver suite, the fitting suite and the scene/trait fall-through
gate; strict `armv7-apple-ios5.0` compile with `-Werror=unguarded-availability`.

## Honest limits

1. `willDisplay`/fit ordering matches native; the two content-size steps above remain the only behavioural
   difference, and it is native's placeholder being different from a real layout.
2. The iOS 5 Swift profile resource is **stale** relative to this backport and needs republishing; that requires a
   full armv7 toolchain build (the staged `probes/linked510` for armv7 does not exist on the build machine).
3. The iPhone 6 (iOS 10.3.3) has never been attached, so the native-route no-regression run on it is unrun.
4. Lazy valid-range layout is implemented and gated but not in the live path (three wiring attempts made visible
   frames worse); it is kept for a future large-data case.

## Verification index

Every claim above can be re-produced. Simulator UUID used below: `76900F98-0C28-435C-9D87-D22F54CF13FB`.
Run from `utils/legacy-ios5-mac` unless stated.

| Claim | Command |
| --- | --- |
| Collection gates (28) | `bash vendor/PSTCollectionView/tests/run-*.sh <sim-uuid>` (each file is one gate; `run-selfsizing-layouts-test.sh <sim> "" --gate --fit-parity` for the oracle gate) |
| Display lifecycle parity | `bash vendor/PSTCollectionView/tests/run-selfsizing-display-lifecycle-test.sh <sim> --report` |
| Geometry vs iOS 27 oracle | `bash vendor/PSTCollectionView/tests/run-selfsizing-layouts-test.sh <sim> "" --gate --fit-parity` |
| Auto Layout / fitting / scene | `bash vendor/UIKitBackports/Tests/run-autolayout-tests.sh /tmp/out`, `run-fitting-tests.sh`, `run-scene-fallthrough-test.sh vendor/UIKitBackports/Tests/scene-probe <sim>` |
| Strict iOS 5 compile | `clang -target armv7-apple-ios5.0 -marm -Werror=unguarded-availability -Werror=unguarded-availability-new -fsyntax-only <file>` |
| Apple route on real iOS 6 | `bash vendor/UIKitBackports/Tests/run-apple-route-ios6-device.sh 2227` (device must be awake) |
| PST route on real iOS 5 | build `tests/selfsizing-scaling.m` with `-DTEST_PST=1 -DDEVICE_APP=1`, install on the iPod touch 3 (iproxy 2225) |
| PST vs native, paired | `tests/paired-device-bench` (bench.m twice with per-engine macros, main.m with `-DINSTALL_BACKPORT_HOOKS`), iPod touch 5, device awake |

Device identifiers: iPod touch 5 = `39a2bacad9a5524e7a6a46ae031f1bea6249d2ab` (iproxy 2227), iPod touch 3 =
`c5f61927f79fecf422c6f5800ae456d9ccbf9b83` (iproxy 2225). Devices must be awake: `n2launch` returns 3/6 when the
device is locked, which looks like a crash but is not (see COLLECTION-VIEW.md, rounds 241-244).

## What is not done

1. **Swift profile republish.** The iOS 5 Swift resource in the toolchain predates this backport
   (`check-legacy-swift-resource.py` reports the drift by name). Republishing needs a full armv7 toolchain
   build: `link-overlay-stage.sh` wants `probes/linked510` for armv7 and a Swift 5.1.5 `build/runtime-ios5`, and
   neither exists on the build machine (only an arm64 stage does).
2. **iPhone 6 (iOS 10.3.3).** Never attached in this session - only the two iPods are present - so the native-route
   no-regression run is unrun.
