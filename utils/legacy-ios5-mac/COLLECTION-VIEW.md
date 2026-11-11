# Toolchain-native UIKit collection views on iOS 5

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
