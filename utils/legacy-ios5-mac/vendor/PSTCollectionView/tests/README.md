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
