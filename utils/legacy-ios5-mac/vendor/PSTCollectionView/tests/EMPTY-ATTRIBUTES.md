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

## Supplementary and decoration coverage (2026-10-30)

The same harness/runner now also executes an independent mixed custom-layout
scenario with three cells, one supplementary view (tag 101), and one
layout-registered decoration view (tag 201). Both engines share macro-generated
layout/data-source/reusable-view behavior. The original seven-step cell-only
scenario and its assertions remain intact. The mixed scenario runs eleven steps:
initial, empty invalidation, three empty repeats, restoration, restored repeat,
second empty invalidation, empty repeat, second restoration, restored repeat.
Data counts, bounds and content size remain constant throughout.

The version-2 JSON adds `nativeMixed` and `pstMixed`. Each step records cell
public visibility, effective hierarchy-visible supplementary/decoration tags,
actually displayed counts, raw attachment/hidden/alpha observations, creation,
request, end-display and prepare-for-reuse counts. Exact per-step parity is
asserted, including preparation staying unchanged while empty and incrementing
only on restoration. Native oracle assertions require real initial/restored
views, no displayed views while empty, stable original allocation counts, and
one end-display per disappearing cell/supplementary view. Every invalidation must
increase layout-query count on both engines. Two cycles guard against a one-shot
queue coincidence.

API boundaries: PST exposes supplementary registration/dequeue and
`didEndDisplayingSupplementaryView:forElementOfKind:atIndexPath:`, but no public
native-style supplementary visibility enumeration. Therefore the shared reusable
visibility observation traverses public `UIView.subviews`, excluding effectively
hidden/zero-alpha ancestors. The nonoverlapping frames are all within the visible
bounds. Decoration is created via layout registration, not a data-source request;
neither engine exposes a separately named public decoration end-display callback.
Its `requested` field is JSON null, not a fabricated zero count. However, this
iOS 27 native oracle **does dispatch decoration disappearance through the public
supplementary end-display delegate method**, passing the decoration kind and
view. End counts/events are therefore attributed by kind to the appropriate
category, and decoration end parity is strictly asserted too. Raw attachment is
still not asserted: native hidden cache retention is explicitly out of scope.
End callback events capture kind, concrete class, tag, path and prepare count at
callback for diagnosis.

Run with a **new** output directory (the captured evidence below already exists):

```sh
bash /Users/jwalr/Developer/Swift-5.10.1-for-iOS-5-6/utils/legacy-ios5-mac/vendor/PSTCollectionView/tests/run-collection-empty-tests.sh \
  /Users/jwalr/Developer/Swift-5.10.1-for-iOS-5-6/utils/legacy-ios5-mac/vendor/PSTCollectionView \
  /Users/jwalr/Developer/Neocord2-iOS5-Work/device-bridge/bench/collection-reusable-coverage/NEW-RUN \
  0827B93D-F8C3-49C4-9ACF-4A5064843B45
```

Preflight: 108 GiB available; exact simulator was already Booted and available,
iPhone SE (3rd generation), iOS 27.0 / build 24A434. No boot/install/device
configuration or physical-device action was performed. Runtime is commit
`9bcc0734`; before/after runtime checksums match in each run. No runtime source
was changed, and no previous evidence was overwritten.

The first strict run is preserved at `bench/collection-reusable-coverage`
(866,570 artifact bytes, exit 1). All original cell assertions passed. All mixed
visibility, displayed counts, allocations, requests and prepare-for-reuse
comparisons passed for cells, supplementary and decoration, including both
restorations. **Supplementary end-display differs:** native reports two callbacks
per disappearance, PST one (cumulative native/PST 2/1 after the first empty
invalidation and 4/2 after the second). This yields 20 failures: ten native
single-end oracle assertions and ten direct native/PST count comparisons.
Assertions were not weakened and this is not a passing parity qualification.

`callback-diagnostic/result.json` preserves the identity-instrumented replay
(878,559 bytes, same 20 failures). It proves the extra native callback carries
`NativeDecoration`, tag 201 and `empty-regression-decoration`, rather than being
a duplicate for the supplementary view. The final harness attributes end events
by kind without filtering any event or dropping parity assertions.

**Use `kind-attributed/result.json` as final evidence** (877,139 bytes, exit 1,
10 strict comparison failures, zero native oracle failures). Real supplementary
end timing matches exactly (1 then 2). Decoration end timing differs: native
1 then 2, PST always 0. Each of the ten post-initial steps reports that mismatch.
All remaining assertions pass, including initial/empty/restored displayed state,
stable allocations, datasource requests, and preparation counts 0 while first
empty, 1 after first restoration/second empty, 2 after second restoration for
both supplementary and decoration. This is a current iOS 27 public delegate
observation; do not infer an iOS 6 requirement without separate historical
validation. The three preserved runs together occupy about 2.62 MB. The final
source differs from that captured run only in an explanatory API comment.

### Historical validation and fix
A separate bounded iOS 6.1 i386 UIKit analysis confirms decoration keys have
type 2; the visible-removal block routes types 1 and 2 into `_reuseSupplementaryView:`.
That method dispatches the same supplementary end-display callback using the
retiring view's element kind/index path (subject to responder/delegate guards).
Evidence: workspace `ios61-ref/ghidra/collection-decoration-output`.

The backport now emits that callback for retiring decorations before queuing
reuse, preserving the existing per-category reuse queues. Strict green evidence:
`device-bridge/bench/collection-decoration-fix/result.json`, iOS27 build24A434,
zero comparison failures. The red files above remain unchanged. This follow-up
has not yet been deployed into NeoCord2 or separately device-qualified.

## Original cell-only captured evidence (2026-10-30)

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
