# PST collection runtime: behaviour and performance harness

These files are **not** part of the shipped archive. `build-collection-runtime.sh`
compiles only `*.m` directly inside `vendor/PSTCollectionView`, so this `tests/`
directory is ignored by the device build.

## Why a simulator harness

The runtime is compiled for `armv7-apple-ios5.0` and can only execute on an iOS 5
device, so the behavioural comparison compiles the *same* Objective-C sources for
the iOS simulator and runs them with `simctl spawn`. Geometry (visible index
paths, cell centres/sizes, content size/offset) is recorded as JSON and compared
byte-for-byte against a golden file recorded from the unmodified sources.

## Running

    vendor/PSTCollectionView/tests/run-collection-perf-tests.sh \
        SRC_DIR OUT_DIR record GOLDEN.json     # (re)record the expected geometry
    vendor/PSTCollectionView/tests/run-collection-perf-tests.sh \
        SRC_DIR OUT_DIR check GOLDEN.json      # verify geometry + print counters

`SRC_DIR` is the vendor directory (or a pristine copy of it); `OUT_DIR` must not
exist; a booted simulator from the active Xcode is required. `record` against a
pristine source copy produces the golden file, `check` against the changed
sources proves the visible cells and frames did not move.

Scenarios cover: initial layout, repeated no-op layout passes, vertical and
horizontal scrolling, reload with unchanged data, item insert/delete/reload
through `performBatchUpdates`, item-size change, section-inset change, multiple
sections with headers/footers, a layout switch, bounds changes, many-section
updates (section-offset bookkeeping), explicit `invalidateLayout` with unchanged
geometry, and a long scroll over 5000 items.

## Counters

`PSTCollectionViewStats.h` exposes an internal, always-compiled counter array and
`PSTCollectionViewStatsRead()` / `PSTCollectionViewStatsReset()`. The harness
resets them per scenario and prints a table. Counters are incremented by a plain
non-atomic `uint64_t++` on the paths they measure; they do not affect layout.

Set `LEGACY_PST_STATS=1` to print a summary line at process exit (with `simctl`
spawn the child process inherits `SIMCTL_CHILD_LEGACY_PST_STATS=1`). Counters are
not reset automatically, so with the harness they reflect the last scenario.

Counter meanings:

| counter | meaning |
| --- | --- |
| `passes`, `passesSkipped` | `updateVisibleCellsNow:` calls; skipped ones short-circuited because the attribute generation and bounds were unchanged |
| `visibleCellsCreated` | cells obtained from the data source |
| `attributesComputed` | `PSTCollectionViewLayoutAttributes` objects manufactured by a layout |
| `elementScans` | `layoutAttributesForElementsInRect:` calls made by the data cache |
| `itemDerivations` | fresh single-item attribute derivations by a layout |
| `itemDerivationsCached` | single-item lookups served from a per-pass fetch (cell creation, diffs, updates) |
| `layoutPreparations`, `layoutPreparationReuses` | flow-layout `prepareLayout` rebuilds vs. prepared-generation reuse |
| `itemCountScanSteps` | per-section linear steps removed by the prefix sums |
| `dataValidations`, `dataRefilters` | `validateLayoutInRect:` calls; ones that actually re-queried the layout |
| `visibleAttributeApplications` | per-visible-view `applyLayoutAttributes:` calls that still changed something |
| `layoutAttributeDiffs` | old/new layout interchange entries built by a layout switch |
| `layoutPassNanoseconds` | wall time inside `updateVisibleCellsNow:` (min of repeated runs is used for reporting; simulator timing is noisy) |

## Native UIKit reference measurement

The same harness also runs each performance scenario twice with identical
geometry: once through UIKit's `UICollectionView` + `UICollectionViewFlowLayout`
and once through `PSTCollectionView` + `PSTCollectionViewFlowLayout` (both built
for the simulator). Only the layout path is timed: a sample is the sum of the
layout passes a scenario triggers; collection-view creation, warm-up passes and
harness setup are outside the measured region. Each engine gets fresh
repetitions, and min/median are reported (`nativeReference` in the JSON output,
printed by the runner). The behavioural golden comparison only uses the
`scenarios` key, so the 14-scenario golden stays byte-identical.

Scenarios (200 items unless stated, 320x568, 50x50, 10/10, 5pt inset):
cold layout, eight idle passes, ten scroll steps, `reloadData`, batch
insert+delete, item-size change, bounds change, multi-section cold and scroll
(4x50 with 24/16 headers/footers).

Representative result (simulator, median of three harness runs; ratio =
PST/native, lower is better):

| scenario | native us | PST before | ratio | PST after | ratio |
| --- | ---: | ---: | ---: | ---: | ---: |
| cold-200 | 536.5 | 805.4 | 1.35 | 678.4 | 1.26 |
| idle-x8-200 | 74.4 | 75.0 | 0.97 | 72.6 | 0.98 |
| scroll-x10-200 | 1302.8 | 1133.7 | 0.85 | 1032.5 | 0.79 |
| reload-200 | 585.4 | 968.9 | 1.61 | 802.8 | 1.37 |
| batch-insert-delete-200 | 437.5 | 701.8 | 1.58 | 650.7 | 1.49 |
| item-size-200 | 208.8 | 286.1 | 1.46 | 276.1 | 1.32 |
| bounds-200 | 405.0 | 504.8 | 1.24 | 450.0 | 1.11 |
| multi-section-cold-200 | 499.8 | 767.6 | 1.51 | 657.2 | 1.31 |
| multi-section-scroll-x6-200 | 1055.5 | 971.3 | 0.91 | 866.6 | 0.82 |

"Before" is the state before this comparison round; the reduction came from
removing three profile-visible redundancies: an unused menu gesture recogniser
created for every cell, an O(subviews) scan/copy in `addControlledSubview:` for
layouts without floating views, and per-property CoreAnimation writes in
`applyLayoutAttributes:` whose values were already correct.

PST is now between 0.79x and 1.49x of native: faster on both scroll scenarios
and effectively equal when idle, and 1.1x-1.5x slower on the cold/update paths.
That residual is structural rather than redundant work: a PST cell composes and
inserts its own `backgroundView`/`contentView` (`UICollectionViewCell` gets
UIKit's private, lazier setup and a tuned reuse path), PST still pays ObjC
message/dictionary costs where UIKit has private fast paths, and the batch-update
machinery builds the old/new index maps and per-view animation dictionaries in
ObjC. The native collection view also keeps extra prefetched cell views during
scrolling, so the PST scroll numbers are comparatively conservative.

Note: this is a simulator proxy, not iOS 5 hardware. The behavioural counters
(`counters`) are the hardware-independent work metric; the timing ratio is for
the native-reference comparison.
