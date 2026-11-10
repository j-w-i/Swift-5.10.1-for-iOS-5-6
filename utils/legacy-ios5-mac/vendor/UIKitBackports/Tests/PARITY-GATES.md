# Native layout conformance gates

Correctness and performance of Auto Layout / UIStackView are release priorities. An optimization is not acceptable merely because views have finite frames or an app stays alive. Known layout differences block publication.

## Required evidence

1. Run `run-direct-update-test.sh NEW_DIRECTORY BOOTED_SIMULATOR_UUID` for native/legacy callback ordering, actual frame solutions, windowed versus detached root selection, content-sized centered stacks and arranged-item fitting. The native fitting reference must be a stack containing the item, not standalone UIView fitting: these have different native contracts.
2. Run the same script with `LSDK_LAYOUT_FIXTURE=native-parity` for real UIKit controls. This is a proper UIKit application with scene adoption, not an unbundled CLI pretending to exercise a full UIKit lifecycle. Compare native and forced-backport output. At present the suite emits 116 normalized observations, including internal progress tracks/fills, slider internals, button/text-field internals, text viewport/content sizes and geometry-setter callbacks.
3. Run `run-direct-stack-tests.sh BOOTED_SIMULATOR_UUID` for the optimized OAStackView path against native UIStackView. Include intrinsic priorities, hidden/insert/remove changes, margins, explicit size preferences, width-dependent wrapping, and spare-height allocation to UIView/UITextView without intrinsic height. The direct path must decline cases whose allocation semantics are not modeled; tight-fitting composites can retain the fast path.
4. Test the actual source-built armv7 runtime in a UIKit app on the iPod. Verify first-use initialization, visible frames, hit-testing, text wrapping/content width, initial and completed progress geometry, cancellation and clean uninstrumented launch. Simulator agreement alone does not prove old UIKit ownership and resize behavior.
5. Rebuild all shipped slices and static qualification, then verify the profile hashes and published downloads. Do not sign or mutate qualified runtime files during tests.

## Fail-closed runner rules

Native/reference and legacy runs are separate app processes. Every run has a fresh output token and must create a completion marker *after* all cases return and stdout flushes successfully. The runner checks required case names before diffing; stale sandbox files, crashes before launch completion, or a helper accidentally omitting a new case must not produce a pass. Source hashes accompany each run. `LSDK_UIVIEW_SOURCE_OVERRIDE` is regression-test-only and hashes the substituted source; it must never be used for release qualification.

## Ownership and geometry invariants

- UIKit-managed text renderers, progress tracks, slider implementation views and button labels are not authoring-time child frames for an ancestor's solver to replay.
- Explicitly opted-in client overlay views must remain eligible for constraint layout.
- Public control setters can clamp geometry. A required constraint dimension must not silently become the control's default intrinsic height.
- Setter notifications needed by ordinary controls must still occur. Compare callback behavior as well as final frames.
- A constraint-update walk is not a layout pass; pending layout work must survive it.
- A stack first used before any unrelated constraint must initialize the bridge itself.
- No-intrinsic axes do not acquire hugging/compression rows just because the view has numeric priority properties.

## Performance evidence and limits

The direct-stack suite checks that 2,000 idle `layoutIfNeeded` calls perform **zero fitting work** and records 2,000 forced-layout and idle timings for native and direct stacks. One simulator run measured native 72.204 ms / 0.116 ms and direct 2.888 ms / 0.102 ms (dirty / idle). This is a tiny matched fixture, not a promise about device application speed. Keep correctness gates separate from noisy wall-clock comparisons; measure device workloads and solver/cached-pass counters before making broader performance claims.

The native frame reporter normalizes to half-points. This is not exhaustive pixel, accessibility, animation, typography, every-OS or every-view-class parity. Full device coverage for armv7s and iOS 6–9 is still absent. Maintain explicit coverage and limitations rather than describing a passing finite suite as universal native equivalence.
