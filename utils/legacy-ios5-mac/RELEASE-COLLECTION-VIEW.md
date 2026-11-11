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
