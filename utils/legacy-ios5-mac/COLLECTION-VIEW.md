# Toolchain-native UIKit collection views on iOS 5

## Preferred-size context staging implemented (round 162)

The flow layout's preferred-attributes factory now performs the staged update native was observed to do:
record the reported size for the item (so this item's attributes show it immediately), stage it into
packed storage without moving any row, name every item from that one to the end of its section as
invalidated, and publish the section-estimate content size (`ceil(count/perRow) * (tallestFirstRow +
interstice) - interstice + margins + header + footer`) through `collectionViewContentSize` until the next
`prepareLayout`. Context flags stay both NO, adjustments stay zero. Named invalidation now forces a rebuild
from retained sizes rather than keeping geometry, so the applied context settles to the same frames and
content size as iOS 27.

The previously failing strict `run-preferred-context-geometry-test.sh` **now passes**, matching native for
`changed=0` and `changed=1`: flags, adjustments, invalidated paths 0-19, staged item size 60 with unchanged
neighbour rows, content height 1200 before and after application, and the view's cached 800. All 22 other
gates still pass (14-scenario golden, layouts 31/32, automatic-size, batch-insert 9/9, prefetch, centering,
stability, proposal, display order, hidden items, cell resize, attribute snapshot, bounds, updates, delegate,
invalidation context/predicate/execution/flow-flags/cache, 240 packed updates), and the strict
`-Werror=unguarded-availability` armv7 iOS 5 runtime archive builds.

Not done: the display lifecycle gate still fails (PST sends `willDisplayCell` before fitting, 9/9 and 10/10
against native 0), because cell preparation still uses the older measuring scheduler. The context path is
now native-accurate but is not yet what drives ordinary cell display. Performance unchanged and unmeasured
on hardware this round.

## Preferred flow context flags (round 161)

Flow now overrides the preferred-attributes factory to turn off both attribute/metric rebuild flags,
preserving dynamic context-class selection via the base factory. The unchanged/unprepared case is verified
against native alongside context factories and all 15 predicates. Named-item/flag execution tests still pass.
Changed-size state mutation, pending adjustments and valid-range path accumulation remain missing, so the
strict preferred-context geometry test still fails. This is not a completed preferred-size context path.

## Packed cross-axis section reflow (round 160)

Added a general packed-item reflow fallback when the fast scrolling-axis-only update rejects a cross-axis
change. It uses retained item sizes to recompute this section's row membership, preserving the section's
absolute origin, then propagates its extent delta through later sections. No data-source query is involved.
It currently rebuilds the entire affected section (not a lazy valid-range suffix) and reallocates row arrays;
therefore this is a correctness fallback, not an Apple-performance claim. Extended tests to 60 cross-axis
updates that grow/shrink row membership across three sections on both axes, now comparing every item frame
as well as row/section/footer/content geometry. All 240 cases match full rebuilds; strict iOS 5 availability
syntax checks pass. This path is still not connected to preferred contexts/cell preparation.

## Strict runtime archive build (round 159)

Ran the actual source runtime builder, including -Werror=unguarded-availability, rather than the looser
syntax checks used in recent rounds. It failed on five NSIndexPath.item accesses from the earlier
proposal/sizing work (SDK marks them iOS 6+). Replaced them with the equivalent iOS-5-available row accessor;
availability checking was not disabled. The complete armv7 iOS 5 archive and generated headers now build,
and nm confirms both new context class definitions are in the archive. The 180-case packed-update test
still passes. This is source/archive qualification only; no installed toolchain or release was updated.

## Generated context class linkage (round 158)

The source runtime builder discovers all .m files, including the new context implementation. But the header
generator's explicit runtime-name list omitted both context classes, exposing UIKit source names that would
link against absent native classes on iOS 5. Added both mappings and a generated-header compilation test:
armv7 object undefined symbols now reference only PSTCollectionViewLayoutInvalidationContext and
PSTCollectionViewFlowLayoutInvalidationContext, not the native UIKit classes. This verifies Objective-C
header/object linkage only, not Swift availability lowering, installed-toolchain integration or a device run.

## Packed size staging versus row recomputation (round 157)

Split packed size storage from row recomputation. `stagePackedItemAtIndex:size:` updates only the size,
preserving its origin, all other item frames, row frames, footer and section extent. The existing incremental
update calls the staging operation then recomputes the row. Tests now assert that entire before/after
boundary for 120 single-section updates, then compare the committed result with rebuilds; all 180 total
updates still pass. This matches the reference's separation of item-size recording and later row validation
structurally, but it is not yet flow-context integration or proof of native lazy-layout parity.

## Preferred-context staging probe (round 156)

New strict differential probe prepares 20 estimated 200x40 items, clears pending preparation adjustments
using a preserving context, then directly creates a preferred-size context for item 0 with height 60.
Native context flags are both NO, adjustment zero, and invalidated paths include 0-19. Before applying it,
item 0 reports height 60 while items 1-4 still have cached y origins 40/80/120/160 and heights 40; layout
content height already estimates 1200 while the view retains 800. After application/validation items 1 and
2 become y=60/120, h=60, but the view still reports cached content height 800. The unchanged-size case
returns an empty, both-flags-NO context. Without explicitly clearing pending initial adjustments, context
creation also carries the original 800-point preparation adjustment; that was isolated rather than mistaken
for this item's delta. This is a direct API probe, not an ordinary cell-fitting transaction.

PST currently fails this strict test because it inherits the base factory without flow side effects.
The result shows that immediately shifting all later item frames using the new packed update primitive
would not reproduce native's staged attribute-cache behaviour. No runtime shortcut was added.

## Incremental section propagation (round 155)

The layout-info layer now routes a packed scrolling-axis size update into its section, shifts every later
section by the returned delta and updates only the scrolling-axis content extent. Invalid section/item or
cross-axis updates are rejected. Extended rebuild-equivalence testing to 60 further updates across three
sections on both axes, comparing content extent, all section/footer frames and all row frames; 180 total
updates pass, as does armv7 syntax checking. This operation is not connected to flow contexts yet. Work is
still proportional to later rows/sections; this does not claim Apple's lazy valid-range complexity or a
new performance measurement.

## Incremental packed row-size primitive (round 154)

Added a section operation for a positive finite scrolling-axis-only item-size change: update the item's
size, recompute its row's extent/centering, shift later row origins and footer by the delta, and update
section extent. It rejects cross-axis changes, invalid indices and unprepared/non-packed sections without
changing them; those require a reflow operation not yet implemented. It allocates no row/item storage.
A 120-update test (growth and shrinkage on both axes, 1-3 columns, 31 items, headers/footers/insets/spacing)
compares every item frame, row frame, footer, section size and delta with a full rebuild after each update.
All match, and armv7 syntax checks pass. This is an internal consistency test, not native differential
parity. It is not yet called by flow layout; lazy valid-range computation, proposal updates, cross-row
reflow and later-section shifting still need implementation before replacing self-sizing execution.

## Separate content-size cache validity (round 153)

The iOS 8.1 collection-data reference has independent content-size and preparation validity bits:
`_prepareToLoadData` can prepare without rereading a valid content size; item invalidation clears cached item
attributes without invalidating that size. PST had an unused contentSizeIsValid bit and unconditionally
read size during preparation. It now uses the separate bit. Named-path contexts preserve content-size
validity, ordinary contexts invalidate it, and full/count invalidation clears it. This is a general cache
state distinction, not a special-case constant or exception for the observed 320-point result.

The previously failing `--named-items` differential now passes, including all metric query paths and item
frames. Base context/adjustment, geometry-cache, self-sizing stability tests and all 14 geometry-golden cases
pass. More complex mixed-context/adjustment cases still need coverage; item attributes currently refresh as
one visible set rather than individual cached global items. The self-sizing execution path remains unchanged.

## Named item contexts: unresolved content-size cache difference (round 152)

Extended the flag probe to invalidate item 0 explicitly. With both flags YES, native and PST both re-query
all eight delegate sizes (paths 0 through 7), change item 0 height to 60 and item 1 origin to 60. But native
reports content height 320 after the pass while PST reports 480. Without a named item both report 480.
The other named-item flag combinations match. This is retained as strict `--named-items` mode on the flow
context test, currently failing, not patched with a guessed content-size exception. Default six-case mode
continues to pass. It demonstrates a data-cache/context interaction still missing from the implementation;
it does not establish that native permanently retains the old content size or that only one item's size
is re-queried. No runtime change made for this finding.

## Coalesced flow invalidation (round 151)

Extended the flag differential test to queue a metrics-rebuild context and a geometry-preserving context in
both orders before preparation. It exposed a bug introduced in round 150: a later preserving context erased
the pending metrics rebuild (height stayed 40 instead of native's 60). Pending metric requirements now
accumulate until preparation, and a weak context cannot cancel them or a pre-existing dirty layout.
Both orders and the four single-context cases match native; base context execution also remains passing.
This fixes coalescing in the new context path only, not the older self-sizing lifecycle or incremental rows.

## Flow-context delegate metrics (round 150)

Flow now rejects non-flow contexts and distinguishes contexts requesting a delegate-metrics rebuild from
contexts retaining current geometry. A new native differential case changes a delegate's item height from
40 to 60 after layout and tests all four attribute/metric flag combinations. Only both flags YES queries
the delegate again and changes content height 320 to 480; all other combinations keep height 40 and content
320. PST matches those four cases, and the existing self-sizing stability gate passes. This is deliberately
limited evidence: attribute-only recomputation of already stored rows, invalidated item-path handling,
coalesced contexts, and preferred-size incremental updates are not implemented/verified by these cases.
The current retained-geometry path is not yet the complete native flow invalidation algorithm.

## Context adjustment timing (round 149)

Base context execution now applies explicit content-size and offset deltas synchronously, before the next
layout. Native differential verification: offset 50 plus 7 immediately becomes 57; content height 400 plus
20 immediately becomes 420, then returns to the layout's authoritative 400 after preparation. Repeated
positive/negative vertical adjustments also match. A separate strict `--cross-axis` test exposes a remaining
clamping difference with undersized content: native clamps a repeated negative x adjustment to 0 while PST
reports -3 immediately (both settle to 0). This mode intentionally fails; no failure allowance. The new
path is not used by the existing self-sizing scheduler. Context execution is still incomplete.

## Base context execution (round 148)

Added the base layout's context invalidation entry point and a cache operation that preserves data-source
counts while marking preparation invalid. A native differential test with a custom layout verifies both empty
and item-path contexts: prepareLayout runs again, item counts are not queried again. Full/count-invalidating
contexts use the existing full cache invalidation. The geometry-only primitive's test also remains passing.
This is limited base execution: content adjustment application and flow-specific invalidation flags/geometry
are not handled yet; callers must not treat the context API as complete. Existing self-sizing still uses
its old private invalidation path. The new entry point does not resolve the lifecycle parity failure.

## Geometry-only collection data invalidation primitive (round 147)

Added an internal `invalidateLayoutAttributes` operation distinct from the existing full invalidation.
It discards the valid attribute rect and reads the layout's updated content size, while preserving item
counts and layout-prepared state. A counter-based test verifies unchanged count queries/preparation,
exactly one new attribute query and generation increment on the next validation of the same rect, updated
content/frame size, and no repeat query on a second validation. It passes simulator execution and armv7
syntax checks. This primitive assumes the layout has already updated its geometry; it does not implement
incremental geometry, consume a public context, or alter existing runtime paths yet.

## Context factory dispatch (round 146)

The base layout now provides `+invalidationContextClass` and the preferred-attributes context factory; flow
layout selects its flow context class. The base factory creates a fresh instance using the dynamic layout
class, preserving subclass context overrides. A differential test confirms base/flow class selection, a custom
layout's custom context, fresh identity and initially empty paths, alongside the 15 predicate cases. Legacy
armv7 syntax checks pass (existing nullability warnings). Flow's size-changing context side effects are not
implemented by this base factory; incremental geometry and execution remain pending. No lifecycle fix claimed.

## Invalidation context data objects (round 145)

Added independent PST base and flow invalidation-context objects. Differential output against iOS 27 agrees
for initially nil item/supplementary/decoration path collections, duplicate elimination across repeated calls,
separate supplementary/decoration kinds, zero/default and assigned content adjustments, and flow flags
(default YES, individually mutable). The new source also passes armv7 iOS 5 syntax checking. This is the
context's storage contract only; layout execution, Swift lowering and native-route missing class installation
are not connected yet. No existing layout path uses these objects, and the lifecycle gate still fails.

## Preferred-attributes predicate API (round 144)

Added `shouldInvalidateLayoutForPreferredLayoutAttributes:withOriginalAttributes:` to PST's base layout
and flow layout, independently implementing the default behaviour read from the iOS 8.1 reference and
verified against iOS 27. The base layout always returns NO. Flow layout returns YES only when self-sizing
is enabled and width or height differs; origin and alpha changes alone do not invalidate. All 15 cases
(base layout, fixed flow, estimated flow × unchanged, height, width, origin, alpha) match the oracle.
This adds the predicate only: the invalidation context API and collection-view integration remain missing.
It does not fix the failing self-sizing display lifecycle gate and has not yet been added to the Apple
route's missing-API hooks or verified through Swift declaration lowering. No performance claim follows.

## Preparation experiment (round 143)

A local experiment moved fitting into PST cell preparation, recorded its answer and invalidated there,
using the existing layout machinery. It eliminated display-before-fit (0 in both cases) and passed the
existing stability test, but still produced 10 display callbacks against native's 8 for changed sizes.
The experiment was reverted rather than shipping a partial lifecycle fix. It demonstrates that synchronous
fitting must be paired with correct invalidation/data-cache handling; it is not sufficient by itself.
The lifecycle gate now requires display counts to match the oracle as well as fitting before display.
No runtime changes from this experiment remain.

## Current parity correction: self-sizing before display (round 142)

The earlier passing display-event tests used fixed-size cells. They did not establish self-sizing lifecycle
parity. The new `tests/run-selfsizing-display-lifecycle-test.sh SIM [--report|--gate]` tests each cell instance
across initial layout, scroll and reload, both when its preferred size equals its estimate and when it changes.
On iOS 27, no tested cell reaches `willDisplayCell` before its fitting callback. Current PST does:

| Preferred size | Native displays / before fit | PST displays / before fit |
| --- | ---: | ---: |
| Equal to estimate | 9 / 0 | 9 / 9 |
| Changes height from 40 to 60 | 8 / 0 | 10 / 10 |

This is externally observable behaviour, including excess display callbacks, not merely a private ordering
difference. The report mode records the known mismatch; `--gate` fails until it is corrected. No allowance
for a number of failures is built into the gate. The Apple hook route has not yet run this new probe.

The iOS 8.1 reference supports the same ordering: cell creation asks for preferred attributes, invokes the
layout's invalidation predicate/context, and invalidates before applying attributes and sending display.
Tracing further shows the collection view queues invalidated item paths, marks visible cells for update and
schedules layout. This does not prove that iOS 27 uses an identical internal algorithm, or that a hook is
incapable of an efficient solution. Earlier categorical statements to that effect were stronger than the
evidence. Incremental invalidation, reuse of unaffected layout data and fit-before-display are confirmed
reference behaviours to implement and test; the precise work bounds and remaining layout mathematics still
need analysis. No runtime behaviour was changed in this round.

`import UIKit` exposes collection views under their ordinary UIKit names in
legacy iOS 5 device builds. No PST import, package dependency, bridging header,
collection-specific include path or project linker setting is required.

## Compiler and runtime

The Clang importer constructs an in-memory UIKit header overlay when the actual
Clang target is an iOS 5 device and `-enable-legacy-ios5-runtime` is enabled.
It retains UIKit as the owning module and adapts collection-view runtime names
and iOS 6 availability for the backport. SDK declarations retain their original
source spelling; a generated declaration resource at
`legacy-collection/Headers/UIKitLegacyCollection.h` supports older SDKs without
collection declarations. The selected SDK is never edited. Missing resources
cause an import error, not a silent fallback to unavailable iOS 6 APIs.

The declarations expose the public UIKit spellings while referring directly to
the backport's Objective-C classes, preserving their actual inheritance hierarchy.
The implementation is compiled from the vendored MIT-licensed PSTCollectionView
sources and included inside the rebuilt `libswiftUIKit.dylib`. Only the internal
overlay build uses an archive force-load; applications do not link a separate
collection archive.

Selection is at compile time: an iOS 5 deployment target uses PST, including when
that binary runs on a newer OS. Compiling for an iOS 6 or newer target leaves the
SDK declarations and native class references unchanged. This intentionally avoids
upstream's dynamically reparented PSUI wrappers: their sibling wrapper classes
do not preserve the UIKit inheritance graph for Swift casts. Native UIKit classes
are never replaced.

This supplies the backported collection-view API, not every collection-view API
added by later iOS releases. Modern APIs still require their own availability
checks or backports. Compiler integration cannot turn an unimplemented API into
an implementation or guarantee absence of runtime errors.

## Rebuilding and checking

The `overlays` stage of `build-all.sh` builds the vendored Objective-C sources,
generates the compiler declaration resource and rebuilds the Swift overlays.
The `assemble` stage verifies the resource and collection runtime symbols.
The source snapshot, license and generated declaration header are hash-bound
into qualification alongside the compiler and UIKit runtime.

`check-collection-api.sh TOOLCHAIN SDK NEW_OUTPUT` compiles unchanged UIKit code
and a second consuming module, covering subclassing, protocols, construction,
registration, dequeue, scroll-position options and scroll-direction enums. It
checks that iOS 5 references are defined by the toolchain UIKit runtime and that
iOS 6 references remain native. `qualify-ios5.sh` runs this check automatically.

## ARM/Thumb startup validation

An iOS 5 device run of the first integrated build crashed in
`PSTInstallIndexPathAdditions`: its constructor pointer had no Thumb bit even
though its symbol/code was Thumb. Both PST constructor entries were affected.
A second device run then trapped entering a Foundation protocol witness: the
data table held an even pointer to Thumb code. The root cause is in LLVM's ARM
Mach-O writer, which emits the Thumb bit into `.word`/`MOVW`/`MOVT` addends only
for external symbols; local Thumb functions lose it, and the older linker cannot
recover it. Every trap is therefore an *address-taken* local Thumb function.

The pipeline now compiles all code it builds for legacy iOS 5 in ARM mode:
the collection runtime, the seven Swift overlays, their native Objective-C
sources, and application/package code (the compiler requests ARM mode from the
Clang invocation that supplies IRGen's target features). Native iOS 6+ builds
remain Thumb and unchanged. No binary pointers are patched.

Assembly and qualification audit the linked images: `check-macho-initializers.py`
verifies constructor entries, and `check-thumb-pointers.py` rejects any absolute
data pointer that reaches a Thumb function without the interworking bit. The
audits are targeted detectors for this linker defect, not exhaustive proofs;
ARM mode is the primary guarantee.

Static compilation and linkage are not device-execution proof. Test on a real
iOS 5 device and on iOS 6 before claiming runtime qualification; the profile's
`deviceExecution` remains `pending` until separately observed.

## Hardware smoke coverage of the iOS 8-10 additions (round 7)

These are scenario-specific smoke tests, not complete behavioural parity or
performance qualification. Later changes require their own device reruns.

| Device | Route | Verified |
| --- | --- | --- |
| iPod touch 3, iOS 5.1.1 | PSTCollectionView | willDisplay, visible supplementary accessors, prefetching, self-sizing, systemLayoutSizeFitting |
| iPod touch 5, iOS 6.1.3 | Apple's UICollectionView + runtime hooks | same |
| iPhone 6, iOS 10.3.3 | Apple's native implementation (hooks inactive) | counts and sizes match the iOS 27 simulator within font-metric differences; native prefetch fired 8 batches and 1 cancel |

Resolved (round 8): an arm64-only app at deployment 10.0 aborted at launch on the iPhone 6 inside libswiftFoundation's
NSDictionary bridge (`cacheCanonicalSpecializedMetadata`). Cause: with no armv7 slice requested the Kit falls back to the
modern retarget route, which embeds the stock Swift 5.10.1 runtime (environment `5.10.1.xctoolchain`, `__text` 0x3637a0) instead
of the source-built stdlib (`out/ios-stdlib`, `__text` 0x364284). The stock runtime crashes on iOS 10; the source-built one does
not. The same app built for armv7+arm64 at deployment 10 uses the native legacy route and passes a ten-step Foundation bridge
check on the phone. So this is a routing limit for arm64-only builds, not a collection-view or stdlib-prespecialization bug,
and it is separate from the armv7s startup crash in SCENE-LIFECYCLE.md (that one is in the source-built armv7s slice).

### Round 25: current-source iPod touch 3 rerun

The full runtime/toolchain rebuild and deployment-5/6 probe builds succeeded.
The deployment-5 probe completed on iPod touch 3, iOS 5.1.1, with these checks
passing on both axes: automatic-size initial proposal 50x50; sole preferred-size
80x30 item centered in a 200x200 viewport; reload remeasured height 30 to 60;
explicit layout invalidation remeasured height 60 to 45. This does not cover
animated scrolling, arbitrary invalidation contexts, supplementary self-sizing,
or every batch-update combination. The same-source Auto Layout direct-update
simulator differential also passed.

The iPod touch 5 was absent from USB for this rerun; the recent Apple iOS 6/7
invalidation hook and shared-delegate changes are not newly hardware-qualified.
The probe's historical timing output is not the corrected paired benchmark and
must not be used to claim PST/native performance parity. Simulator benchmark
results now include offset-setter work and alternate engine order, but remain
CPU microbenchmarks rather than hardware frame-delivery measurements.

### Round 29: controlled batch-mapping A/B (simulator only)

Compared PST source at `30764bd0` (before the recent mapping allocation changes)
with `d3439b7c` using the same current benchmark harness. Eight fresh-process
pairs alternated before/after order; each binary's batch result is the median
of nine repetitions. Every invocation passed the same 14-scenario geometry
golden. After/before batch ratios were 0.922, 0.894, 0.957, 0.891, 0.974, 0.962,
0.941, and 0.970 (median 0.949; improvement in 8/8 pairs). This supports roughly
5.1% lower synchronous batch CPU time for the combined changes in this workload,
not a confidence bound, a hardware result, or equality with native UIKit.
Native/PST batch parity remains unfinished. Raw samples are retained in the
local session evidence directory `/tmp/cv-ab-batch.rIEbZ0`; this temporary path
is not a durable repository artifact.

### Round 33: same-device iPhone 6 CPU baseline

Current PST Objective-C sources and the native-reference harness were compiled
with Xcode 13.4.1 clang, `-O2`, arm64, deployment 10.0, and run as mobile on the
connected iPhone 6 (iOS 10.3.3). Both PST and native UIKit execute in the same
binary. Three launches each used nine alternating native/PST pairs per workload.
Median paired PST/native ratios across launches:

| Workload | Ratio | Launch range |
| --- | ---: | ---: |
| Cold 200 items | 1.02 | 1.01–1.02 |
| Idle ×8 | 0.75 | 0.74–0.78 |
| Scroll ×10 | 1.29 | 1.27–1.29 |
| Reload | 1.53 | 1.53–1.54 |
| Batch insert/delete | 0.70 | 0.69–0.70 |
| Item-size change | 1.79 | 1.73–1.79 |
| Bounds change | 0.94 | 0.93–0.94 |
| Four-section cold | 1.05 | 1.03–1.06 |
| Four-section scroll ×6 | 1.08 | 1.05–1.09 |

This is a command-line UIKit synchronous CPU microbenchmark, not a visible
UIApplication frame-delivery measurement. It proves neither smoothness nor iOS 6
performance parity. It does establish that simulator advantages do not transfer
to device scrolling/reload: those real-device gaps remain to be closed. Raw
session outputs were retained under `/tmp/cv-phone-perf.kMMIVt`. The required
iPod touch 5 iOS 6 baseline remains pending while that device is absent.

### Round 35: reload retirement change hardware A/B

Compared the round-33 iPhone benchmark binary with the same harness rebuilt after
`4293517a` (detach the retirement dictionary instead of copy-and-clear). Six
before/after launch pairs alternated order on the same iPhone 6. The after/before
PST reload ratios were 0.992, 0.984, 1.015, 0.982, 1.017, and 0.988; median 0.990,
with improvement in 4/6 pairs. This mixed roughly one-percent result does **not**
establish a meaningful speedup. The structural allocation reduction is retained,
but the native/PST reload gap is not closed. Session samples were retained under
`/tmp/cv-phone-reload-ab.m8Q1Jn`; these temporary files are not durable artifacts.

### Round 45: 32-bit sizing-wrapper ABI gate

The focused `collection_size_hook_test.m` was compiled `-O2 -marm` as armv7,
deployment 10.0, and executed as mobile on the iPhone 6 / iOS 10.3.3. It passed
original delegate seed, measured-size override, zero-estimate fallthrough,
repeated/inherited wrapper, and super-calling subclass override cases. This
exercises `CGSize` return through both a block-backed IMP and saved typed IMP on
real 32-bit ARM. The simulator test also passes. Modern native installer IMPs
remain unchanged in this test. This is **not** the missing iOS 6/7 layout-engine
integration gate: those hooks are invoked directly using layout test doubles,
and forwarding/proxy sizing delegates remain unwrapped.

### Round 46: iPod touch 3 sizing-delegate regression

All current PST Objective-C sources were built `-O2 -marm`, armv7, deployment
5.0, with the sizing-delegate regression and run as mobile on iPod3,1 / iOS
5.1.1. Estimate-enabled result: delegateCalls=1, fittingCalls=2, final 80x99.
Fresh zero-estimate control: delegateCalls=1, fittingCalls=0, final 80x31. Both
assertions passed. This exercises actual PST layout and preferred sizing on iOS
5, including the recent attribute snapshot change; it is not a displayed-app
frame test or a complete API regression gate.

Initial test links with the modern SDK omitted `crt1.3.1.o`, warned that the
linker changed the target to iOS 7, and produced crashing executables. Relinking
with `-L /Users/jwalr/Developer/Legacy-Build-Inputs` supplied the existing startup
object and resolved the probe startup failure. Session artifacts:
`/tmp/pst-ipod3-sizing.EhijAB` (not durable repository artifacts).

### Round 47: iOS 5 attribute and prefetch lifecycle checks

Using the same current armv7 PST objects and legacy startup object, additional
command-line tests passed on iPod touch 3 / iOS 5.1.1: copy/equality symmetry and
all seven geometry/presentation inequality cases; disabling prefetch cancels
outstanding paths once despite reentrancy; replacing the source retains paths
and cancellation reaches the current source. A new numeric affine-frame test
passes on both native iOS 27 simulator and iOS 5 PST: identity, scale, frame
assignment while scaled, reset, rotation, translation, and translated-center
assignment, each also checking copy geometry. These isolate attribute/setter
behaviour, not app-driven prefetch scheduling or frame delivery. Session build
artifacts: `/tmp/pst-ipod3-lifecycle.A29JW1` (temporary, not durable evidence).

### Round 52: direct snapshot copy hardware A/B

Compared the immediately pre-`bd65f981` arm64 iPhone benchmark against the same
objects/harness relinked with only the updated layout implementation. Six
alternating-order launch pairs on iPhone 6 / iOS 10.3.3; each launch uses nine
alternating native/PST sample pairs. Median PST after/before ratios:

| Workload | After/before | Improved pairs |
| --- | ---: | ---: |
| Cold | 0.988 | 6/6 |
| Idle | 1.034 | 0/6 |
| Scroll | 0.986 | 4/6 |
| Reload | 0.972 | 5/6 |
| Batch | 0.972 | 5/6 |
| Item-size change | 0.995 | 4/6 |
| Bounds change | 0.979 | 5/6 |
| Multi-section cold | 0.987 | 6/6 |
| Multi-section scroll | 0.971 | 6/6 |

These modest CPU reductions do not close native parity. Idle regressed in all
six pairs and needs further investigation; it must not be omitted from the
result. No displayed frame-delivery test was performed. Raw JSON/summary in
`/tmp/cv-copy-ab.CLrkuQ` are session-only artifacts. The harness also emits
availability warnings for `NSJSONWritingSortedKeys` (iOS 11 flag used on iOS 10);
JSON serialization is outside timing, but that harness portability issue remains.

### Round 66: cost of the display-ordering changes (iPhone 6, arm64)

The ordering fixes (retire before add, sorted retirement, cells before
supplementary views) were measured against the build just before them
(`7992ce3a`), changing only `PSTCollectionView.m`. Six alternating-order pairs;
median new/old PST ratio (lower is faster), final single-pass version:

| Workload | new/old | Improved pairs |
| --- | ---: | ---: |
| Cold | 0.990 | 3/6 |
| Idle | 0.940 | 6/6 |
| Scroll | 1.022 | 2/6 |
| Reload | 1.036 | 0/6 |
| Batch | 1.011 | 1/6 |
| Item-size | 1.034 | 0/6 |
| Bounds | 1.026 | 0/6 |
| Multi-section cold | 1.002 | 3/6 |
| Multi-section scroll | 0.904 | 6/6 |

An earlier two-phase version gave almost identical numbers, so the extra loop was
not the cost. Reload, item-size and bounds are about 3% slower in every pair and
the cause is **not identified** (the key-set pre-pass and the sort are the
suspects). Behaviour fidelity was judged worth that cost for now; this is a
regression to revisit, not a win. Also note: replacing a binary at the same path
on the phone made iOS kill the new binary (cached signature); use a fresh path.

Follow-up (same round): the suspect was the second `collectionItemKeyForLayoutAttributes:`
per attribute (once in the key pre-pass, once when adding). Building each key once
and reusing it from a scratch array gave, over six more alternating pairs against
the same `7992ce3a` baseline (median new/old, lower is faster):
cold 0.988, idle 0.955, scroll 0.984 (6/6), reload 1.013 (0/6), batch 1.018,
item-size 1.005, bounds 1.001, multi-section cold 1.001, multi-section scroll 0.868 (6/6).
Reload remains about 1% slower in every pair; batch is noisy (range 0.967-1.058).
This is CPU time only, not frame delivery, and does not reach native parity.

### Round 68: selection-state calls on reuse

`tests/reuse-selected.m` (diagnostic, not a pass/fail gate) logs `prepareForReuse`,
`setSelected:` and `setHighlighted:` on a cell subclass through select, scroll away
and scroll back. Native UIKit calls the two setters once per `prepareForReuse` and
not at all when a cell is created. PST used to call them again after every cell
creation (8 setter pairs against native's 2 in the scroll phase). PST now sets them
at creation only when the value changes; the per-reuse ratio matches native.
Not fixed: PST prepares 4 reused cells where native prepares 2. `tests/reuse-order.m`
(diagnostic) shows why: native does retire first (`end` before `cellForItem`) but
does not hand a view it retired in the same pass to an arriving cell, so it creates
new cells (`new#3`, `new#4`) where PST reuses `#2`, `#1`. On the next pass native
reuses one queued cell and creates another instead of reusing the second, which a
plain LIFO queue does not explain. A "reusable only after the pass" model fits the
first pass but not the second, so no code change was made. Observable by apps that
count cell creations or `prepareForReuse` calls. Profile of a reload loop (simulator, 200 items): about
64% of main-thread time in `pstAddVisibleViewForAttributes:key:`, of which
`addControlledSubview:` (UIKit `insertSubview:atIndex:`) is about 39%.

### Round 69: native iOS 10.3.3 self-sizing scroll differs from iOS 27

`tests/native-ios10-selfsizing-scroll.m` is a standalone repro (no PST). With
`estimatedItemSize` set, 40 items of increasing preferred height, a 200x120 view and
`scrollToItemAtIndexPath:atScrollPosition:Top animated:NO` on item 39:

| | iOS 27 simulator | iPhone 6, iOS 10.3.3 |
| --- | --- | --- |
| Fresh collection | cell visible, offset 1585, content height 1705 | cell **nil**, offset 920, content height 2083 |
| After a 3-item reload first | cell visible, same | **NSRangeException** (cell queried against the stale 3-item array) |

So on iOS 10 the native engine neither resolves the destination of a self-sizing
scroll nor survives a reload to a larger data set after measuring. Consequences:
(1) the iOS 27 simulator is the oracle for self-sizing scroll/mutation behaviour and
the iPhone 6 result for `run-self-sizing-updates` is a native bug, not a PST
failure; (2) PST passes that fixture on the same phone, so on iOS 10 hardware PST
is stricter than native here; (3) no oracle exists for self-sizing scroll on iOS 6/7
or 8/9 hardware, so Apple-route behaviour there remains unverified. PST's content
height, offset and cell at the same scenario were not compared on the phone (see below).

The same file also builds against PST (`-DTEST_PST=1`). Results for the same scenario:

| Engine | Cell 39 | Offset | Content height |
| --- | --- | ---: | ---: |
| Native, iOS 27 simulator | visible | 1585 | 1705 |
| PST, iOS 27 simulator | visible | 1650 | 1770 |
| PST, iPhone 6 (iOS 10.3.3) | visible | 1650 | 1770 |
| Native, iPhone 6 (iOS 10.3.3) | nil | 920 | 2083 |

PST gives identical numbers on simulator and phone, and survives the reload that
crashes native iOS 10. But it differs from the iOS 27 oracle by 65 points in both
offset and content height, so this scenario is **not** a PST/native match. The sum
of all 40 heights is 2760, so every engine is reporting a partly measured layout; the
difference is which items each engine has measured when the scroll resolves. That
set depends on engine-internal measurement order and was not investigated.

### Round 71: why PST and native differ by 65 points (cause found, not implemented)

`tests/selfsizing-measurement-trace.m` logs every `preferredLayoutAttributesFitting`
query and the per-item sizes after the scroll (iOS 27 simulator, native vs PST).

Native: measured items 0-3 (30, 32, 34, 36), and **every unmeasured item is laid out
at the running mean of the measured sizes (33) instead of the estimate (40)**. After
the scroll it also measured 35-39 (100..108), and item 34 was laid out at 62.5714,
which equals the mean of the 7 measured items 0-3 and 35-37 at the moment item 34
was placed. Items 4-33 stayed at 33. So native uses a running average of what it has
measured so far as the proposal for unmeasured items, not the fixed
`estimatedItemSize`. Content height by that model: 1704.6 (observed 1705).

PST: queries 0-3 and 37-39 only, keeps unmeasured items at the fixed estimate (40),
content height 1770. The 65-point difference is the estimate-versus-mean gap.

Open points before implementing: native measured 35 and 36 during the scroll and PST
did not (it measured 37-39), and the mean is evidently updated while placing items in
a single pass. Reproducing the exact order of 36,37,35,38,39 would need more probes.
This is a layout-geometry rule, so changing it affects every self-sizing result, and
the existing automatic-size gate (which uses uniform preferred sizes, where mean and
estimate coincide only when the estimate is 50x50) would need to keep passing.

### Round 72: the running-mean proposal across scenarios and OS versions (still not implemented)

`tests/selfsizing-unmeasured-proposal.m` (diagnostic; builds for native and, with
`-DTEST_PST=1`, PST) prints the laid-out heights of a self-sizing list after the
first layout. Sizes of runs are shown as `size (xN)`.

| Scenario (estimate 40) | Native iOS 27 sim | Native iPhone 6 iOS 10.3.3 | PST |
| --- | --- | --- | --- |
| 30 items all 100 | 100 (x30) | 100 (x30) | 100 (x3) 40 (x27) |
| same, estimate 200 | 100 (x30) | 100 (x30) | 100 (x2) 200 (x28) |
| ramp 30+2i, view 120 | 30 32 34 36 **33 (x26)** | same | 30 32 34 36 **40 (x26)** |
| ramp, view 400 | 30..50 step 2, then 40 (x19) | same | same |
| alternating 20/80, view 160 | 20 80 20 80 **50 (x26)** | 20 80 20 80 20 **44 (x25)** | 20 80 20 80 **40 (x26)** |
| single item, 3 items | exact | exact | exact |

Findings: (1) both native versions size unmeasured items at the mean of the measured
sizes, and for uniform content that means the whole list takes the measured size,
which PST does not (PST leaves the estimate, so a uniform 100pt list is 1380pt
tall in PST but 3000pt natively). (2) The measured set differs by OS: iOS 10 measured
5 items in the alternating case where iOS 27 measured 4, so the mean differs (44 vs
50). (3) PST matches native exactly only when the whole content is visible. So PST
cannot be made to match both oracles on partially measured content; a choice of
reference version would be needed, and the iOS 27 simulator is the stated oracle.
Not implemented: the earlier trace showed unmeasured items keeping the mean from when
they were first placed (items 4-33 stayed at 33 while item 34 took a later mean), so
the mean is cached per item at some invalidation granularity I have not identified.

### Round 73: native proposal is updated per measurement (model fits, not implemented)

`tests/selfsizing-proposal-steps.m` scrolls a 60-item ramp (preferred 30+2i, estimate
40, view 120) in steps and prints each run of unmeasured items (iOS 27 simulator,
native only). Measured items are marked `*`.

| After | Unmeasured tail | Measured so far | Mean of measured |
| --- | ---: | ---: | ---: |
| first layout (0-3) | 33.00 | 4 | 33.00 |
| scroll to 300 (+8-11) | 41.00 | 8 | 41.00 |
| scroll to 600 (+15-17) | 46.73 | 11 | 46.73 |
| scroll to 900 (+20-22) | 52.14 | 14 | 52.14 |
| scroll to 1200 (+25,26) | 55.75 | 16 | 55.75 |

The tail always equals the mean of every size measured so far, to two decimals. The
single unmeasured items between measured blocks hold an earlier mean: item 7 = 39.43
is the mean of the first 7 measurements, and items 14, 19 and 24 (45.00, 50.46, 54.00)
are the means of exactly the first 10, 13 and 15 measurements. Items 4-6 kept the
very first mean (33.00). So the proposal is refreshed as each cell reports its size,
and an unmeasured item keeps whichever mean was current when the layout last touched
it. Content height follows (1980 at first layout; PST's fixed estimate gives 2400).

Reproducing this needs PST to apply measurements one at a time in native's order
(items 8-11 arrived as 8,9,10 then 11, but the mid-block items 36,37,35,38,39 in the
earlier trace arrived out of order), and to know which items the layout "touches" on
each update. I have a model that fits every number above but no test that would catch
a wrong guess about the untouched items, so nothing was changed in PST.

### Round 74: PST now proposes the mean of measured sizes (partial match)

`PSTCollectionViewFlowLayout` now proposes, for self-sizing items not yet measured,
the mean of the cell-reported sizes (frozen for each layout rebuild) once any size has
been reported; the estimate only seeds the first layout. Delegate-supplied seeds are
not counted as reports. `tests/run-selfsizing-proposal-test.sh` gates the first-layout
probe against native on the iOS 27 simulator (7 scenarios, byte-identical), and the
same 7 results were identical on the iPod touch 3 (iOS 5.1.1).

Stepped scrolling still differs from native. In the 60-item ramp, content height after
each scroll step, native / PST: 2434 / 2556, 2742 / 2837, 3022 / 3127, 3201 / 3398
(3.5%-6.2% taller in PST). Native updates its mean as each cell reports and leaves
untouched items on the mean current when they were last placed; PST freezes one mean
per rebuild and applies it to every unmeasured item. `selfsizing-proposal-steps.m`
shows the detail. This is closer to native than the fixed estimate was (PST's earlier
gap was up to the whole estimate-versus-mean difference), but it is not a match.
Existing gates still pass: automatic-size (the 2 known subpixel differences remain),
self-sizing mutation, delegate precedence, 14 geometry scenarios.

### Round 75: Apple route given the same mean proposal (unit-level only)

`UICCollectionViewDisplay.m` (iOS 6/7 self-sizing) now follows the PST rule: the
estimate seeds the first layout, then unmeasured items are proposed at the mean of
the cell-reported sizes, frozen when the layout is rebuilt; a re-reported item
replaces its earlier size in the mean; delegate seeds are not counted; resetting
clears it. `collection_size_hook_test.m` checks the arithmetic (seed, frozen until
rebuild, mean of reports, replace-not-add, measured item keeps its own size, reset)
and passes on the simulator and as an armv7 executable on the iPhone 6. The runtime
compiles for armv7, armv7s and arm64.

**Not verified:** this has never run inside Apple's iOS 6/7 flow layout. The iPod
touch 5 has not been connected, and no oracle exists for how iOS 6/7's own engine
responds to these proposals. The rule is copied from PST, which was fitted to the iOS
27 and iOS 10 native behaviour, so on iOS 6/7 it is a hypothesis.

### Round 76: cell resize without per-subview autoresizing (iPhone 6, arm64)

Fresh same-device baseline, median PST/native paired ratio over three launches
(higher is slower): cold 1.08, idle 0.76, scroll 1.34, reload 1.75, batch 0.73,
item-size 1.88, bounds 0.99, multi-section cold 1.10, multi-section scroll 0.99.

A profile of the item-size loop (simulator) put 50% of main-thread time in
`applyLayoutAttributes:`, almost all in UIKit autoresizing the cell's background and
content views on every bounds change. A microbenchmark on the phone: 38.6 us per
cell with autoresizing against 13.4 us setting the child frames directly (0.35x).
`PSTCollectionViewCell` now sets those frames itself, with autoresizing suspended, when
the cell is stock (only its background, content and optional selected-background views,
default masks, frames equal to bounds). Any extra subview, a changed mask or a changed
frame takes the ordinary path. `tests/run-cell-resize-test.sh` checks that the cell,
content view and two app-added subviews (one on the cell, one in the content view) end
up where native UIKit puts them; it passes on the simulator and the iPod touch 3.

Six alternating-order pairs, new/old PST median: **item-size 0.729 (6/6 pairs faster)**,
cold 0.993, idle 1.007, scroll 0.998, reload 0.994, batch 0.996, bounds 1.005,
multi-section cold 1.015, multi-section scroll 0.997. So only the size-change workload
moved, from about 1.88x to about 1.37x native. That is an estimate from multiplying
medians measured in separate runs, not a measured ratio. Reload (1.75x), scroll (1.34x)
and cold layout (1.08x) are unchanged and still slower than native.

Same round: reload profile (simulator, current code) shows `removeFromSuperview` at
18.8% of main-thread time, and a probe (`reloadsem.m`-style, logging overridden
`removeFromSuperview`) showed PST calling it twice per cell on reload: once while
retiring and again when queueing for reuse. Native UIKit's cells still have a
superview when `cellForItem` runs after a reload; PST's do not. `queueReusableView`
now skips the second call when the view is already detached. Six alternating pairs on
the iPhone 6 against the previous build, new/old PST median: reload 0.979 (6/6 faster),
item-size 0.986 (6/6), bounds 0.988, multi-section cold 0.991 (6/6), idle 0.986, scroll
0.995, multi-section scroll 0.972, cold 0.998, batch 1.000. A small gain, not a fix:
reload is still roughly 1.7x native. The profile's remaining time is `insertSubview`
(about 38%, UIKit) and view dequeue/creation. The cell-with-superview difference is
not changed (native keeps the retired cell attached until it is reused).

### Round 78: native keeps retired cells attached and hidden (cause of the reuse difference)

`tests/retired-cells.m` counts a collection view's cell subviews through scroll steps
(200x100 view, 50pt rows, 40 items; iOS 27 simulator):

| | cell subviews | hidden | `visibleCells` |
| --- | ---: | ---: | ---: |
| Native initial | 2 | 0 | 2 |
| Native after scrolling to 500 | 4 | 2 | 2 |
| Native after scrolling to 1000 | 4 | 2 | 2 |
| PST at every step | 2 | 0 | 2 |

Native does not detach a retired cell. It hides it and leaves it in the view
hierarchy, and a later dequeue reuses it (un-hiding it). That explains the earlier
reuse-count difference: a cell retired in a pass is not yet in the queue when the same
pass creates arriving cells, so native creates new ones where PST recycles. It also
means native skips `removeFromSuperview` and `insertSubview:atIndex:` on the scroll
path, which are the two largest UIKit costs in PST's scroll and reload profiles
(about 7% and 16% of main-thread time in scroll). Matching this changes observable
state (the cell stays in `subviews`, hidden) and `didEndDisplaying` timing relative to
the queue, so it is not a pure optimisation. Not implemented yet.

### Round 78 (continued): iOS 6.1 UIKit disassembly confirms the retired-cell model

Reference only, from the iOS 6.1 i386 UIKit already analysed under
`ios61-ref/ghidra` (`collection-reuse-output` and a new read-only extraction of
`_updateVisibleCellsNow:` and `_addControlledSubview:atZIndex:` into
`collection-update-output`). No code was copied; this records behaviour.

- The shared enqueue helper behind `_reuseCell:` and `_reuseSupplementaryView:`
  adds the view to the reuse queue and then sends `_setHiddenForReuse:YES`. It
  sends `removeFromSuperview` only on the other branch, when the queue is at or
  above a capacity computed from the main screen's area divided by the view's own
  area (half the screen area over the view area, rounded up, plus one) or when the
  queue already contains the view. So a retired view normally stays in the hierarchy.
- `_addControlledSubview:atZIndex:` sends `_setHiddenForReuse:NO` to the incoming
  view before inserting it, which un-hides a recycled view.
- `prepareForReuse` is sent at dequeue, not at enqueue (already matched by PST).

This agrees with the iOS 27 observation (retired cells stay as hidden subviews until
reused), so the behaviour is stable across the oracle and the reference. It is the
reason native recycles a cell only on a later pass, and it is the missing piece for
PST's extra `prepareForReuse` calls and for skipping `removeFromSuperview` /
`insertSubview:` while scrolling. Implementing it needs a private `hiddenForReuse`
state that survives `hidden` assignments by the layout (apply of attributes must not
un-hide), the capacity cap, and `subviews`-visible changes to be accepted.

### Round 79: retired views stay attached and hidden (implemented; hardware-measured)

`PSTCollectionView` now retires a view the way native UIKit does. It hides the view,
tells the delegate (`didEndDisplaying` sees it already hidden, as under UIKit), and
queues it only after the pass has created its arrivals, so a view retired in a pass
is not recycled in that pass. It stays in the hierarchy until a later dequeue
un-hides it, which skips a `removeFromSuperview` and an `insertSubview:` per recycled
view. The queue is capped (half the main screen's area over the view's area, rounded
up, plus one); beyond the cap or for a duplicate the view is detached. `reloadData`
hides instead of detaching. Behaviour taken from the iOS 6.1 disassembly and checked
on the iOS 27 simulator (`retired-cells.m`, `retired-capacity.m`, `reuse-order.m`).

Checked: PST after scrolling now has 4 cell subviews with 2 hidden, as native does;
a reload shows `superview yes` in `cellForItem`, as native does; display-event gates,
self-sizing mutation, cell-resize and the 14 geometry scenarios pass; the iPod touch 3
(iOS 5.1.1) display-event sequence matches native structurally.

Hardware (iPhone 6), six alternating pairs, new/old PST median: **reload 0.562,
scroll 0.816, multi-section scroll 0.871, item-size 0.933**, batch 0.973, cold 0.990,
bounds 0.991, multi-section cold 0.996, **idle 1.028 (1/6 pairs faster)**. Paired
PST/native over three launches: cold 1.09, idle 0.79, **scroll 1.09, reload 0.95**,
batch 0.71, item-size 1.26, bounds 0.99, multi-section cold 1.11, multi-section
scroll 0.87. Reload and multi-section scroll are now at or below native; scroll is
within 9%; item-size (1.26) and cold layout (1.09-1.11) remain slower. Idle got about
3% slower in this comparison and is not explained.

Not matched, and not changed by this work (the same results appear at the previous
commit):
- Native does not create a visible cell for a layout item whose `hidden` is YES
  (`layout-hidden-items.m`: native shows 1 cell, PST shows `0h 1`).
- `hitTest:` inside a visible cell returns the cell natively but the cell's inner view
  in PST (`hidden-retired-effects.m`).
Untested with the new retirement: animated `performBatchUpdates` retirement
(`freeUnusedViews` and `finishUpdate` now hide and keep views attached) beyond the
non-animated mutation suite, and the Apple iOS 6/7 route, which has its own path.

### Round 80: animated deletes: callbacks fixed, animation still does not match

Probes (`animated-delete-callbacks.m`, `animated-delete-presentation.m`; iOS 27
simulator, cell view inside a window, `performBatchUpdates` deleting two rows):

| | Native | PST before | PST now |
| --- | --- | --- | --- |
| `didEndDisplaying` for deleted rows | sent once, at animation completion (453 ms), rows 1 then 2, view hidden, alpha 0 | never | sent, rows 1 then 2, view hidden |
| `completion` | at the same instant (453 ms) | 1 ms | 1 ms |
| Deleted cell | alpha fades 0.15 -> 0.01 -> 0, then hidden | n/a | alpha 0 and hidden at once |
| Cell below the deletion | slides 46.1 -> 40.4 -> 40 over the animation | snaps | snaps |

Delegates now hear `didEndDisplaying` for deleted cells and supplementary views (it was
missing entirely: the animated path never called it), in ascending index-path order,
with the view already hidden. The retired view is kept attached and hidden under the
capacity cap like any other. Display-event, self-sizing, cell-resize and geometry gates
pass; a PST iOS 5 compile has no errors.

**Not fixed:** the animation itself does not run in these probes. PST finishes the
update in 1 ms and the cells jump, where native takes about 450 ms and animates alpha
and position. The same snapping occurs at `b6a45a5c`, the commit that was meant to
add 0.3 s animations, so this is not caused by the retirement change; the earlier
animation work appears to depend on conditions these probes do not satisfy (a window
and a run loop are present here). Until that is understood, `completion` timing and
the animated frames should be treated as unmatched. This overlaps the earlier user note
that PST animations were missing.

### Round 81: why PST batch updates did not animate on the simulator (fixed)

Instrumenting a scratch copy showed `animateWithDuration:` being called with a duration
of about 1.6e-315. `PSTSimulatorAnimationDragCoefficient()` looked up UIKit's
`UIAnimationDragCoefficient` with `dlsym` and called it through a pointer typed as
returning `CGFloat`. UIKit's function returns a `float`; on 64-bit, `CGFloat` is a
double, so the wrong width was read from the return register and the duration came out
as garbage near zero. Every batch update therefore completed in about 1 ms and snapped.
It is simulator-only (the lookup is under `TARGET_IPHONE_SIMULATOR`), so devices were
not affected, but it means the earlier animation commit `b6a45a5c` was never exercised on
the simulator oracle. The pointer is now typed `float` and the result widened.

Delete probe (two rows, view in a window), animation and callbacks:
- native iOS 27 sim: completion at 448 ms; deleted cell alpha 0.17 at 150 ms, 0.01 at
  300 ms; the cell below is at y=46.6 at 150 ms and 40.5 at 300 ms.
- PST now, iOS 27 sim: completion at 305 ms; deleted cell alpha 0.48 at 150 ms, 0 at
  300 ms; the cell below is at y=59.1 at 150 ms and 40 at 300 ms.
- native iPhone 6 (iOS 10.3.3): completion at 357-409 ms over three runs.
- PST on the iPod touch 3 (iOS 5.1.1): completion at 331 ms, `didEndDisplaying` rows 1
  then 2 with the view hidden, delivered with completion.

**Correction (next round):** the paragraph that stood here claimed the native timing
was not a plain 0.3 s animation on any measured device. That was wrong. Reading the
animations UIKit attaches to the layers (`tests/animation-layer-keys.m`):
- iPhone 6, iOS 10.3.3, native: `CABasicAnimation`, 0.300 s, ease-in-out
  (0.42, 0, 0.58, 1), keys `position` and `opacity`. PST on the same phone attaches the
  identical animation, and completion lands at 378-409 ms against native's 357-409 ms.
- iOS 27 simulator, native: a critically damped `CASpringAnimation` (mass 1, stiffness
  438.649, damping 41.888, so w = 2*pi/0.3 s), 0.441 s. That is what differed from PST's
  curve in the probe above. It is not an OS PST targets.
So PST's animation already matches the real target devices; the simulator is only a
trustworthy oracle for the animation *curve* on OSes new enough to use springs. iOS 6.1.3
was measured at 0.3 s in the earlier animation commit.

This corrects the previous section, which said PST animations did not run for reasons
unknown and that the retirement change was not the cause: the cause was this return-type
bug, present since `b6a45a5c`. Existing gates pass; the earlier "snapping" evidence was
the same bug.

### Round 83: stop boxing item rects when nobody asked for them

Profile of the item-size loop with the current code (simulator): `layoutRow` is 16% of
main-thread time, and `PSTGridLayoutRow layoutRowAndGenerateRectArray:` is called with
`NO` by `layoutRow`, which passes no array, yet it still created an `NSValue` for every
item and sent `addObject:` to nil. It now skips that when no array is requested.

iPhone 6, six alternating pairs against the previous build, new/old PST median:
**item-size 0.889 (6/6 faster), batch 0.946 (6/6), bounds 0.952 (6/6), cold 0.966 (6/6),
multi-section cold 0.965 (6/6)**, idle 0.971, reload 0.993, scroll 0.998,
multi-section scroll 0.990. All gates pass (14 geometry scenarios, self-sizing,
automatic-size, display events); iOS 5 compile has no errors.

The profile now has `applyLayoutAttributes:` (mostly `UIView setFrame:`) at about 44% for
a size change and `PSTGridLayoutSection computeLayout` at about 21%.

### Round 84: current same-device ratios (iPhone 6, iOS 10.3.3, arm64)

Paired PST/native median over three launches of the current build (`3b2eae09`);
above 1 is slower than native. Compare round 76's baseline in parentheses.

| Workload | Now | Round 76 |
| --- | ---: | ---: |
| Cold, 200 items | 1.06 | 1.08 |
| Idle x8 | 0.75 | 0.76 |
| Scroll x10 | 1.08 | 1.34 |
| Reload | 0.96 | 1.75 |
| Batch insert/delete | 0.67 | 0.73 |
| Item-size change | 1.15 | 1.88 |
| Bounds change | 0.95 | 0.99 |
| Multi-section cold | 1.07 | 1.10 |
| Multi-section scroll x6 | 0.87 | 0.99 |

Still slower than native: item-size change (1.15), scroll (1.08), cold layout (1.06 and
1.07). The other six workloads are at or below native. This is a command-line UIKit
synchronous CPU microbenchmark on one phone; it is not frame delivery, not an iOS 6
measurement and not a claim of parity.

Scroll profile (simulator, current code): `updateVisibleCellsNow` 41%, of which adding
views 23%, `layoutAttributesForElementsInRect:` 12%, `validateLayoutInRect:` 15%; UIKit's
own `setContentOffset` 14%, `setBounds` 5%, `setHidden` 4%. Nothing PST-specific stands out.
Candidate for the remaining layout cost: `PSTGridLayoutSection computeLayout` (about 21% on
a size change) walks every item and creates a row object per row even for fixed-size
items; a closed-form fast path for fixed item size could remove most of it, but it changes
the structure the attribute query, self-sizing and update code rely on, so it needs the
14-scenario geometry gate and the self-sizing suites around it. Not started.

### Round 85: hidden layout attributes create no view (matches native)

`PSTCollectionView` now treats an attribute with `hidden = YES` as not visible: it
creates no view for it, and a view the item already had is retired (leaving its key out
of the visible set does both). Before this, PST created the view and hid it, which put an
extra, hidden cell in `visibleCells`.

`tests/run-layout-hidden-test.sh` (layout hides every even item, scroll away and back,
then stop hiding; plus a toggle probe logging `willDisplay` and `didEndDisplaying`)
compares native and PST byte for byte on the iOS 27 simulator and passes. The same toggle
sequence on the iPod touch 3 (iOS 5.1.1) matches the native output exactly. Display
events, self-sizing, cell-resize, automatic-size and the 14 geometry scenarios still pass;
iOS 5 compile has no errors.

iPhone 6, six alternating pairs against the previous build, new/old PST median: every
workload is within 1.5 percent and none moves consistently (cold 1.004, scroll 1.008,
reload 1.015, item-size 1.007, batch 1.002, idle 0.970), so the added branch has no
measurable cost.

Resolved: the "native does not create a visible cell for a hidden layout item" difference
listed in rounds 79 and 84. Still open: `hitTest:` inside a visible cell returns the cell
natively but its inner view in PST.

### Round 86: `hitTest:` on cells: native depends on whether the cell was recycled

`tests/cell-hit-test.m` (iOS 27 simulator): for a freshly created cell native's
`hitTest:` returns the cell's content view, like PST. After scrolling, hit-testing a
recycled cell returns the **cell itself**, where PST still returns the content view.
So the round 79 note that native returns the cell "inside a visible cell" described the
recycled case only. Both content-view and cell report `userInteractionEnabled` YES in
both states, so the cause is internal to UIKit's recycled-view path, not a flag
PST can copy. PST's selection and highlighting use `indexPathForItemAtPoint:` rather
than the hit-test result, so this does not change which item a touch selects. Left
unmatched on purpose: reproducing a rule that depends on recycling history would mean
imitating an internal quirk; revisit only if an app is shown to depend on it.

### Round 87: default cell has one subview, like UIKit

`tests/cell-structure.m` compares the cell's subviews as a background view and a selected
background view are set, resized and cleared. Native UIKit's new cell has `backgroundView`
nil and exactly one subview (the content view); setting a background puts it first, and
setting a selected background puts it between the two. PST used to add an empty default
background view to every cell, so each cell had two subviews and one more view to resize
and attach. It no longer does. `backgroundView` is nil by default, as natively, and the
resize fast path now handles the content view plus whichever backgrounds exist. The probe's
only remaining difference from native is timing, not structure: native creates its content
view lazily, on the first access to `cell.contentView` (a fresh native cell reports zero
subviews until then), where PST creates it in `initWithFrame:`. Once `contentView` has been
touched the structure matches (background, selected background, content, all frames equal
and resizing together, and a resize moves all three). An earlier sentence here blamed
`layoutIfNeeded`; that was a guess and was wrong.

**Compatibility change:** code that read `cell.backgroundView` on a fresh PST cell and
expected a view will now get nil, exactly as on UIKit; assigning one still works. The
hit-test, selection, display-event, self-sizing, cell-resize and geometry gates all pass;
the iPod touch 3 (iOS 5.1.1) output of the structure probe is identical to the simulator
build of PST.

iPhone 6, six alternating pairs against the previous build, new/old PST median:
**cold 0.777, multi-section cold 0.780, bounds 0.844, item-size 0.902, multi-section scroll
0.935, scroll 0.962** (all 6/6 pairs faster), batch 0.985, idle 0.970, reload 1.001.

Paired PST/native over three launches (below 1 is faster than native): cold 0.82, idle 0.77,
scroll 1.03, reload 0.95, batch 0.66, item-size 1.03, bounds 0.79, multi-section cold 0.84,
multi-section scroll 0.81. On this benchmark and device no workload is more than about
3 percent slower than native and most are faster. That is CPU time for synchronous
layout and view updates on one iPhone 6; it is not frame delivery, not iOS 6 hardware, and
the benchmark's cells are plain views, so it does not show parity for heavy cell content.

### Round 88: a heavier-cell benchmark contradicts the earlier item-size result

`tests/heavy-cell-bench` runs native UIKit and PST in one binary on the iPhone 6 (iOS
10.3.3), alternating order, 15 pairs per row, with N plain `UILabel`s in each cell
(`README.md` there has the build flags). Median PST/native, three runs of the 3-label
build agreed within 0.04:

| Labels per cell | Item-size change (x3) | Scroll (x10) |
| ---: | ---: | ---: |
| 0 | **2.14** | 1.01 |
| 1 | **1.93** | 0.92 |
| 3 | **1.70** | 0.86 |
| 6 | **1.46** | 0.78 |

Other rows at 3 labels: reload and cold, 1.25-1.27 (min 0.89, max 1.63 across runs).

So scroll is at or below native and gets relatively better with heavier cells, but
**item-size changes are 1.5-2.1x native's time**. This does not agree with the round 87
figure of 1.03: that harness changes the item size once, from 100x50 to 80x40, so it
exercises a different mix; this one resizes every visible cell three times. The earlier
"no workload more than about 3 percent slower than native" statement is therefore true
only for that harness's workloads and must not be read as covering repeated resizes or
heavier cells. Cold/reload with labelled cells is also about 25% slower here (single
scenario, wide spread).

A profile of the 3-label item-size loop (simulator): `UIView setFrame:` 43%, of which
`resizeSubviewsWithOldSize:` (autoresizing the labels inside the content view) is 23% and
`UILabel setFrame:` 16%; `computeLayout` 32%. The labels' own autoresizing is UIKit work
that native presumably avoids or defers when it resizes a cell; why native's cost per
cell is so much lower was not established.

### Round 89: PST's cost grows with item count; native's does not

`scaling-resize.m` / `scaling-all.m` (iPhone 6, iOS 10.3.3; plain cells, fixed 320x58 items,
320x480 view; 40 timed iterations after warm-up) against the number of items. Microseconds:

| Items | Resize, native | Resize, PST | Scroll step, native | Scroll step, PST | Reload, native | Reload, PST |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8 | 544 | 436 | | | | |
| 50 | 577 | 763 | | | | |
| 200 | 624 | 1,769 | 242 | 178 | 854 | 614 |
| 1,000 | 569 | 7,239 | 220 | 228 | 886 | 802 |
| 5,000 | 615 | 34,112 | 235 | 739 | 894 | 1,387 |
| 20,000 | | | 216 | 1,488 | 1,276 | 1,694 |

Native's resize, scroll and reload are essentially flat in the item count. PST's resize grows
linearly (about 7 us per item), and its scroll step stops being competitive somewhere past
1,000 items (3.1x native at 5,000, 6.9x at 20,000). At 200 items, which is what the other
benchmarks here use, the gap is small, which is why it was not visible: **the earlier
"within about 3 percent of native" and "at or below native" statements do not hold for
large collections.** Cold layout at 5,000 and 20,000 items took 33.5 ms and 118 ms in PST against
about 2 ms native.

Cause (from the profile and the code): `computeLayout` visits every item and builds a row
object per row even for fixed-size sections, so a layout rebuild is O(items); and
`layoutAttributesForElementsInRect:` walks every row of every section testing
`CGRectIntersectsRect`, so a scroll step is O(rows). Native evidently does neither.

Next candidates, in order of how contained they are: (1) in the attribute query, rows are
ordered along the scroll axis, so find the first intersecting row by binary search and stop
at the first row past the rect (keeps the structure, makes scroll O(visible)); (2) a
closed-form fast path for fixed-size sections that does not build row objects (changes the
structure that self-sizing, updates and the attribute query rely on, so it needs the
14-scenario geometry gate and the self-sizing suites around it). Not started.

### Round 90: attribute query is O(visible rows); scroll no longer grows with item count

`layoutAttributesForElementsInRect:` now binary-searches the first row whose far edge reaches
the rect and stops at the first row that starts beyond it (rows are in increasing order along
the scroll axis), instead of testing every row of every section. It also stops using
`indexOfObjectIdenticalTo:` to find the section (a linear scan per section per call) and the
item (a linear scan per item for variable-size sections); rows now carry `firstItemIndex`,
set by the section while it lays rows out.

`tests/attribute-query-window.m` compares the query with a brute-force reference built from
`layoutAttributesForItemAtIndexPath:` and the supplementary accessors, over 3,276 rects
(vertical and horizontal, fixed and variable item sizes, with and without headers and
footers, one to six sections, rect sizes from 1 to 700 points). It reports 0 mismatches on
this code and on the previous commit (so the test is sound) and 0 on the iPod touch 3
(iOS 5.1.1) as an app. The 14 geometry scenarios, self-sizing, automatic-size, display-event,
cell-resize, hidden-layout and unmeasured-proposal gates pass.

iPhone 6, plain cells, microseconds (previous round's PST in brackets):

| Items | Scroll step, PST | Scroll step, native | Reload, PST | Reload, native |
| ---: | ---: | ---: | ---: | ---: |
| 200 | 223 (178) | 242 | 888 (614) | 854 |
| 1,000 | 218 (228) | 220 | 810 (802) | 886 |
| 5,000 | 221 (739) | 235 | 815 (1,387) | 894 |
| 20,000 | 158 (1,488) | 216 | 805 (1,694) | 1,276 |

Scroll is now flat in the item count and matches native at every size; reload is flat too and
below native from 1,000 items up. (The 200-item row differs from last round by run-to-run
noise: single-engine probes, not paired.)

**Still O(items):** a layout rebuild. A resize at 5,000 items is 34.6 ms against native's 0.6
ms and cold layout at 20,000 items is 97 ms against about 2 ms; `computeLayout` still visits
every item and builds a row object per row. That is the closed-form fixed-size fast path
described last round, which has not been started.

### Round 91: fixed-size layout rebuild reuses the first row's layout (about 2.2x faster, still O(items))

In a fixed-size section every complete row lays out identically, so `computeLayout` now lays out
the first complete row and lets later complete rows adopt its size instead of re-running the
alignment arithmetic. The final row, which may be incomplete, is always laid out on its own, and
variable-size sections are untouched.

`tests/fixed-layout-dump.m` prints every item frame and the content size for 648 fixed-size
configurations (both scroll directions, six view dimensions, four item widths, three spacings,
item counts from 0 to 41, two sections of different sizes): 17,496 lines. The new build is
**byte-identical** to the previous commit's output. On the iPod touch 3 (iOS 5.1.1) the same dump
agrees with the simulator on every line within 0.00046 points; the difference is the 32-bit device
printing single-precision floats, not a layout difference (both builds of the simulator agree
exactly). The 14 geometry scenarios, the 3,276-rect query test, self-sizing, automatic-size,
display-event, cell-resize, hidden-layout and unmeasured-proposal gates pass.

iPhone 6, plain cells, microseconds (previous round in brackets):

| Items | Resize, PST | Resize, native | Cold layout, PST | Cold, native |
| ---: | ---: | ---: | ---: | ---: |
| 200 | 991 (1,781) | 624 | 9,823 (9,873) | 11,962 |
| 1,000 | 3,383 (7,177) | 569 | 5,126 (7,714) | 3,179 |
| 5,000 | 15,694 (34,575) | 615 | 12,520 (25,272) | 1,815 |
| 20,000 | | | 46,020 (97,146) | 1,941 |

Scroll (213-225 us) and reload (about 850 us) stay flat as before. **A rebuild is still O(items)**:
a resize at 5,000 items is 15.7 ms against native's 0.6 ms. The profile now shows
`addRow` 26.6% and the section's deallocation 22.4% (together about half of a rebuild): the
section still allocates and frees one row object per row. Removing that needs rows that are not
objects (or a lazily built row array for fixed-size sections), which changes the structure the
attribute query, updates and self-sizing rely on and has not been started.

### Round 92: fixed-size sections keep two row objects, not one per row (rebuild is now flat)

A fixed-size section no longer allocates a row object per row. It lays out a template row (which
stands for every complete row) and the last row (which may be incomplete), and keeps one origin
per row in a `CGFloat` array. The section exposes `rowCount`, `rowAtIndex:` and `rowFrameAtIndex:`;
the attribute query, `layoutAttributesForItemAtIndexPath:` and the item-rect cache use them.
Variable-size sections are untouched, and sizes the compact path cannot handle (no items, a
non-positive item size) fall back to the general loop. Row origins use the same additions as
before, so the geometry is bit-identical.

**A bug the new test caught before this was committed:** the attribute query computed a cell's
index from `row.index`, and the compact path shares one row object between all complete rows, so
about 40% of the 3,276 query checks failed (1,224). The query now uses the row's position. The
geometry golden had also failed in the same run, and passed again after the fix.

Verification: `tests/fixed-layout-dump.m` output is **byte-identical to the previous commit** for
both the 648-configuration sweep (17,496 lines) and a larger sweep up to 700 items per section
(344,520 lines); the iPod touch 3 (iOS 5.1.1) agrees with the simulator on the 648-configuration
dump within 0.00046 points (single-precision printing). The 3,276-rect query test, the 14 geometry
scenarios, self-sizing, automatic-size, display-event, cell-resize and hidden-layout gates pass.
The iOS 5 compile has no errors.

iPhone 6, plain cells, microseconds (previous round in brackets):

| Items | Resize, PST | Resize, native | Cold layout, PST | Cold layout, native |
| ---: | ---: | ---: | ---: | ---: |
| 200 | 355 (991) | 624 | 9,261 (9,823) | 11,962 |
| 1,000 | 481 (3,383) | 569 | 3,117 (5,126) | 3,179 |
| 5,000 | 1,208 (15,694) | 615 | 2,147 (12,520) | 1,815 |
| 20,000 | | | 4,513 (46,020) | 1,941 |

Scroll (about 215-235 us) and reload (about 810-830 us) are flat. A resize at 5,000 items is now
1.2 ms against native's 0.6 ms (it was 34.6 ms two rounds ago); cold layout at 20,000 items is
4.5 ms against 1.9 ms. The remaining growth is the per-item work that is left (the section still
runs one pass over the items to count a row, and cell and view bookkeeping), roughly 0.2 us per
item. Not yet remeasured: variable-size and self-sizing sections, which still build a row object
per row and an item object per item.

### Round 94: variable-size and self-sizing sections measured against item count

Same phone and probe shape as round 92 (`scaling-all.m`), but with a
`collectionView:layout:sizeForItemAtIndexPath:` delegate instead of a fixed item size, and then
with `estimatedItemSize` set as well. Microseconds.

**Variable size (delegate reports 40-70 pt heights).** This corrects round 92's guess that
variable-size sections still scale badly: they do not, and they are close to native.

| Items | Cold, native | Cold, PST | Scroll step, native | Scroll step, PST | Reload, native | Reload, PST |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 200 | 13,781 | 8,269 | 309 | 290 | 3,970 | 2,784 |
| 1,000 | 10,226 | 12,755 | 273 | 175 | 14,434 | 10,996 |
| 5,000 | 36,782 | 38,302 | 309 | 230 | 75,016 | 50,651 |

Both engines are O(items) here because both ask the delegate per item, so the delegate call
dominates and PST is at or better than native on every measurement except cold layout at 1,000
items. The per-row object cost that mattered for fixed sizes is buried under that.

**Self-sizing (`estimatedItemSize` plus the delegate).** A real difference, in where the work
happens rather than how much:

| Items | Cold, native | Cold, PST | Scroll step, native | Scroll step, PST |
| ---: | ---: | ---: | ---: | ---: |
| 200 | 9,674 | 12,618 | 627 | 247 |
| 1,000 | 6,632 | 14,356 | 1,356 | 244 |
| 5,000 | 18,418 | 54,128 | 6,109 | 248 |

Native measures lazily: its scroll cost grows with the data set (627 to 6,109 us per step) and its
cold cost stays low. PST measures every item in one pass during layout, so its scroll cost is
flat (about 245 us) and its cold cost is 2.9x native's at 5,000 items. This is the same design
difference behind the known stepped-self-sizing geometry mismatch, and it is not a matter of
making one loop faster: matching native's scroll cost profile would mean measuring only what is
about to become visible, which changes when cells are created, when
`preferredLayoutAttributesFitting` runs, and therefore the content height that the existing
self-sizing gates check. Not started; it needs its own round with the self-sizing gates as the
safety net.

### Round 95: after rounds 90-92, PST is at or below native on every workload measured except one

**Standard harness** (`PSTCollectionPerfHarness`, paired PST/native, median of three launches on
the iPhone 6, iOS 10.3.3, arm64). Above 1 is slower than native; round 84 in brackets:

| Workload | Now | Round 84 |
| --- | ---: | ---: |
| Cold, 200 items | 0.77 | 1.06 |
| Idle x8 | 0.77 | 0.75 |
| **Scroll x10** | **1.03** | 1.08 |
| Reload | 0.94 | 0.96 |
| Batch insert/delete | 0.63 | 0.67 |
| Item-size change | 0.80 | 1.15 |
| Bounds change | 0.74 | 0.95 |
| Multi-section cold | 0.79 | 1.07 |
| Multi-section scroll x6 | 0.82 | 0.87 |

**Heavy-cell benchmark** (`tests/heavy-cell-bench`, two engines in one binary, 15 pairs, median of
two runs that agreed within 0.03). Round 88 in brackets, where item-size was the standing failure:

| Labels per cell | Item-size change | Scroll |
| ---: | ---: | ---: |
| 0 | 0.69 (2.14) | 0.95 (1.01) |
| 1 | 0.78 (1.93) | 0.89 (0.92) |
| 3 | 0.83 (1.70) | 0.83 (0.86) |
| 6 | 0.90 (1.46) | 0.75 (0.78) |

So the item-size gap is closed and reversed. The remaining slower-than-native figure among these
workloads is standard scroll at 1.03, within measurement noise of parity but consistently above 1.

Honest limits, unchanged: this is a synchronous CPU microbenchmark on one iPhone 6, not frame
delivery, not iOS 6 hardware, and the cells are plain views or plain labels. Self-sizing still
measures everything up front (round 94) and its scroll/cold profile differs from native's.
Nothing has been published.

### Round 95 (continued): iOS 5 device re-check after the layout rework; device status

The layout code changed substantially in rounds 90-92 (windowed attribute query, row reuse,
compact fixed-size rows), so the display-event sequence was re-run on the iPod touch 3
(iOS 5.1.1) as an app and compared with the native oracle: **still matches** (45 lines,
`compare-display-events.py`). Combined with round 92's geometry dump on the same device (agrees
with the simulator within single-precision printing), the iOS 5 route has no detected regression
from the rework.

Device status, since the objective names three devices: `idevice_id -l` lists the iPod touch 3
(`c5f61927...`) and the iPhone 6 (`2775f7a9...`), plus `00008130-001C0D5811D2001C`, which
`ideviceinfo` identifies as an iPhone 16 Pro on iOS 27.0.1 — not a test target and not touched.
The iPod touch 5 (`39a2bacad9a5524e7a6a46ae031f1bea6249d2ab`) is still **not connected**: its
iproxy listener on port 2227 is stale (`Device ... not found`), so the Apple iOS 6/7 hook route
remains verified only on the simulator, as stated in earlier rounds. That iPhone 16 could serve as
a second real-hardware native oracle, but it is the user's personal phone with a current iOS and
no role in the Apple 6-9 route, so it was left alone.

### Round 96: checking the "faster than native" claim instead of trusting it

A claim that PST beats native needs the work compared, not just the clock. Three checks on the
iPhone 6, fixed 320x58 items, 200 items, 20 scroll steps of 37 pt:

**(1) Same visible output.** `indexPathsForVisibleItems` after every step is **identical** for
native and PST, step for step (same rows, same order). The layout result agrees, which the
geometry and display-event gates already said.

**(2) Same work?** No, and not in PST's favour on cell creation:

| Counter over 20 steps | native | PST |
| --- | ---: | ---: |
| `cellForItemAtIndexPath:` | 17 | 14 |
| `prepareForReuse` | 11 | 13 |
| `willDisplayCell:` | 14 | 14 |
| `didEndDisplayingCell:` | 13 | 13 |
| `layoutAttributesForElementsInRect:` (layout's own) | 2 | 20 |

Native creates 3 more cells over the same scroll and PST queries its layout's attributes 18 more
times. So PST's advantage is not "same work done quicker" and not "skipping the query".

**(3) Deferred work?** Giving native (and PST) the chance to finish work outside the timed block
does not remove the gap: with `CATransaction flush` after each step the ratio stays 0.85-0.87,
with a run-loop turn 0.83-0.91, with both 0.81-0.93, and with a real window attached (rendering
involved) 0.81-0.85. `layoutIfNeeded` alone: 0.85-0.87. Timed work simply is not being hidden by
deferral.

**So what does "faster" mean here?** For a minimal workload - plain cells, fixed size, no
prefetching, no self-sizing, no decorations, no safe-area insets, no focus engine, no drag and
drop - the synchronous layout path in PST costs about 15 percent less CPU than UIKit's. Part of
that is that UIKit does more per pass and creates more cells; part is that a smaller
implementation has less bookkeeping per cell and per layout. It is *not* evidence that PST is a
better collection view: on self-sizing, where native measures lazily and PST measures everything
up front, native is **2.9x faster** in cold layout at 5,000 items (round 94, 18.4 ms against
54.1 ms). The honest summary is workload-specific: PST is competitive to modestly ahead on simple
fixed and delegate-sized layouts, well behind on self-sizing, measured as CPU on one device
without frame pacing, GPU or rendering in the figure.

### Round 97: the Apple route runs on real iOS 6 hardware; iOS 6 performance baseline

The objective's longest-standing caveat is gone: the hooks that give Apple's own `UICollectionView` the
modern API now have a hardware run. iPod touch 5 (iPod5,1), **iOS 6.1.3 (10B329)**, armv7f, CoreFoundation
793.0 (below the 1140 threshold), reachable on iproxy 2227.

`vendor/UIKitBackports/Tests/apple_route_ios6_device_test.m` plus
`run-apple-route-ios6-device.sh` build an armv7 app (runtime at its iOS 5.0 floor, app at 6.0), install
it over SSH, run it and check 12 properties. All pass on the device:

| Check | Result |
| --- | --- |
| iOS 9 supplementary accessors installed | PASS |
| iOS 10 prefetching installed | PASS |
| `willDisplayCell` once per visible cell | PASS, 10 callbacks for 10 visible |
| `willDisplaySupplementaryView` for a header | PASS, 1 callback |
| `visibleSupplementaryViewsOfKind:` returns the header | PASS |
| `indexPathsForVisibleSupplementaryElementsOfKind:` | PASS, [0, 0] |
| no prefetch while stationary | PASS, 0 paths |
| prefetch announces items ahead of a forward scroll | PASS, 7 paths |
| prefetch does not repeat at the same position | PASS |
| self-sizing drives content height | PASS, 16020.0 (200 x 80 + 20 header) |
| self-sized cell takes its preferred height | PASS, {0, 20; 320, 80} |
| layout attributes `transform` round-trips | PASS |

The "once per visible cell" row is the one that matters most: it shows the hooks are strictly additive
and do not double-deliver on top of UIKit's own pass.

**Performance baseline on the same device and OS** (`tests/ios6-native-baseline`, paired PST/native,
9 pairs, median, 200 items, 20 scroll steps): PST/native **1.02** (layoutIfNeeded only), **1.02**
(+CATransaction flush), **1.02** (+run-loop turn), **1.02** (+both), and **1.01-1.03** with a window
attached. Visible cells and `cellForItem` counts were identical (10 and 14) in every mode. So on iOS 6.1.3
hardware the PST route and Apple's collection view cost the same in this benchmark.

**Route selection, verified rather than assumed** (`tests/route-selection-probe.m`): a deployment-target 5.0
build run on iOS 6.1.3 creates a `PSTCollectionView` whose superclass is `UIScrollView`, with
`isKindOfClass:UICollectionView` 0, while Apple's `UICollectionView` is present and usable alongside. The
route is fixed when compiling; the design rationale (upstream's reparented wrappers break Swift casts) is
in the selection note above.

Still not verified: iOS 7 (no 7.x device), and animated updates on the Apple route.

### Round 98: animated updates on the Apple route (verified), and a runner fix

The device gate grew three animated checks, run against UIKit 6.1.3 with the hooks installed: an
animated insert of five rows, then an animated delete of five. All pass:
`animated insert completes`, `animated insert applies new item count` (10,270 = 205 x 50 + 20),
`willDisplay for cells that arrive in the animation` (10 -> 15), `visible cells sane after animated
insert`, `animated delete completes`, `animated delete applies new item count` (10,020 = 200 x 50 + 20),
`no willDisplay regressions after animated delete`. That closes the "animated updates untested on the
Apple route" note.

The first run reported FAILED while the app had in fact passed. Two runner bugs, both fixed: the app
inherited a default-buffered stdout, so a slow run lost its output, and the script `cat` the result file
after a fixed 8 s while the two animations take longer, then grepped an incomplete file. The test now
sets `setvbuf(stdout, NULL, _IONBF, 0)` and the runner polls for the `RESULT:` line (up to 40 s) instead
of sleeping a fixed time. Worth remembering when adding device gates: a fixed sleep is a flaky grep.

### Round 99: what "inject so it swaps in natively" would take

Asked whether the routes could swap automatically the way the Auto Layout backport does. First, a fact
worth having measured rather than assumed (`nsclass on the iPod touch 3, iOS 5.1.1, PST runtime loaded):

    class named UICollectionView exists at runtime: 1
      name=UICollectionView superclass=PSUICollectionView_
      instance=UICollectionView
      UICollectionViewCell exists: 1; LayoutAttributes: 1

So on iOS 5 the process already exposes classes **named** `UICollectionView`, `UICollectionViewCell`,
`UICollectionViewLayoutAttributes`, created by PST's constructor through
`objc_allocateClassPair(PSTClass, "UICollectionView", 0)` (the map in `PSTRegisterClasses`). Class names
are not the obstacle. The obstacle is that a class created at runtime has no linker symbol, while code
compiled against Apple's declarations references `_OBJC_CLASS_$_UICollectionView`, which iOS 5's UIKit
does not export: dyld would fail to bind it (or bind a weak import to nil).

Three ways to close that gap:

1. **Patch iOS 5's UIKit itself** so it exports the classes. That means editing a framework inside the
   dyld shared cache on the device. Highest blast radius of anything in this project (every app on the
   device depends on it, and a mistake leaves the device unbootable). Not worth it: the same runtime
   behaviour is reachable in-process.
2. **Ship the engine as a dylib that defines the symbols** - build the PST classes under the UIKit names
   and link the app `-flat_namespace` (or load it with `DYLD_INSERT_LIBRARIES`). On iOS 5 dyld binds the
   app's `UICollectionView` references to that dylib. Native precedence on iOS 6+ is **not automatic**:
   the controlled retest below shows it depends on the dependency order, and even the successful order
   leaves a duplicate-class warning. This is the design
   that actually does what was asked, and it is what upstream PST approximated with
   `class_setSuperclass` (this kit compiles that out). Costs: renaming the vendored classes for that
   build, flat-namespace linking (distribution compatibility not assessed), a second symbol
   definition per class, and re-running every gate on both routes. It also changes what a class symbol
   means per OS, which is exactly the kind of indirection the compile-time choice avoids on purpose.
3. **App-level indirection** - `NSClassFromString(@"UICollectionView") ?: NSClassFromString(@"PSTCollectionView")`
   behind a protocol. No injection, works today, one binary, PST on 5 and native on 6+. Loses Swift's
   typed API and the compiler's availability lowering.

The Auto Layout backport needs none of this because its API lives on classes that exist on every OS and
is purely additive (`UICInstallMissingMethods` copies absent selectors); a collection view needs a whole
engine that is absent on iOS 5. Recommended order if a single artifact is wanted: (3) as an additive
helper, and (2) only as a deliberate spike on a branch, accepted against the existing gates on the
iPod touch 3 and the iPod touch 5.

### Round 100: earlier loader-spike conclusions (superseded by the controlled retest below)

A 30-line spike tested the only assumption behind option 2 from round 99: that a flat-namespace binary
linking a dylib which defines `UICollectionView` would resolve to that dylib on iOS 5 and to Apple's
class on iOS 6+, giving one artifact with PST on 5 and native on 6+. Built `engine.m` (defines
`@interface UICollectionView : UIScrollView`, imports only `UIScrollView.h` so the modern SDK does not
collide) into `SpikeEngine.dylib` with `-install_name @executable_path/SpikeEngine.dylib`, linked the app
`-flat_namespace` against it, and ran the identical bundle on both devices.

* **iOS 5.1.1: works.** `class=UICollectionView superclass=UIScrollView`, `resolved to the injected
  engine: 1`. The symbol binding idea is sound on the OS that lacks the class.
* **iOS 6.1.3: froze the device.** No output, no crash report (so a hang, not a clean abort), SSH alive
  but SpringBoard wedged; it needed three `killall -9 SpringBoard` attempts before the process count
  went 19246 -> 19295 and the UI came back. Two Objective-C classes with the same name in one process
  has undefined selection according to the runtime warning, but this run did not establish that the
  duplicate classes caused the freeze. The earlier claim of a proven deadlock was incorrect.

**Correction (retest, same round):** the freeze does **not** reproduce as a duplicate-class effect. The
retest added a control app with the same flat-namespace linkage and the same dylib that defines
**nothing** Apple ships (`SpikeDummyEngine`). The control ran and printed its result, and then the device
froze again as well; the duplicate-class build produced no output either time. So the earlier
attribution to two same-named ObjC classes is **not supported**. The subsequent claim that the freeze
tracks flat-namespace linkage was also not established; the controlled persistent UI test below works. That needs its own investigation on a
throwaway device before anything is concluded about dyld binding - the previous paragraph's strong claim
is withdrawn.

What the spike did establish: on iOS 5.1.1 a flat-namespace binary resolves `UICollectionView` to a
definition supplied by a loaded dylib, which is the mechanism option 2 depends on. What it did not
establish: that the same process survives on iOS 6+ with two definitions present.

Practical consequence either way: flat-namespace experiments froze this device twice, so they are not
something to keep running on the test hardware. Option 2 stays **unproven and unattractive**, not proven
impossible. Keep the compile-time route selection (two builds from one tree, as the objective specifies);
if a single artifact is genuinely required, prototype app-level indirection (option 3), which needs no
symbol tricks and can be verified with the existing gates.

### Controlled retest: loader identity bug fixed in the spike; persistent native GUI works

The earlier freeze attributions were premature. A normal persistent flat-namespace control with a
harmless dylib, root view controller/window, and a normally returning launch callback reached active
state and its delayed main-queue callback. The user confirmed Home and touch worked. The old direct
root-SSH launch had left `anonymous.Spike` (PID 19170) running after bundle deletion and repeated
resprings; this process was terminated. No claim is made that this alone proves the cause of every
reported UI freeze.

A non-UI diagnostic then isolated the actual **symbol-binding defect** without creating an application:

| Dependency order | iOS 5.1.1 | iOS 6.1.3 |
| --- | --- | --- |
| Fallback before UIKit | Earlier spike selected fallback | Compiled reference selects fallback; runtime lookup selects UIKit: different Class objects |
| UIKit before fallback | Both references select fallback | Both references select UIKit |

The checked-in `tests/runtime-selection-spike/build.sh` builds positive and negative probes. On both
physical iPods the UIKit-first probe exits 0 and agrees with runtime lookup. On iOS 6 the engine-first
negative exits 2, detecting the split identity. Sources, build commands and limits are in that test's
README. Fresh executable paths were used for the final runs after overwriting an old installed path
caused one SSH launch to terminate; both devices remained reachable.

The corrected **persistent UI app** uses UIKit-first dependencies, a real root controller/window,
proper collection-view initialisation with a layout, normal launch callback return, and mobile-user
SpringBoard launching. It neither exits during launch nor deletes itself while running. On iOS 6.1.3
it logged: direct/runtime identity agrees; native class selected; real native cells laid out; active;
delayed main-queue callback; real button tap; normal backgrounding on Home. The user confirmed normal
input and Home operation. SpringBoard's PID stayed 19547, so no recovery respring was needed.

This fixes the demonstrated loader-order bug and the test setup, **not the shipping route**. A duplicate
Objective-C class warning still says class selection is undefined, even with the successful order.
The stand-in implements no collection engine on iOS 5. Full PST class-family binding, Swift subclasses,
casts, protocols, metadata, deployment packaging and different library dependency graphs remain to be
proved before any automatic-route mode is enabled. No UIKit/shared-cache/system-file patch was made.

### Round 101: same binary passes hierarchy and typed Swift metadata checks on both iPods

Extended the isolated runtime-selection spike, not the production engine. Seven class stand-ins model
collection view/reusable view/cell/layout/flow layout/attributes/controller. `hierarchy` passes 21
checks on each device: all direct/runtime class pointers agree; all seven choose the fallback on
5.1.1 and native UIKit on 6.1.3; cell/reusable and flow/layout inheritance agree; app-defined cell,
flow and controller subclasses inherit from the canonical runtime classes. No GUI process is created.

The typed Swift probe also passes on both devices using the **same armv7 iOS-5-targeted binary**:
`Swift typed metadata result=0`. It defines Swift cell and flow subclasses of test-only imported
classes whose `objc_runtime_name` is UIKit's name. Runtime metatype casts, a negative unrelated-type
cast, Swift and ObjC protocol conformance and ObjC superclass checks all pass. The types are looked up
at runtime before casting so the checks are not compile-time-folded subtype tests. Build scripts and
sources live in `tests/runtime-selection-spike`; the Swift script stages its own runtime dependency
closure rather than changing anything in `/usr/lib` on either device.

One manual packaging run failed before main because the concurrency runtime dylib was omitted; the
checked-in script follows transitive dependencies and the final build ran successfully on both iPods.
Linker warnings about existing compatibility archives' iOS-7 minimum tags and newer autolink candidates
remain recorded in the test README; passing this metadata probe is not general runtime verification.

**What this establishes:** an isolated UIKit-first linkage experiment can retain these typed Swift
subclasses/casts while selecting a fallback on iOS 5 and native classes on iOS 6. The earlier blanket
claim that runtime selection necessarily loses Swift typing was too strong.

**What is still unproved:** the full PST implementation under native class symbols, actual subclass
instances/ivar layout and overrides, the production importer/public UIKit spellings, cell reuse and
modern API parity through this new route, and arbitrary dependency graphs. Duplicate-class warnings
still occur on iOS 6. The shipping compile-time route has not been changed or published.

### Round 102: real PST/native engine selection with one persistent app, and visual inspection

The isolated build now uses the actual PST implementation. A generator copies the sources to a new
build directory, adds UIKit `objc_runtime_name` attributes to the eight public classes, and exports
native spellings for the header/footer/automatic-size globals. It changes no original runtime sources.
The build-only runner and persistent app are under `tests/runtime-selection-spike`.

The full implementation passed the class-identity/hierarchy probe on both physical devices. More
importantly, the **same real app bundle** passed 15 checks on iOS 5.1.1 and iOS 6.1.3: fallback selected
on 5/native UIKit on 6; canonical class pointer; visible cells; actual app cell subclass ivars and label
content; reusable-view casts; 320x50 cell bounds; 10,000-point content size; scroll away/back; reuse and
layout subclass overrides; willDisplay delivery. Counts were created/reused/layoutQueries/willDisplay
10/15/5/25 on iOS 5 and 5/20/4/25 on iOS 6. Both processes reached active state and remained responsive;
the user confirmed button and Home operation on both devices. SpringBoard did not require a respring.

The user then asked for screen inspection. Both displays were captured without launching another GUI
process, using the legacy `UIGetScreenImage` API (the ordinary screenshotr service was unavailable
because no developer disk image was mounted). Visual inspection showed a real **fixture styling**
difference: native iOS 6's collection background showed black around the white 280x40 UILabel inside
each 320x50 cell. The fixture now explicitly uses a white collection background and clear labels; no
engine defaults were changed. Both recaptured screens show clean white lists, and the app logs the
same collection frame (320x240), cell/content size (320x50), and label frame (8,0,280,40). The iPod touch
5 still runs the old test bundle in legacy 320x480 compatibility mode; its capture has letterboxing
and reduction, which should not be mistaken for collection-row frame differences.

This is stronger than the stand-in test but not shipping integration. Swift instance layouts and
overrides over the full engine, native/PST protocol identity, modern API gates through this route,
the production importer, deployment packaging and duplicate-class warnings still need work. The
existing compile-time route remains unchanged; no UIKit/shared-cache files were patched or published.

### Round 103: actual Swift cell instances survive runtime engine selection

The same iOS-5-targeted `SwiftCellRoute.app` bundle passes 21 checks on both physical iPods. Cells are
real Swift subclasses over the full generated PST/native class family, not metadata stand-ins. Stored
UInt64, String, Array and UILabel state survives creation, layout, four scroll destinations and reuse;
Swift `prepareForReuse`/`layoutSubviews` overrides run, runtime casts and custom Swift/ObjC protocol
checks succeed, label content and frames match, and `willDisplay` is exact initially and for each
arriving index path. Counts: 10 created/15 reused/5 layout queries/25 displays on iOS 5; 5/20/4/25 on
iOS 6. Both reach active state and SpringBoard PIDs remain unchanged.

A useful fixture bug was caught during count review: the first Swift app linked a separate hook source
as well as `libswiftUIKit`, which already contains/installs the hook runtime. It delivered 50 callbacks
on iOS 6; a weak `willDisplay > 0` assertion passed despite this discrepancy. The final build links no
second hook copy and the strengthened exact-count assertions pass with 25 on both devices. The
build-only runner, Swift cell implementation, imported test declarations and driver generator are
under `tests/runtime-selection-spike`.

Limits: imported Swift class spellings are test aliases with native runtime names, not the production
UIKit importer path. These custom protocols are not UIKit delegate/prefetch protocol identity tests.
Instance destruction, broader subclasses, modern self-sizing/prefetch/supplementary APIs through this
new route, arbitrary dependency graphs and duplicate-class warnings remain unverified. Shipping route
selection is unchanged.

### Round 104: native protocol identity and Swift casts verified in the isolated route

A non-UI test reproduced a protocol bug in the generated engine: its classes had native names but
its data-source/delegate/flow-delegate/prefetch protocols retained PST runtime names. The negative
probe failed all 14 checks on iOS 5 and 12 of 14 on iOS 6 (the native controller conformed to its SDK
protocols). Working callback selectors had hidden a real identity/conformance mismatch.

The isolated generator now gives those four protocols native `objc_runtime_name` attributes too;
no vendor runtime header was changed. The Objective-C identity/conformance probe passes 14 checks on
each iPod, and the existing 21 class-hierarchy checks still pass. A combined non-UI Swift/ObjC probe
then passes **24 checks on each device with the same binary**: canonical protocol pointers/names,
ObjC source conformance, Swift casts of an ObjC source to all four native-named protocols, Swift
source casts and conformance to both SDK and generated declarations, and selected controller
conformance. Test sources and build-only runner are under `tests/runtime-selection-spike`.

The Swift declarations are still test aliases, not the production public importer path; this test
does not create a collection or prove real Swift delegate/prefetch dispatch. Captured command-line
stderr also reveals duplicate private PST helper/wrapper classes between `libswiftUIKit` and the
separate generated fallback, in addition to public UIKit duplicates on iOS 6. Private names must be
isolated and instance/API gates rerun before treating this arrangement as safe. The shipping route
remains unchanged and nothing has been published.

### Round 105: private engine classes isolated from the Swift overlay and instances reverified

The isolated generator now assigns unique `RouteEngine` runtime names to fourteen private helper and
wrapper classes, including the private Ext class declared in an implementation file. The compiler
therefore emits distinct class symbols too, while source identifiers/import file names remain intact.
All declaration counts are checked; no original vendor/runtime sources or packaged overlay were edited.

The combined non-UI Swift/ObjC protocol test now passes **52 checks on both devices**: the previous 24
protocol checks and 28 new image-provenance checks. Every isolated helper originates in the generated
fallback library, and no original private helper name originates there. Captured stderr is empty on
iOS 5; on iOS 6 it has exactly the eight expected public UIKit/fallback class warnings, with no private
PST/PSUI/RouteEngine collision warnings. This directly verifies the private collision fix rather than
inferring it from successful callbacks.

The real Swift-cell app was then rerun using the **same previously verified Swift executable** with the
isolated engine dylib under a separate bundle/identifier. Both iPods again pass 21 instance checks and
report 25 exact willDisplay callbacks. Created/reused/query/display counts remain 10/15/5/25 on iOS 5
and 5/20/4/25 on iOS 6. Both reach active state without a respring; SpringBoard PIDs remain 7512/19547.

Remaining limits: public duplicate-class selection, production importer/public UIKit spelling, modern
API parity through this generated route, and arbitrary dependency graphs. The existing shipping route
is still unchanged and nothing was published.

### Round 106: modern API feature gate passes through both selected engines

Added a build-only persistent device gate using the original Apple-route assertions, adapted by a
generator rather than altering the historical source. The exact same iOS-5-targeted app/dylib bundle
passes **21 checks** on both physical iPods, selecting real PST on 5.1.1 and native UIKit on 6.1.3.
Coverage: provider/canonical identity; cell and header willDisplay; visible supplementary view/path
queries; stationary/forward/nonrepeating prefetch (0/7/no extra paths); uniform preferred fitting to
height 80 and content height 16020; affine rotation a=.878/b=.479; animated insert/delete completions
and resulting item counts/content heights. Both animation callbacks report called with finished=YES.

The first adaptation exposed a harness problem rather than establishing a runtime failure: it deferred
Run onto the main queue but retained nested CFRunLoop waits for animation completion. Both engines
failed those checks. The final generated driver returns to the event loop, sequences delete from the
insert callback via dispatch_async, tracks callback-called separately from finished, and has an
8-second timeout. Both then pass without timeout. It has a real root controller/window, returns
normally from launch, retains assign delegates/data sources through failure paths, removes fixtures
before showing results, and remains alive rather than exiting/removing a foreground app bundle.

No shipping runtime fix was needed for these assertions. This gate is feature coverage, not evidence
that the whole modern API surface matches iOS 27. Variable/stepped self-sizing, fitting priorities,
prefetch cancellation, exact animated event order and modern APIs with the Swift overlay together
remain unverified through this generated route. Public duplicate classes and the production importer
also remain unresolved. Neither system UIKit nor the existing shipping selection was changed.

### Round 107: measured fitting-call reduction, with stepped geometry mismatch left explicit

Added a shared native/PST JSON trace for 60 variable-height items (30+2*index), estimate 200x40,
viewport 200x120, no prefetch, steps y=0/300/600/900/1200/back-to-0. It records actual fitting calls and
proposals, data-source requests, measured paths, visible paths, content size, offset and all item
frames. These are work/geometry measurements, not FPS or wall-clock performance claims.

Before the fix, initial geometry matched UIKit but PST fitted 11 times versus native's 8. Internal
measurement invalidation cleared every cell's stability, including frames just confirmed unchanged.
PST now preserves confirmations across internal measurement invalidation **only for an unchanged full
proposal frame**. Explicit invalidation clears them, and a newly configured cell forgets its path's
confirmation. Subclass invalidateLayout overrides still run, and scoped preservation state is restored
with @finally. A shifted origin is not incorrectly treated as stable merely because size is unchanged.

The shared trace now measures **8/8 initial fittings**, with the same initial frames, 4 requests each
and content height 1980. Returning to the start still fits each of the four newly configured cells.
The initial-only fitting budget is an optional gate; the runner does not label stepped parity as passing.

The larger mismatch is unchanged and precisely reproduced: at y=300 native/PST content heights are
2434/2556 and visible paths are [8,9,10,11]/[7,8,9,10]; at y=1200 they are 3201/3398.18 and
[25,26]/[22,23,24]. Fifty-six item frames differ after each step. Native preserves different unmeasured
proposal ranges while PST replaces them with its global running mean. The trace supports that cache
policy distinction; it does not yet establish a full replacement algorithm. Source comments no longer
claim that PST's stepped proposal policy already matches UIKit.

Verification: visible/offscreen sizing mutation gate, sizing-delegate geometry gate, first-layout
proposal gate, and a new four-case stability gate pass against iOS 27. The stability gate covers explicit
invalidation, changed proposal origin and returning-cell reconfiguration. During its development, an
initial preferred height equal to estimate (80) showed a separate native observation: after another
cell fitted to 50, native row 0's attributes became 50 despite its earlier 80 report, while PST retained
80. That edge case remains unresolved; the isolated stability regression starts the first item at 90
instead, so it tests invalidation without pretending that separate initial-cache difference is fixed.

The rebuilt armv7 engine also passes the persistent **21-check modern API gate on each physical iPod**
with both animated callbacks finished=YES and unchanged SpringBoard PIDs. No simulator-only fix was
accepted without an iOS 5 build/run. No iPhone 6 run or hardware speedup claim is made this round. The
broad goal, stepped geometry, public duplicates and production importer integration remain incomplete.

### Round 108: controlled native cache model, not a guessed shipping fix

Extended the shared trace with viewport/step/final-offset inputs and optional layout-query/invalidation
logging. The matrix covers viewports 60/120/240, steps 100/150/300/600, and a reverse visit to y=450
from y=1200, in addition to the original trace. The logging subclass is checked against the ordinary
native flow layout: all six snapshots' frames, fitting sequence, requests, visibility, content size
and offset must be identical before its events can support the model. This check passes in all six
configurations; instrumentation was not assumed transparent merely because it logged plausible events.

For this one-column 60-item fixture, the native events support a precise model: retain actual reports;
after a coalesced preferred invalidation batch, assign the running mean to unmeasured items starting
one item before the earliest invalidated index, preserving earlier estimates. A replay of the native
public events reproduces **all 2160 item heights across 75 invalidation batches** in the six traces.
At y=300, native batches [9,10] then [8] then [11], so proposal ranges start at 8, 7 and 10. This explains
why item 7 retains mean 39.4286 while later unmeasured items use 41, instead of PST's one global mean.

This is a model of observed cache responses, not a complete layout algorithm: replay consumes native
invalidation batches and fitting reports; it does not predict those batches, multi-column/section
behaviour, pixel-rounded origins, or arbitrary preferred-size functions. PST's measurement batching
also differs. No runtime policy is patched from this limited fixture. The matrix mode now checks the
native model reproducibly, and the initial-only fitting budget remains separately scoped. The next
implementation needs row-aware/multi-column evidence and a bounded measurement schedule, rather
than simply replacing PST's global mean with an untested per-item heuristic. Shipping code and device
state are unchanged this round; no hardware performance or completed parity claim is made.

### Round 109: grid counterexamples distinguish previous-row caching and changed reports

The trace now accepts fixed item width and records full rectangles. Four two-/three-column
configurations compare ordinary and instrumented native layouts with widths 90/60 in a 200-point
viewport, heights 60/120/240 and scroll steps 100/120/200. Full rectangles, fitting sequence, requests,
visibility, content size and offset match with instrumentation in all cases.

Eight competing response models are compared explicitly. Two-column cases alone are ambiguous, but
three-column cases reject updating from the previous item or merely the row containing that item.
Updating from the **previous whole row** and caching a new report **only when it differs from the
proposal** reproduces all **1440 native item heights** in these four fixtures. One three-column case
has 219 height errors if every report is cached instead. The checked diagnostic requires both this
winning response model and counterexamples rejecting the naïve alternatives; it is not a PST parity
gate. The older one-column fixtures do not distinguish the report-caching alternatives.

The equal-proposal distinction also explains the earlier observation at the cache-response level:
in the three-column/60-high fixture, item 2 first returns its 34-point proposal, yet its snapshot
attributes subsequently use estimate 35.2. On returning later it reports 34 against a changed proposal
and is then retained at 34. This is observed layout-attribute behaviour, not a claim about every live
cell frame or an algorithm inferred from disassembly.

PST grid differences remain explicit. For width 60/viewport height 120, initial native/PST content is
810/766 with 57 rectangles differing; after y=200 it is 1011/1151. Width-90 fixtures can have equal
content heights yet still differ in 4 or 6 initial rectangles. The single-column initial geometry and
8-fitting budget still pass; the six-case one-column response matrix still passes too.

This rejects an unsafe per-item cache patch before shipping it. The supported next prototype is a
compact row-range cache with changed-report means, followed by full measurement-scheduling/rectangle
checks before promotion. Variable widths, incomplete rows, multiple sections, horizontal flow, native
batch prediction and pixel rounding remain outside these fixed-width models. No production runtime,
physical-device state or published artifact changes this round.

### Round 110: compact row-range prototype tested, not promoted

Implemented the response model in an **isolated generated source copy**, leaving the original flow
layout unchanged. The new test generator adds contiguous C-struct breakpoints stored in NSMutableData,
binary-search lookup, previous-row suffix updates, coalescing/truncation on backward updates, and
clearing on explicit invalidation/reload. It offers changed-only and all-report variants for A/B
comparison. No per-unmeasured-item dictionary is added. The trace exposes the prototype's record count;
the one-column run stores 2 through 6 records, and a reverse visit to y=450 truncates 6 records to 4.
These are record counts, not claimed allocations or latency measurements.

The changed-only prototype preserves initial 8/8 fitting calls and exact initial geometry. At y=300,
visible paths improve from PST [7,8,9,10] to [8,9,10,11], matching native; cumulative requests improve
10->9 (native 8), stage fitting calls 15->12 (native 8), and content height 2556->2518.33 (native 2434).
But later content errors are mixed and visible paths still differ: at y=1200 the prototype shows
[23,24,25] versus native [25,26]. Fifty-three item frames still differ. The native invalidation
response model alone is not sufficient when PST supplies different measurement batches.

The isolated candidate passes the initial-only fitting budget, four-case stability gate,
visible/offscreen mutation gate and sizing-delegate geometry gate. Grid A/B traces still differ in
51–60 rectangles in some changed-only stages. For width60/viewport120, changed-only differences by
stage are 56/53/51/51/51/51, while all-report differences remain 57 throughout. Other grids remain
ambiguous or mixed. These are not passing parity results and no timing/FPS claim is made.

**Promotion rejected:** retain the reproducible prototype under tests, not in the production runtime.
The next work is measurement scheduling/coalescing and full rectangle verification, plus the still
uncovered variable-width/section/horizontal cases. The generator copies only simulator sizing sources
and tests, not sibling device runtime projects, and installs nothing. No device, shipping selection,
compiler or published toolchain is changed this round.

### Round 111: scheduling prototype reaches exact baseline rectangles, not complete parity

Added isolated one/two/half-batch scheduling variants. They use iterative relayout with a scoped
reentrancy guard, six attempts per path, a 256-pass transaction cap and a latched budget-hit diagnostic;
no recursive per-cell relayout stack is added. Fresh candidates are prioritised spatially, confirmed
candidates are deferred until fresh work is processed, and all variants remain under the test generator.
A deliberately nonconverging cell terminates after 18 fitting calls with the expected budget flag and
without its 500-call emergency escape. Ordinary traces never hit either bound.

Ablation matters: fixed one- and two-cell batches still differ in 52–53 stepped rectangles. Processing
half the fresh candidates matches the baseline's fitting counts at all six steps, unlike those
controls. But it is **not established as UIKit's general scheduling algorithm**: the larger grid has
coalescing/order counterexamples, and the current spatial priority differs in some warm cases.

Separate switches isolate two other effects: centering unequal-size items within a row (PST was top
aligned), and rounding self-sizing origins to screen pixels/content size to points while broad-phase
queries admit the rounding fringe. A changed-only/half-batch/estimated-stability/center/pixel candidate
matches **all 360 baseline rectangles to 1e-6**, content heights, visible paths and fitting counts
(8/8, 8/8, 6/6, 6/6, 4/4, 4/4). The exact gate rejects the otherwise similar raw-coordinate control,
so the result is not merely the older half-point tolerance. Fitting order and equal data-source work
are not claimed: final baseline requests are PST 24 versus native 20.

Three of four grid configurations also match every rectangle exactly at all six snapshots, but can
still perform extra fitting/data-source work. The width60/viewport120 grid matches initially and at
y=200, then has 33 wrong rectangles at y=400 and later; an additional fitted path changes the mean.
Native and prototype ordering also differ there. Thus the combined prototype is **not promoted**.

The latest isolated candidate passes explicit-invalidation/changed-origin/returning-cell stability,
visible/offscreen mutation and sizing-delegate geometry gates. New trace fields expose pass/budget
state, and an analyser keeps exact baseline requirements separate from failing grid diagnostics. No
hardware run, latency/FPS result, production runtime change, compiler change or publication is claimed.
The next work is to isolate centering/quantisation and resolve fresh-cell creation/priority/coalescing
rather than treating a useful half-batch heuristic as the finished native scheduler.

### Rows: default within-row centering now matches UIKit (verified on device)

Native flow layout centers unequal-size items on the row's scroll axis; PST pinned them to
the top/leading edge. A new independent gate (`tests/flow-row-centering.m`) covers 16
variable-size cases (vertical and horizontal scroll, padded and unpadded sections, 1/5/6/7
items, including an incomplete final row) with no estimates and no scheduling prototype.

Result: stock UIKit 6.1 on the iPod 5 passes all 16 cases, the previous PST engine failed 12,
and the fix makes both routes produce **byte-identical frame matrices**. The fix is confined to
`PSTGridLayoutRow` and only changes the default alignment option value (1); other private
option values keep the former top/leading behaviour. Re-verified afterwards: visible/offscreen
sizing mutation, four-case stability and sizing-delegate geometry gates all still pass.

### Row layout: hoisted per-item property reads (measured on iPod touch 3)

`PSTGridLayoutRow layoutRowAndGenerateRectArray:` re-read `self.section`, `self.itemCount`,
`self.items` and several section properties on every loop iteration, each an Objective-C message.
A sampled profile of a 5,000-item self-sizing cold layout put roughly two thirds of the time in
`updateItemsLayout`, mostly `layoutRow`. The reads are now taken once per row. Behaviour is unchanged.

Verified: the 14-scenario geometry golden recorded from the committed sources matches exactly, plus
the 16-case centering, stability, mutation, delegate-sizing and first-layout-proposal gates.

Measured on the **iPod touch 3 (iOS 5.1.1)**, same device, old versus new PST, median of 3 launches
(`tests/selfsizing-scaling.m`, self-sizing with and without a size delegate):

| Case, 5,000 items | Old | New | New / old |
| --- | ---: | ---: | ---: |
| No delegate, cold | 1458.9 ms | 1148.4 ms | 0.79 |
| No delegate, reload | 2388.3 ms | 2019.7 ms | 0.85 |
| Delegate, cold | 832.1 ms | 682.3 ms | 0.82 |
| Delegate, reload | 954.8 ms | 800.3 ms | 0.84 |

Every cold, scroll and reload case measured 0.79-0.88 of the old time, except two near-zero scroll
steps (about 2.5 ms) that did not move. The simulator agrees (cold 5,000 items 5.9 -> 4.7 ms).

**What this does not show.** Native UIKit 6.1.3 on the iPod touch 5 (with the backport hooks installed,
since stock iOS 6 has no `estimatedItemSize`) measured about 38 ms cold at 200, 1,000 and 5,000
items without a delegate, and PST on the iPod touch 3 about 58, 239 and 1,148 ms. These are
different devices, so this is a comparison of shape, not a ratio: the Apple route's cost does not grow
with item count in this probe, and PST's does. PST still measures every item up front, so the
self-sizing gap documented in round 94 remains open and this change only makes the same algorithm
cheaper. The two routes also do different work (native with hooks: 50 cell requests and 100 fitting
calls at cold layout; PST: 10 and 19), which is unexplained. A paired same-device comparison needs the
iPod touch 5 to run PST and native in one binary.

Stock iOS 6.1.3 aborts in this probe without the hooks (`estimatedItemSize` does not exist there).

### Same-device self-sizing ratios on the iPod touch 5, and a correction

PST and the Apple route (native UIKit 6.1.3 plus the backport hooks) now both ran
`tests/selfsizing-scaling.m` on the **same iPod touch 5**. Ratio = PST / native, below 1 means PST is
faster. Median of three repetitions in one run per engine; PST launched separately, so this is not an
interleaved pairing.

| Items | No size delegate: cold | scroll | reload | With size delegate: cold | scroll | reload |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 200 | 0.56 | 0.31 | 0.77 | 1.00 | 0.72 | 0.97 |
| 1,000 | 2.43 | 1.38 | 3.24 | 1.16 | 0.69 | 1.10 |
| 5,000 | **11.29** | **6.63** | **15.55** | 1.24 | 0.57 | 1.12 |

So PST is faster at 200 items, roughly at parity with a size delegate (0.57-1.24), and **much slower
without one at 1,000 and 5,000 items** (up to 15.6x on reload).

**Correction.** Earlier notes (round 94 and the performance summary) say PST "measures every item up
front". The fitting counts say otherwise: PST made 19 `preferredLayoutAttributesFitting` calls and 10
cell requests at cold layout regardless of item count, the same order as the visible set. The cost
that grows is the O(items) layout rebuild: a self-sizing section builds one `PSTGridLayoutItem`, one
`NSIndexPath` and one dictionary lookup per item, and lays out every row, even though only the visible
cells were measured. The per-item cost on the iPod 5 is about 85 us.

**Caveat on the native column.** The Apple route's no-delegate cost is flat (about 38 ms from 200 to
5,000 items), which is what a uniform-size fast path looks like. It is plausible, though not proven,
that the hook installs the estimate as `itemSize`, so native lays out a uniform grid and its content
height uses the estimate for unmeasured items. If so this column is not doing the per-item work PST
does, and a flat curve there is cheap rather than equivalent. Where a delegate supplies real sizes both
engines do per-item work and the ratios are close to 1, which supports that reading.

**What would fix it.** Keep unmeasured items in the compact fixed-size representation and store only
the measured items as sparse overrides, so a rebuild is O(rows plus measured items) instead of
O(items). Rows holding a measured item need a full row layout; the rest can be uniform. This touches
`PSTGridLayoutSection`, row alignment and the proposal cache, and must keep the stepped-geometry
traces and the centering matrix passing. Not started.

### Correction: the "no delegate" native column above is not self-sizing; Apple-route gap found

The probe now prints the content height at cold layout. On the iPod touch 5 (iOS 6.1.3, Apple's
`UICollectionView` plus the backport hooks), **without a delegate the layout is not self-sizing**:

| Items | iOS 27 simulator (real self-sizing) | Apple route on iOS 6.1.3 | PST on iOS 6.1.3 |
| ---: | ---: | ---: | ---: |
| 200 | 10,933 | **2,000** | 10,880 |
| 1,000 | 54,667 | **10,000** | 54,400 |
| 5,000 | 273,333 | **50,000** | 272,014 |

2,000 for 200 items is the default 50x50 `itemSize` in a six-column grid, so `estimatedItemSize` was
ignored. The cause is in `UICCollectionViewDisplay.m`: self-sizing works by injecting
`collectionView:layout:sizeForItemAtIndexPath:` into the delegate's class, and `UICInstallSizeHook`
returns immediately when the collection view has no delegate. iOS 8+ self-sizes with no delegate.

Consequences, stated plainly:
- **The 1.0x-15.6x "no delegate" ratios in the previous section are invalid.** They compared PST's real
  self-sizing against a fixed grid on the Apple route. The flat ~38 ms native curve was a uniform-grid
  fast path, not lazy measurement. The earlier hypothesis was right and the previous section's
  "unexplained 100 vs 19 fitting calls" is explained: the grid is 50 pt cells, so 50 are visible.
- **The "with delegate" columns are valid.** Both engines do real per-item work there: PST/native
  0.57-1.24 on the same iPod touch 5, content heights identical (11,564 / 57,982 / 289,970).
- **Open defect on the Apple route (iOS 6-9):** `estimatedItemSize` without a delegate does not
  self-size. The existing device test sets a delegate, which is why it passed. A fix needs the layout to
  receive per-item sizes without an app delegate, for example an internal delegate that the `delegate`
  getter hides, which has side effects on scroll-view delegate forwarding. Not fixed; needs its own
  design and a test that leaves the delegate nil.

The earlier statement that PST "measures every item up front" was already corrected: the cost that
grows is the O(items) layout rebuild, not item measurement.

### Fixed: Apple-route `estimatedItemSize` with no delegate (iOS 6/7), and the first valid ratios

`UICInstallSizeHook` returned early without a delegate, so Apple's flow layout never asked for item sizes
and `estimatedItemSize` was ignored (see the correction above). The layout is now shown an internal
`UICInternalSizeDelegate`, only while it prepares itself. `UICollectionView -delegate` is overridden on
that class (never on `UIScrollView`) and returns the internal object only when all of these hold: the
real delegate is nil, a `prepareLayout` for that same view is on the stack, and the layout is
self-sizing. Application code, scroll-view callbacks and anything outside the layout never see it, and
it implements one selector so every other flow-layout delegate query is answered NO.

New test `Tests/nil_delegate_selfsizing.m` (persistent app) leaves the delegate nil. The **before** build
(original runtime) fails 3 of 10 on the iPod touch 5, content height 2,000 against the 12,000 expected;
the **after** build passes 10 of 10 (12,000; delegate getter stays nil; a delegate assigned later
receives scroll callbacks and sizing survives it; removing it again also works; a layout without an
estimate is unchanged). The 21-check modern-API gate still passes on both the iPod touch 3 and iPod
touch 5, with SpringBoard PIDs unchanged.

**First valid same-device ratios without a delegate**, iPod touch 5, content heights now equal
(10,880 / 54,400 / 272,014 on both). Single run each, not interleaved; PST/native:

| Items | Cold | Scroll | Reload |
| ---: | ---: | ---: | ---: |
| 200 | 1.36 | 0.83 | 1.02 |
| 1,000 | 1.51 | 1.01 | 1.21 |
| 5,000 | **1.50** | 0.81 | **1.28** |

With a size delegate, as before: cold 0.99-1.26, scroll 0.70-0.72, reload 0.95-1.14. So PST is
**about 1.5x slower than the Apple route on cold layout and 1.1-1.3x on reload at 1,000+ items**, and
faster or equal on scroll. This replaces the earlier invalid 11x-15x figures. Those were a fixed grid
against real self-sizing, not a PST defect. The remaining cold gap is O(items) layout rebuild cost, the
same shape as the delegate case, and is a real but modest target.

Limits: the internal delegate depends on UIKit 6/7 asking the delegate during `prepareLayout`; it was
verified on iOS 6.1.3 only, not iOS 7 or on the iPhone 6. Ratios are single runs on one device and the
cell is a trivial subclass.

### Self-sizing rebuild without a size delegate: sparse overrides instead of one lookup per item

A profile of the 5,000-item no-delegate cold layout put 10.4% in `pstSizeForSelfSizingItemAtIndexPath:`
and a further 8-9% in the per-item objects it feeds. With no size delegate every unmeasured item takes
the same proposal, so the layout now seeds every item with that proposal once and applies the few
measured sizes by walking the measurement dictionary, instead of building an `NSIndexPath` and doing a
dictionary lookup for each of 5,000 items. With a delegate each item must still be visited, because
the lookup records the app's seed, so that path is untouched. Sizes produced are identical.

Verified identical to the previous commit: the 14-scenario geometry golden, the centering, stability,
mutation, delegate and first-layout gates, and **6 of 6 stepped traces byte-identical** (frames, content
height, visible paths, request counts and fitting sequences for one-column and 2-3 column grids).

Same device, previous commit versus this change, median of 3 repetitions (this / previous):

| Device, no delegate | 200 items cold | 1,000 cold | 5,000 cold | 5,000 reload | 5,000 scroll |
| --- | ---: | ---: | ---: | ---: | ---: |
| iPod touch 3 (iOS 5.1.1) | 0.90 | 0.81 | 0.79 | 0.78 | 0.75 |
| iPod touch 5 (iOS 6.1.3) | 0.82 | 0.75 | 0.77 | 0.93 | 0.90 |

Against the Apple route on the iPod touch 5 (PST this change / native with hooks, no delegate):

| Items | Cold | Scroll | Reload |
| ---: | ---: | ---: | ---: |
| 200 | 0.84 | 0.66 | 0.85 |
| 1,000 | 1.20 | 0.73 | 0.99 |
| 5,000 | **1.15** | 0.75 | **1.23** |

Cold went from 1.50x to 1.15x and reload from 1.28x to 1.23x at 5,000 items. PST is faster on scroll at
every size and faster on everything at 200 items. It is still 15-23% slower on cold layout and reload
at 5,000 items, because every rebuild still allocates and links 5,000 item objects and lays out every
row. Removing that needs a compact representation for the unmeasured majority of items.

Limits: native column is a single run, PST a median of 3 in a separate launch; the cell is trivial;
iPhone 6 not run.

### Row alignment resolved once per section, not three dictionary lookups per row

After the sparse-override change, the next profile of the no-delegate 5,000-item reload showed
`layoutRowAndGenerateRectArray:` at 32% of samples, and inside it `NSDictionary objectForKey:` as the
largest single callee (214 of 919 samples). Every row looked up the common-row alignment, the last-row
alignment and the vertical-alignment option in `rowAlignmentOptions`, though they are identical for all
rows of a section. `PSTGridLayoutSection` now reads them once when `rowAlignmentOptions` is set and
exposes `commonRowAlignment`, `lastRowAlignment` and `centersItemsAcrossRow`; the row reads those.
Defaults for a nil dictionary are unchanged (alignment 0, centering on).

Verified identical to the previous commit: the 14-scenario geometry golden, centering (16 cases),
stability, mutation, delegate and first-layout gates, and **6 of 6 stepped traces byte-identical**.
Simulator, no delegate, 5,000 items: cold 4.2 -> 3.3 ms, reload 6.4 -> 5.4 ms.

On hardware (median of 3; this change / previous commit, no delegate):

| Device | Cold 5,000 | Reload 5,000 | Scroll 5,000 | Cold 1,000 |
| --- | ---: | ---: | ---: | ---: |
| iPod touch 3 | 0.79 | 0.84 | 0.86 | 0.79 |
| iPod touch 5 | 0.80 | 0.76 | 0.77 | 0.80 |

**PST versus the Apple route on the iPod touch 5** (no delegate, content heights equal; PST median of 3
against a single native run, so not interleaved):

| Items | Cold | Scroll | Reload |
| ---: | ---: | ---: | ---: |
| 200 | 0.72 | 0.57 | 0.73 |
| 1,000 | 0.96 | 0.60 | 0.81 |
| 5,000 | **0.92** | 0.57 | **0.94** |

So in this probe PST is at or below the Apple route at every size and metric. Combined with the sparse
override change, cold at 5,000 items went from 1.50x to 0.92x and reload from 1.28x to 0.94x.

This is a single synthetic workload with a trivial cell and no delegate; with a size delegate the
earlier ratios (cold 0.99-1.26, reload 0.95-1.14) have not been re-measured since these two changes and
should be before any claim of parity there. The native figure is one run. The iPhone 6 was not run.

### Fixed: inserts outside the viewport were given cells, willDisplay and data source requests

`updateWithItems:` decides whether an inserted item is on screen by testing its start and final
frames against the visible rect. When the layout has no initial attributes for the item, `startAttrs`
is nil and its frame reads as `CGRectZero`, which touches the visible rect whenever the view is
scrolled to the origin. So an insert far below the viewport was treated as visible: PST created a cell,
sent `willDisplay` and called the data source for it, none of which UIKit does. A profile of the batch
scenario showed 5 such requests per insert of 5 items, and the visible cells themselves were also
re-created.

The start rect now counts only when start attributes exist. New test `tests/batch-insert-visibility.m`
runs nine insert scenarios on iOS 27 UIKit and PST (far below at the top, far below while scrolled,
inside, just past the viewport edge, above while scrolled, a delete plus insert mix, into an empty
collection, and at the end of a short list) and compares requests, `willDisplay`, visible items and
content height. **Before: 6 of 9 match (three scenarios issued 2-5 extra requests and display events).
After: 9 of 9.** The golden geometry, centering, stability, mutation, delegate, first-layout, display
order, supplementary display, prefetch lifecycle, empty-collection, hidden-item, cell-resize and
attribute-snapshot gates all still pass.

The harness's `batch-insert-delete-200` ratio (PST/native, simulator, 3 runs) moved from 1.10-1.17 to
1.04-1.09. It is still the only scenario above 1.0; the remaining cost is per-update bookkeeping in
`updateWithItems:` (index-path key objects and dictionaries for 9 visible cells). This is a simulator
number; no hardware measurement of batch updates yet.

### First hardware measurement of batch updates: paired PST and Apple route on the iPod touch 5

`tests/paired-device-bench` compiles one benchmark twice (native `UICollectionView`, then PST with distinct
class names) into one app, so both engines run on the same device in one launch, alternating order,
median of 9 pairs. Fixed 320x58 cells, no delegate, no self-sizing. The Apple route here is stock iOS
6.1.3 with the backport hooks installed. iPod touch 5, build of commit `5febbfa1`:

| Workload | Items | Native | PST | PST / native |
| --- | ---: | ---: | ---: | ---: |
| Cold layout | 200 | 2.99 ms | 2.56 ms | 0.86 |
| Reload | 200 | 2.73 ms | 2.12 ms | 0.78 |
| Insert 5 + delete 5 (two batches) | 200 | 40.7 ms | 17.1 ms | **0.42** |
| Cold layout | 1,000 | 3.19 ms | 3.24 ms | 1.02 |
| Reload | 1,000 | 12.79 ms | 3.14 ms | 0.25 |
| Insert 5 + delete 5 (two batches) | 1,000 | 99.7 ms | 47.0 ms | **0.47** |

So on real iOS 6.1.3 hardware PST is faster than the Apple route on batch updates (about 2.1-2.4x),
reload and 200-item cold layout, and at parity on 1,000-item cold layout. **This contradicts the
simulator, where batch insert/delete was the one scenario above 1.0 (1.04-1.09).** The simulator
runs iOS 27 UIKit as the oracle; iOS 6's batch machinery is much slower (40 ms against 0.25 ms in the
simulator for the same scenario), so the simulator ratio does not predict this device. Native reload
growing from 2.7 to 12.8 ms between 200 and 1,000 items is the O(items) Apple rebuild; PST's compact
fixed-size rows keep reload flat.

Found while building it: `+[UIView performWithoutAnimation:]` is iOS 7 API, and the first build aborted on
the iOS 6 device with an unrecognized selector until the bench used `setAnimationsEnabled:`. Any
benchmark or test that targets iOS 6 must avoid it.

Limits: one device, one cell type, animations disabled so the batch figures are bookkeeping and layout
cost, not animation cost; the cells are trivial. Self-sizing and delegate-sized layouts are measured
separately above. No iPhone 6 run and no iPod touch 3 run of this bench (PST only would not be a
ratio).

### Paired self-sizing with a size delegate on the iPod touch 5 (closes the open ratio)

The paired bench now also runs self-sizing with `estimatedItemSize`, a size delegate and a cell whose
preferred height varies. Same iPod touch 5, one launch, both engines alternating, median of 9 pairs
(5 for the 5,000-item rows). Build of the current sources, Apple route with the backport hooks.
PST / native:

| Items | Cold | Reload | Insert 5 + delete 5 |
| ---: | ---: | ---: | ---: |
| 200 | 0.89 | 0.53 | 0.64 |
| 1,000 | 1.01 | 0.60 | 0.69 |
| 5,000 | 1.05 | 0.82 | not run |

So with a size delegate PST is at parity on cold layout (0.89-1.05), and faster on reload (0.53-0.82)
and on batch updates (0.64-0.69). This supersedes the earlier non-interleaved figures for the same case
(cold 1.03/1.32/1.03, reload 1.07/1.22/0.97), which compared a PST median of three repetitions against a
single native run and overstated PST's cost, most visibly at 1,000 items. The interleaved numbers are the
ones to use.

Together with the fixed-size table above, every paired same-device workload on the iPod touch 5 now has
PST at or within 5% of the Apple route, and mostly well below it. The slowest cell is 5,000-item
self-sizing cold layout at 1.05, which is within the variation seen between runs.

Limits: one device; the Apple route is stock iOS 6.1.3 plus the backport hooks, not a native iOS 8
implementation; the cell is trivial apart from its preferred size; animations are disabled in the batch
rows; 5,000 items has 5 pairs rather than 9. No iPhone 6 run. The no-delegate self-sizing case uses the
non-interleaved figures above and has not been re-run in the paired app.

### Paired self-sizing without a delegate, and the full paired table (iPod touch 5)

The no-delegate self-sizing case, the one that depends on the nil-delegate fix to the Apple route, now
runs in the paired app too. Same iPod touch 5, one launch, both engines alternating, median of 9 pairs
(5 at 5,000 items). PST / native:

| Items | Cold | Reload | Insert 5 + delete 5 |
| ---: | ---: | ---: | ---: |
| 200 | 0.84 | 0.44 | 0.57 |
| 1,000 | 0.97 | 0.50 | 0.64 |
| 5,000 | 1.04 | 0.85 | not run |

This replaces the earlier non-interleaved no-delegate figures (cold 0.84/1.20/1.15, reload 0.85/0.99/1.23)
that compared a PST median of three against a single native run and overstated PST's cost at 1,000 and
5,000 items. Content heights matched in the earlier unpaired run of this case.

**Complete paired table, iPod touch 5, PST / native, interleaved** (this run; the earlier fixed-size and
delegate figures reproduce within a few hundredths):

| Workload | 200 | 1,000 | 5,000 |
| --- | ---: | ---: | ---: |
| Fixed size, cold | 0.86 | 1.03 | |
| Fixed size, reload | 0.77 | 0.07 | |
| Fixed size, batch | 0.54 | 0.50 | |
| Self-sizing + delegate, cold | 0.85 | 1.01 | 1.07 |
| Self-sizing + delegate, reload | 0.52 | 0.51 | 0.76 |
| Self-sizing + delegate, batch | 0.66 | 0.71 | |
| Self-sizing, no delegate, cold | 0.84 | 0.97 | 1.04 |
| Self-sizing, no delegate, reload | 0.44 | 0.50 | 0.85 |
| Self-sizing, no delegate, batch | 0.57 | 0.64 | |

Across 21 measured cells PST ranges 0.07-1.07 of the Apple route. The cells above 1.0 are cold layout at
1,000 and 5,000 items (1.01-1.07), which is parity within run-to-run variation; no cell is more than
7% slower. The 0.07 is fixed-size reload at 1,000 items, where the Apple route's rebuild cost grows with
item count (2.7 ms at 200, 29 ms at 1,000) and PST's does not.

Limits, unchanged: one device; the Apple route is stock iOS 6.1.3 plus the backport hooks; a trivial
cell; animations disabled for batches; 5,000-item rows have 5 pairs and no batch row; and the iPhone 6
(iOS 10.3.3, real Apple implementation of the API) was not run because it is not attached.

### Stepped self-sizing geometry: the exact-geometry scheduler costs 2.6x on cold layout, so it is not promoted

The isolated prototype generator was brought up to date with the current sources (positional proposal
lookup in the sparse seed loop) and given a fresh-candidate order option. It was scored on all ten
stepped fixtures (6 one-column, 4 grid) as the number of item rectangles that differ from iOS 27 UIKit,
over six scroll positions each (3,600 rectangles):

| Source | Fixtures exact | Rectangles differing |
| --- | ---: | ---: |
| Shipping | 0 of 10 | 2,290 (63.6%) |
| Prototype: half-batch, previous-row proposal, nearest-origin order | 8 of 10 | 417 (11.6%) |
| Same, index order | 6 of 10 | worse on grids |
| Same, column-major order | 7 of 10 | worse |

The prototype passes every other gate: geometry golden, centering, stability, first-layout proposal,
display order, supplementary display, hidden items, cell resize, attribute snapshots, mutation,
delegate sizing and the nine batch-insert scenarios. Two fixtures remain inexact: a one-column case at
viewport 60 where fitting order differs for one item, and a three-column grid at viewport 120 where an
item at the end of a row is fitted twice before the row settles.

**But it is slower, and the reason is structural.** Self-sizing no-delegate, 5,000 items, simulator:
cold 3.4 ms (shipping) against 9.1 ms (prototype), reload 5.4 against 9-10 ms; scroll is unchanged.
Matching UIKit's geometry needs UIKit's *batching*: several smaller invalidation batches per layout pass
instead of the shipping code's one or two. Each batch makes PST rebuild every item object and every row
(5,000 of each), and the profile shows 68% of time in `computeLayout` and 80% in the measurement loop,
against about 49% for shipping. UIKit evidently invalidates incrementally, so its extra batches are
cheap.

So the two goals conflict until the layout rebuild is incremental: geometry parity needs more batches,
and speed parity needs each batch to cost O(rows after the change), not O(items). The shipping code
currently trades geometry parity for speed, and that trade is now measured: on hardware it is at or
within 7% of the Apple route, while 64% of rectangles differ from iOS 27 after scrolling.

**Next step if this is pursued:** make `PSTGridLayoutSection` recompute only from the first changed row
(`recomputeFromIndex:` exists but is a stub that invalidates everything), then promote the prototype. The
generator and trace gates are in place to prove the result.

### Packed storage for self-sizing sections: rebuilds are about 8x cheaper

The geometry prototype's cost was structural: every extra invalidation batch rebuilt a
`PSTGridLayoutItem` per item and a `PSTGridLayoutRow` per row (5,000 of each) plus an `NSArray` per row.
A self-sizing section now keeps its item sizes, row boundaries, per-item origins, row origins and row
sizes in five flat C arrays (`preparePackedItems:`, `pstComputePackedRowsWithDimension:`), and the
attribute queries read them directly. The row breaking and the justification, centering and sole-item
arithmetic are the same operations in the same order as the object code, so the geometry is bit-identical.
Variable-size sections that are not self-sizing, and fixed-size sections, keep their existing storage.

Verified: **10 of 10 stepped fixtures bit-identical to the previous commit** (rectangles, frames,
content height, visible items, request counts, fitting sequences and offsets, across 1-3 column fixtures
and a reverse scroll), the 14-scenario geometry golden, and the centering, stability, first-layout,
display order, supplementary display, hidden items, cell resize, attribute snapshot, mutation, delegate,
automatic size and nine batch-insert gates.

Simulator, 5,000 items, no delegate: cold 3.4 -> 0.45 ms, scroll 0.91 -> 0.11 ms, reload 5.4 -> 0.60 ms.
With a size delegate: cold 2.5 -> 1.2 ms, reload 2.8 -> 1.1 ms (the delegate round trips remain). No
hardware measurement yet.

### Promoted: UIKit's stepped self-sizing geometry, now faster than before

With packed storage making a rebuild cheap, the scheduling prototype could be promoted into the runtime.
The measurement pass in `PSTCollectionView` now works as UIKit does: it fits the visible cells nearest
the origin first, about half of the not-yet-fitted cells per step, relayouts between steps, and confirms
the rest last. In the flow layout, unmeasured proposals are kept as a few breakpoints (`PSTProposalRun`)
rather than one value per item: after a preferred-size batch the new running mean applies from one row
before the earliest changed item onward, earlier estimates stay, and a first report equal to its proposal
leaves the item an estimate. Origins are rounded to pixels and the content size to points. The pass is
bounded: at most 6 fittings per cell and 256 passes per transaction. New gate
`run-selfsizing-bounds-test.sh`: a cell that never converges stops after 18 fittings instead of hanging.

**Geometry against iOS 27 UIKit**, over the same ten stepped fixtures (3,600 item rectangles):

| | Fixtures exact | Rectangles differing |
| --- | ---: | ---: |
| Before | 0 of 10 | 2,290 (63.6%) |
| Now | **8 of 10** | **417 (11.6%)** |

Two fixtures remain inexact (a one-column case at viewport 60 where fitting order differs for one item,
and a three-column grid at viewport 120). Every other gate passes: geometry golden, centering,
stability, first-layout proposal, display order, supplementary display, hidden items, cell resize,
attribute snapshots, mutation, delegate sizing, automatic size (now 0 subpixel differences), prefetch
lifecycle and the nine batch-insert scenarios.

**Cost, measured on hardware**, 5,000 self-sizing items, one launch, promoted code against the previous
commit (which had neither packing nor the new scheduler):

| Device, no delegate | Cold | Scroll | Reload |
| --- | ---: | ---: | ---: |
| iPod touch 3 (iOS 5.1.1) | 719 -> 142 ms | 225 -> 16 ms | 1,317 -> 147 ms |
| iPod touch 5 (iOS 6.1.3) | 261 -> 62 ms | 94 -> 7 ms | 511 -> 63 ms |

With a size delegate: cold 0.49-0.58x, reload 0.43-0.45x, scroll unchanged within noise (about 1-3 ms).

**Paired against the Apple route, iPod touch 5** (interleaved, median of 9 pairs, 5 at 5,000), PST / native:

| Items | Self-size + delegate: cold / reload / batch | No delegate: cold / reload / batch |
| ---: | --- | --- |
| 200 | 0.61 / 0.27 / 0.44 | 0.57 / 0.28 / 0.39 |
| 1,000 | 0.51 / 0.22 / 0.37 | 0.30 / 0.14 / 0.30 |
| 5,000 | 0.49 / 0.29 / n/a | 0.21 / 0.15 / n/a |

Fixed-size workloads are unchanged (cold 0.87-1.00, reload 0.07-0.77, batch 0.49-0.55). **No paired
cell is now above 1.0 except fixed-size cold at 1,000 items, which is 1.00.**

Limits: 8 of 10 fixtures exact, not 10; the model is fitted to native behaviour observed on one-column
and fixed-width two- and three-column grids, with unit-size estimates, and is not validated for
multiple sections, horizontal flow, variable widths or sections with headers. The Apple route here is
stock iOS 6.1.3 plus the backport hooks. The iPhone 6 was not run.

### Self-sizing across sections, headers, insets and horizontal scroll: tested, and four defects fixed

The stepped fixtures were all single-section vertical layouts without headers, which is exactly the
coverage the earlier notes listed as unvalidated. A new differential test
(`tests/selfsizing-layouts-trace.m`, `run-selfsizing-layouts-test.sh`) runs six shapes against iOS 27
UIKit and compares what is on screen at four scroll positions: real cell frames, header frames, content
size and the visible set. The shapes: three sections with headers; insets plus line and item spacing; two
sections with narrow items; the same two horizontally; and four sections with small headers.

First run: **0 of 24 steps matched**, and the same on the commits before packed storage, so none of it
was a packing regression. Four independent defects:

1. **Learned sizes leaked across sections.** PST applied the running mean to every later section as soon as
   one section had measured items, so unvisited sections were laid out with the learned size. UIKit keeps
   the original estimate for a section nothing has changed in yet. Proposal breakpoints now apply only
   inside the section they were learned in. This alone moved 578 wrong rectangles to the cross-axis cases.
2. **Non-scrolling-axis content size was wrong.** UIKit reports exactly the viewport's width (vertical
   scroll) or height (horizontal) whatever the items and insets add up to: narrow items, items wider than
   the view, and inset sections all leave it unchanged. PST reported the item or inset-padded extent
   (175, 187, 224, 300 where UIKit says 200). Fixed for every layout, not only self-sizing; the 14-scenario
   geometry golden still passes.
3. **A lone item in a horizontal column was never centered.** The leading-edge alignment offset was applied
   to x in both scroll directions, so horizontal columns ignored it. It now runs along the row in both
   directions, in the object row code and the packed code.
4. **Vertical content height is whole points, horizontal width is not.** A rounding of both axes was
   correct for one and wrong for the other (observed against UIKit; cause not established).

**Result:** 23 of 24 steps exact on screen, **0 of 148 visible cell frames differ**, headers and visible
sets all match. The single remaining step is the first step of the horizontal narrow-item shape, where
UIKit reports a content width of 707.09 while its cells are still being fitted and PST reports 773.09 (a
66-point difference that disappears on the next step). The gate allows that one step and nothing else.
The stepped single-section fixtures are unchanged at 8 of 10, all other gates pass, and hardware cost is
unchanged (5,000 items, no delegate, cold: iPod touch 3 142 -> 144 ms, iPod touch 5 62 -> 65 ms).

**Not matched, and reported rather than hidden:** attribute queries for items that are not on screen
(`layoutAttributesForItemAtIndexPath:` for an item that has never been displayed). UIKit answers those
from a layout it computes lazily and often returns the estimate, whereas PST returns its settled
geometry. 14-42 such rectangles per step differ. This does not affect anything drawn, but code that
queries layout attributes for off-screen items will see different numbers than on iOS 27.

Limits: unit-size estimates and four to five sections of 9-16 items; no footers with content, no
supplementary views other than headers, no decoration views, no section insets that differ per section,
no delegate-supplied spacing, and no right-to-left. iPhone 6 not run.

### Per-section delegate geometry and footers also match

The layouts test gained two shapes with a delegate answering per-section insets, line spacing, item spacing
and footer sizes (different for every section), narrow self-sizing items, vertical and horizontal. Both
match iOS 27 on screen at all four scroll positions: 0 of 62 further visible cell frames differ, headers
and footers and content size match. No code change was needed. The whole test is now **31 of 32 steps
exact, 0 of 210 visible cell frames differing** across eight shapes; the one inexact step is the known
first-step content width of the horizontal narrow-item shape. Footers with content views, decoration
views and right-to-left remain untested.

### The Apple route does not yet match iOS 27's stepped self-sizing geometry (measured on the iPod touch 5)

Everything above about stepped geometry concerns PST. The Apple route (iOS 6-9) has its own self-sizing
scheduler in `UICCollectionViewDisplay.m`, and it was never compared with iOS 27. The same stepped trace
(60 items, estimate 200x40, four viewport/step configurations, six scroll positions) was built as a
persistent app with the hooks installed and run on the **iPod touch 5 (iOS 6.1.3)**, then compared with the
iOS 27 simulator:

| Viewport / step | Rectangles differing per step | Visible set |
| --- | --- | --- |
| 120 / 300 | 0, 56, 56, 56, 56, 56 | differs |
| 60 / 150 | 0, 58, 58, 58, 58, 58 | differs |
| 240 / 600 | 0, 53, 53, 53, 53, 53 | differs |
| 120 / 100 | 0, 0, 0, 49, 0, 0 | matches |

**884 of 1,440 item rectangles differ (61.4%)**; the first layout always matches. Content height is off by
up to 552 points. The fitting counts differ too (for example 15 against 8 calls in one step). This is the
profile PST had before its scheduler was replaced (63.6%), so the same two causes apply: the hook fits every
visible cell in one batch instead of UIKit's nearest-first half-batches, and it applies one global mean as
the proposal rather than a per-section, per-row breakpoint.

So the two routes currently differ from each other: PST matches 8 of 10 stepped fixtures, the Apple route
about 1 of 4. The scheduling half is portable to the hook as is. The proposal half needs the row a changed
item sits in, which the hook cannot read from Apple's layout directly; it would have to be inferred from
item frames (a new row starts when the cross-axis origin does not increase). Not started.

### Apple route: UIKit-order self-sizing in the hook, and why it costs more on iOS 6-9 (iOS 8.1 binary examined)

The hook's measuring pass now fits cells the way PST's does and the way iOS 27 does: nearest the visible
origin first, about half of the not-yet-fitted cells per step, relayout between steps, confirmations last;
unmeasured proposals are breakpoints scoped to the section they were learned in, applied from one row before
the earliest changed item (rows are recovered from item frames, since Apple's layout does not expose them); a
first report equal to its proposal stays an estimate. A per-rebuild snapshot replaces six associated-object
reads and a dictionary lookup per size query with a sorted C array.

**Geometry, iPod touch 5 (iOS 6.1.3) against iOS 27**, four stepped configurations, 1,440 rectangles: before
61.4% differed (884); now 763 differ at the 1e-3 level, of which 478 are sub-third-point origin differences
(the oracle runs at 3x, the device at 2x) and 285 are larger. Three of four configurations are exact within a
pixel, with identical fitting sequences and visible sets. The 60-point-viewport configuration still differs
by more than a point on 57 items per step. Not closed.

**Cost, same device, Apple route (native + hooks), self-sizing, no delegate, cold layout:** 200 items
19 -> 49 ms, 1,000 items 66 -> 170 ms, 5,000 items 307 -> 783 ms (a separate run measured 736 ms), about
2.5x slower than the single-batch fit it replaced, which is exactly why the geometry was wrong. With a size
delegate the change is 1.0-1.35x. PST on the same device is unaffected and is 0.06-0.22x of the Apple route
here, and every gate passes (21-check API gate on both iPods, nil-delegate gate 10/10).

**Where the time goes, measured on the device:** a 5,000-item cold layout runs 5 rebuilds of Apple's layout
and the size hook is called 5,000 times in each (25,000 total) at about 29 microseconds per item per rebuild.
The hook's own work is a binary search; the remainder is Apple's iOS 6 grid engine building an object per item
and row on every rebuild. Matching UIKit's geometry needs UIKit's batches, so the cost is
(number of batches) x (O(items) rebuild).

**iOS 8.1 UIKit (Xcode 6.1.1 simulator SDK, saved under `ios81-ref`) shows why UIKit does not pay this.** Its
flow layout has selectors iOS 6.1's lacks entirely: `_fetchItemsInfoForRect:`, `_updateItemsLayoutForRect:`,
`computeLayoutInRect:forSection:invalidating:`, `rowsInRect:`, `_UIFlowLayoutItem isPositionEstimated`,
`_UIFlowLayoutInfo didUpdateSizeForSection:withDelta:` and `_updateContentSizeScrollingDimensionWithDelta:`.
iOS 6.1 has `_fetchItemsInfo` and `_updateItemsLayout` with no rect and no per-item estimated flag. So iOS 8
lays out only the rows around the visible rect and adjusts the content size by a delta when an item's size
changes, which makes each batch cheap; iOS 6-9's engine rebuilds everything. That machinery is part of the
engine, not a hook point, so the hook cannot reproduce it on top of iOS 6's engine.

**Options that would remove the trade-off:** replace Apple's flow layout engine on iOS 6-9 with PST's
packed engine (the same layout, driven through the UICollectionView API), which already measures 0.06-0.22x of
this cost on the same device; or accept a size threshold. Neither is done.

### Fit order: 9 of 10 stepped fixtures exact on PST, and the Apple route within a pixel everywhere

The one-column fixture that differed (viewport 60) was a fit-order difference. Seven candidate orderings
were scored against all 885 first-pass fit sequences captured from iOS 27 UIKit (750 of them were
multi-fit). None of the simple ones (index, distance from the origin, distance from the query rect)
explained more than 342. The rule that fits, learnt from the data and then verified:

- **One cell per row (or column):** the cell that *spans* the visible origin first, then the cells after
  it, then those before it nearest-first. This explains `[9, 10, 8, 11]` where nearest-top would give
  `[9, 10, 11, 8]`. 452 of 485 single-column sequences, and the remaining misses were one case that
  appears in two traces.
- **Several cells per row:** the cells nearest the visible origin. The same spanning rule scored 20 of 200
  on two-column grids and 0 of 200 on three-column grids, so the two regimes are real, not one rule. Which
  applies is read from the frames.

Applying it in PST took the stepped fixtures from 8 of 10 to **9 of 10 exact**. The one left is the
three-column grid at viewport 120, where native fits `[0,3,1,6,4,7,9,10,2,5,8]` and PST `[0,3,6,1,9,4,7,10,
2,5,8]`: both start with column-major, but native interleaves the columns as each fit changes the next
batch's candidate set. Not explained yet.

The same ordering is in the Apple-route hook. On the iPod touch 5 (iOS 6.1.3) against iOS 27, over four
stepped configurations (1,440 rectangles): **0 differ by more than half a point**, down from 884 (61.4%)
before the hook was changed and 285 larger-than-sub-pixel differences in the previous round; fit sequences
match step for step on all four configurations. The 673 rectangles that are not bit-exact are all below half
a point, which is the oracle running at 3x scale and the device at 2x. All PST gates pass, the 21-check API
gate passes on both iPods and the nil-delegate gate passes 10 of 10.

Limit: this is evidence from five fixture families (1, 2 and 3 columns, vertical scroll). Horizontal
ordering is implemented by symmetry and is covered only by the layouts test, which compares frames, not
fit order.

### Correction: Apple-route fit sequences do not match step for step, and why confirmation order cannot

The previous section said the Apple route's fit sequences "match step for step on all four configurations".
**That was wrong.** It rested on comparing the number of fitting calls per step, not the sequences. Compared
properly on the iPod touch 5 against iOS 27, over the 24 steps that fit anything: the **first pass** matches in
20, and the **whole sequence** matches in only 7. The geometry claim stands (0 of 1,440 rectangles differ by
more than half a point); the sequence claim does not.

What differs is the confirmation pass at the end of a step, for example device `[15,16,17,15,16,17]` against
iOS 27 `[15,16,17,16,15,17]`. The cause was found by reproducing iOS 27's order: it confirms cells in
`NSDictionary` enumeration order of their index paths. Replaying dictionaries of index paths on the iOS 27
simulator gives exactly UIKit's observed orders (`6,1,4,7,2,5,0,8,3` for items 0-8; `16,15,17` for 15-17).
That order is produced by `NSIndexPath`'s hash, which differs between releases: on iOS 27
`hash(item i) = 22 + i * 2^21`, on iOS 6.1.3 `hash(item i) = i + 2`, and the dictionaries enumerate differently
(`16,17,15` for 15-17). The order is therefore a property of the Foundation hash function, not of the
layout, and cannot be reproduced on iOS 6 by iterating the same collection. It could be reproduced by
computing iOS 27's hash and bucket order explicitly, which would couple the runtime to one release's
Foundation internals; not done.

Consequence: any app that logs or depends on the order in which `preferredLayoutAttributesFitting` is called
during the confirmation pass will see a different order on iOS 6-9 and on PST than on iOS 27. The geometry
produced is the same.

### Retraction: the three-column fit-order mismatch is not explained by NSIndexPath hashing

The previous correction suggested that native's interleaved fit order on the three-column fixture
(`[0,3,1,6,4,7,9,10,2,5,8]`) might be the same `NSDictionary` ordering effect as the confirmation pass. That
was an untested guess, and it is wrong. Enumerating the pending set at each batch as a dictionary of index
paths on iOS 27 gives `6,1,4,7,2,5,0,8,3` for the first batch (native fitted `0,3,1,6`), `9,4,7,2,10,5,8` for
the second (native fitted `4,7,9,10`) and `5,8,2` for the third (native fitted `2`). Only the final
confirmation pass follows dictionary order; the fitting batches follow a layout rule that is still unknown.
The three-column fixture therefore remains inexact (9 of 10 stepped fixtures) for an unexplained reason.

### Apple route cost: measured without any hook (iPod touch 5), confirming and sharpening the attribution

The claim that the extra self-sizing cost on iOS 6-9 is Apple's engine and not the hook was inferred from the
hook doing a binary search. It is now measured. A hook-free app (no `UICInstallCollectionViewDisplay`, an
ordinary `sizeForItemAtIndexPath:` delegate) timed one cold rebuild of Apple's flow layout on the iPod
touch 5, best of five:

| Items | Constant sizes | Varying sizes |
| ---: | ---: | ---: |
| 200 | 4.5 ms (22.6 us/item) | 7.4 ms (36.9 us/item) |
| 1,000 | 9.9 ms (9.9 us/item) | 24.3 ms (24.3 us/item) |
| 5,000 | 36.5 ms (7.3 us/item) | 112.8 ms (22.6 us/item) |

Two facts follow. First, **Apple's own engine costs about 23 us per item per rebuild when sizes vary**, on top
of which self-sizing runs several rebuilds per transaction (5 for a 5,000-item cold layout), so about 0.56 s
of the 0.78 s measured for the hooked cold layout is five rebuilds of Apple's engine and the hook's own work
is the remainder. Second, **the engine is 3x cheaper per item when sizes are constant** (7.3 against 22.6 us), so
the cost depends on size variety, not only on item count. PST's packed rebuild of the same 5,000 varying
items measured 62 ms on this device for the whole self-sizing transaction.

This confirms that no change inside the hook can remove the cost; only changing which engine lays the items
out can. That decision remains open.

## How iOS 8.1 UIKit actually implements self-sizing (decompiled; behavioural findings only)

Source: the iOS 8.1 simulator `UIKit` from Xcode 6.1.1 (i386), decompiled headlessly with Ghidra, 362 methods of
`UICollectionView`, `UICollectionViewFlowLayout`, `UICollectionViewLayout` and `_UIFlowLayout{Info,Section,Row,Item}`
(0 failures). The raw output lives outside this repository (`Neocord2-iOS5-Work/ios81-ref`) and is reference
only; nothing below is code, and no decompiled code is to enter the runtime.

**This contradicts the design both routes currently use.** Everything built so far (the PST scheduler, the Apple
route hook) measures cells in a separate pass after layout and fits them in batches chosen to resemble traces.
iOS 8.1 does not work that way:

1. **Measurement is synchronous with cell creation.** `-[UICollectionView
   _createPreparedCellForItemAtIndexPath:withLayoutAttributes:applyAttributes:]` asks the data source for the cell,
   calls `-preferredLayoutAttributesFittingAttributes:` on it, and, if the result differs
   (`isEqual:`) and `-[layout shouldInvalidateLayoutForPreferredLayoutAttributes:withOriginalAttributes:]` says
   yes, asks `-invalidationContextForPreferredLayoutAttributes:withOriginalAttributes:` and calls
   `-invalidateLayoutWithContext:`; only then does it add the cell and send `willDisplayCell:`. There is no
   post-layout measuring loop and no half-batch rule. The batches seen in traces are a consequence of how
   cell creation interleaves with these invalidations.
2. **The layout is lazy.** `prepareLayout` calls `_fetchItemsInfoForRect:` with `CGRectZero`;
   `_layoutAttributesForItemsInRect:` calls it again with the real rect. Each `_UIFlowLayoutSection` keeps a
   `validRect` and `validItemRange`; `computeLayoutInRect:forSection:invalidating:` lays out only the rows in
   or next to the requested rect, extending the valid range as needed. Items outside it carry a per-item
   `positionEstimated` flag.
3. **Unlaid-out sections are estimated by formula**, `updateEstimatedSizeForSection:`: items per row are taken
   from the first row, the section height is `ceil(itemsCount / perRow) * (tallestItemInFirstRow +
   interstice) - interstice + margins + header + footer` (mirrored for horizontal), and that is stored with
   `setEstimatedSize:forSection:`.
4. **A reported size is applied incrementally.** The layout's invalidation-context method calls
   `[_data setSize:forItemAtIndexPath:]`, which updates the item frame, adds the *later items within the valid
   range* to the invalidated list, calls `didUpdateSizeForSection:withDelta:` (which shifts every later section's
   frame by the delta) and `_updateContentSizeScrollingDimensionWithDelta:` (which adjusts the content size and
   records a content-size adjustment). The context it returns has `invalidateFlowLayoutAttributes` and
   `invalidateFlowLayoutDelegateMetrics` both NO, so `-invalidateLayoutWithContext:` does not rebuild the data:
   it only queues index paths to validate. **A size change therefore costs O(rows in the valid range), not
   O(items).** This is why iOS 8's cost does not grow with batches.
5. The entry points `_fetchItemsInfoForRect:`, `_updateItemsLayoutForRect:`, `rowsInRect:`,
   `isPositionEstimated` and `didUpdateSizeForSection:withDelta:` do not exist in iOS 6.1's UIKit (its flow layout
   has `_fetchItemsInfo`/`_updateItemsLayout`, no rect). Whether iOS 7 has them is not known: no iOS 7 UIKit is
   available here.

**What this means.** The earlier "mean of reported sizes", "previous row", "half the pending cells" and fit-order
rules were fitted to a black box and happened to agree on simple fixtures; they are not Apple's algorithm, which
explains why residual mismatches were never explainable. Exact parity needs the algorithm above, and so does
iOS 8's performance: it is incremental. On iOS 6 (and possibly 7) Apple's own engine cannot do this, so a hook
cannot reproduce it there; the layout computation itself has to follow iOS 8's design.

**Not yet done:** an independent implementation of points 1-4, reading the remaining routines
(`_layoutAttributesForItemsInRect:`, `sizeChangedForItem:atIndexPath:inRow:`, the per-item `estimatedSize`
use in `_getSizingInfos`), and verification of it against the iOS 27 oracle. No runtime code changed this round.
