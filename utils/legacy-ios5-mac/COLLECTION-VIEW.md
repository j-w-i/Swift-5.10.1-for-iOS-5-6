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
height, offset and cell at the same scenario were not compared on the phone.
