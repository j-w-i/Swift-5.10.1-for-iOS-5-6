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
