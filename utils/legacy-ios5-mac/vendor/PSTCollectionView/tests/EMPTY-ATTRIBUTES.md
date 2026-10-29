# Empty layout-attributes differential regression

`PSTCollectionEmptyAttributesHarness.m` compares native `UICollectionView` with
PST using matching custom layouts, cells, data sources and delegates. Three items
and a 240x240 content size remain constant. Only the layout's attribute output
changes: nonempty, invalidate to `@[]`, three repeated layout passes, invalidate
to restore, repeated restored pass. No reload, batch update, scrolling or animation
is involved. Both engines must re-query their layout after invalidation.

```sh
bash /Users/jwalr/Developer/Swift-5.10.1-for-iOS-5-6/utils/legacy-ios5-mac/vendor/PSTCollectionView/tests/run-collection-empty-tests.sh \
  /Users/jwalr/Developer/Swift-5.10.1-for-iOS-5-6/utils/legacy-ios5-mac/vendor/PSTCollectionView \
  /Users/jwalr/Developer/Neocord2-iOS5-Work/device-bridge/bench/collection-empty/verified-red \
  0827B93D-F8C3-49C4-9ACF-4A5064843B45
```

The output directory must not exist. The runner requires an explicit UUID of an
already booted iOS simulator; it never selects `booted`, installs an app, changes
device settings, boots, shuts down, or erases a device. It uses the existing perf
harness's ARC/arm64 simulator build pattern. Runtime sources are checksummed before
and after execution. Output includes source snapshots, invocation, native OS/build,
UUID, per-step observations and assertion failures, exit status, compile logs,
objects and signed harness (normally under 1 MiB per run).

Assertions compare visible cell tags, actually displayed cell subviews, allocation,
data-source requests and end-display callbacks at every step. Prepare-for-reuse
counts are compared at every step: both engines must defer preparation until
dequeue. Original PST prepared at enqueue; the iOS 6.1 UIKit i386 dequeue dispatch
independently confirms native preparation timing. Raw actual cell-subview counts
and each cell's hidden/alpha state are also
recorded. Native may retain hidden cell subviews for reuse, so raw attachment count
is an observation, **not** a requirement to match a private native caching policy.
Reuse timing is observed, not inferred from visible cells.

This is a current-native simulator oracle, not a claim about native iOS 5 behavior.
The JSON records the native OS version. A red exit is expected on the unchanged
PST source with the early return in `updateVisibleCellsNow:` for empty attributes.
The runtime fix removes the empty-set early return and moves preparation from
enqueue to dequeue for cells, supplementary views and decoration views. Final
strict simulator run: `bench/collection-empty-lifecycle/result.json`, zero
comparison failures. All 14 historical geometry scenarios also pass; this is not
yet real-device or application performance qualification.

## Captured evidence (2026-10-30)

Native: iOS 27.0, Version 27.0 (Build 24A434), requested iPhone SE UUID.
Disk check before work: 108 GiB available.

The initial run in `bench/collection-empty` is preserved, including an overly
strict native raw-subview-zero assertion. Runtime files were unchanged during that
run. Its PSTCollectionView.m SHA-256 is
`bb2ca372d50ec4581c6d08ee74d62f0689bd24bda323fe387a2fd8d3c3c70a15`.

Another agent changed the runtime between the first and second builds. Therefore
`verified-red` is **not unchanged-source evidence**: it observed a different
PSTCollectionView.m hash (`0d63842e...`) and exposed the enqueue/dequeue reuse-timing
difference. Neither run's valuable output was overwritten.

**Use `unchanged-red/result.json` as the corrected red evidence** (exit 1, 18
assertion failures). The final harness was relinked against the initial run's
preserved original runtime object files, not the concurrently changed sources.
That directory includes the final harness source, original runtime hashes and
object checksums. Exact execution:

```sh
xcrun simctl spawn 0827B93D-F8C3-49C4-9ACF-4A5064843B45 \
  /Users/jwalr/Developer/Neocord2-iOS5-Work/device-bridge/bench/collection-empty/unchanged-red/harness \
  /Users/jwalr/Developer/Neocord2-iOS5-Work/device-bridge/bench/collection-empty/unchanged-red/result.json
```

The result path must be new on replay. Empty steps: native visible `[]`, displayed
subviews 0, end-display 3; unchanged PST visible `[1,2,3]`, displayed subviews 3,
end-display 0. Native retains three *hidden* actual subviews. Restore: native
requests 6 and prepares 3 cells for reuse, unchanged PST requests 3 and prepares 0.
The same mismatches persist across repeated layout passes. No native-oracle
sanity assertion fails in this corrected run.
