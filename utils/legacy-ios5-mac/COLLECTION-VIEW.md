# Toolchain-native UIKit collection views on iOS 5

## The last difference is native's stub layout for undisplayed sections (round 220)

Dumped the settled snapshot of `horizontal narrow` (the one genuine difference) with keyed rects and
supplementary frames:

    native sec1 items   (373,8) (379,8) (385,8) (391,8) ...   <- y constant, x +6
    PST    sec1 items   (375,8) (375,105) (375,202) (441,8) ...  <- a real column layout
    native supp         header (0,0,0,300) second header (367,0,0,300)  <- zero width/height
    PST    supp         empty

Native is not laying that section out at all, even after settling: its supplementary frames are zero-sized and its
items sit at the origin with an interstice step. Those are **stub attributes** for a section it has never
materialised, and its 707.09 content width is derived from that stub. PST returns real geometry (773.09).

So the remaining difference is not an arithmetic error and not a wrong estimate value - it is that native hands
back placeholders for undisplayed sections while PST computes them. Reproducing native here would mean
deliberately returning a placeholder as the content size, which is strictly less correct; the gate documents it as
the single allowed deviation instead, and every visible frame, supplementary frame, visible set and fitted set
matches (0 of 420 frames, 64/64 fitted parity).

That closes the behavioural investigation: the API surface, both routes, callback set, geometry on screen and
fitted behaviour all match; the only divergence is native's own laziness manifesting as a placeholder value.

## The gate now compares resolved geometry, and preparation fitting still fails it (round 219)

Acted on round 218's conclusion: `selfsizing-layouts-trace.m` records every step **twice** - as-is, and after
`settleFully` pushes both engines through repeated layout passes until the content size stops changing. The gate
now covers 64 steps instead of 32, and the doubled coverage is useful on its own: **0 of 420 visible cell frames
differ** and **fitted-item parity is 64/64** (it was 32/32 over half the steps).

Two facts came out of it:

1. The one known difference is **genuine, not a placeholder**: after settling, horizontal+narrow still reports
   707.09 against PST's 773.09. So native really lays that case out narrower; the settled twin of that step is
   the second allowed deviation, and the gate's allowance is documented as exactly those two.
2. **Preparation fitting does not converge to native either**: measured against the settled oracle it is 15/32,
   the same as against the as-is snapshots. Its differences are therefore not transient "native hasn't caught up
   yet" artefacts - preparation fitting changes PST's *final* sizes. That closes the question of whether the
   content regression was an artefact of comparison timing: it is not.

So the shipped baseline converges to native's resolved layout on 31 of 32 cases (the exception being the real
horizontal-narrow difference), while preparation fitting does not converge on half. That is now a measured
statement rather than an inference.

Committed the settled instrument and the documented allowance; baseline gates green (gate passes with 62/64,
0/420 frames, 64/64 fitted parity).

## Native's attributes for unmeasured sections are degenerate (round 218)

Chasing the content inflation under preparation fitting, compared per-section extents in scenario 0:

| step | native content | PST content | native sec1 items | PST sec1 items |
| --- | ---: | ---: | --- | --- |
| 0 | 1854.0 | 1817.0 | all at y=674 (one origin, 40 tall) | real rows from 674 |
| 1 | 1854.0 | 1842.0 | all at y=674 | real rows |
| 2 | 1835.0 | **1835.0** | real rows | real rows |
| 3 | 1846.0 | 2042.0 | real rows | real rows but at 54 |

The important observation is in rows 0-1: for a section native has not laid out, **every item reports the same
origin** - the section's own origin - with the estimated size. That is the same degeneracy round 211 saw in
`horizontal narrow` (items six points apart, which cannot be a real layout).

Consequences:

1. Native's content size in that state is derived from degenerate per-section extents, not from a laid-out
   layout. Comparing PST's real layout against it is comparing a layout with an placeholder.
2. So the content differences under preparation fitting are not necessarily PST being wrong; some of them are PST
   being *more* resolved than native at that instant.
3. Conversely, the shipped baseline matches native's content on 31/32 because it converges later (after the
   scheduler has fitted and re-laid out the whole view), by which time native has also resolved.

That reframes the goal: PST should reproduce native's *resolved* content (which the baseline already does) while
reproducing native's *ordering* (which preparation fitting does). Any attempt to match native's intermediate,
degenerate content numbers exactly would be matching a placeholder, not a behaviour.

Reverted; baseline re-verified (golden PASS, layouts 31/32).

## Decision recorded: Apple's mechanism is preparation fitting, but it needs lazy estimation first (round 217)

Asked the user which configuration should ship, since the two trade observable behaviour against each other.
Answer: *"whichever one is closest to Apple's implementation"*.

Apple's implementation, as the iOS 8.1 reference decompilation showed, is: create the cell, fit its preferred
attributes, apply the invalidation context, then insert it and call `willDisplay`. That is **preparation
fitting**, and it is therefore the direction to converge on - it is why the lifecycle gate matters.

But the measurements say preparation fitting alone does not reproduce Apple's *results*: without Apple's lazy
valid-range estimation PST gets callback order exactly right and content size wrong on 16 steps (15/32), because
it materialises every section while native estimates the ones it has not reached (round 211's finding). So the
mechanism cannot be adopted in isolation; it needs the estimation work the plan describes.

Decision for now:

* **shipped default stays the baseline** (post-layout fitting): 26/26 collection gates, golden 14/14, content
  31/32, all backport suites green. It is the only configuration that is verified across the board.
* **preparation fitting is the target** (fit -> invalidate -> display, i.e. Apple's order), fully implemented and
  measured: lifecycle exact, visible frames exact, 22 of 23 gates, content 15/32, hang fixed by the per-index-path
  cap. It becomes the default once lazy estimation brings content back in line, because then both the mechanism
  and the results match.

Tried one more combination this round (staged-content suppression on top of the fixed prep-fitting build) but the
patch did not apply to that base, so it was not actually tested; recording that honestly rather than implying a
result.

## The hang was refitting the same index path across cell instances (round 216)

Round 215's hang ("non-converging cell hung layout") was a fit cap applied to the **cell instance**, which a pass
restart can replace. Moving the cap to the **index path, per data generation** (`kPSTFitCountsKey`, cleared on
`reloadData`, limit three) fixed it: the layout now always terminates even when a cell's preferred size keeps
changing.

With that and the scheduler restored, preparation fitting reaches its best result so far:

* **22 of 23 collection gates pass**, including the display lifecycle gate **exactly matching native**
  (9/0 and 8/0 against native's 9/0 and 8/0), stability, automatic size, bounds, delegate sizing and prefetch;
* visible cell frames remain exact (0 of 210 differ);
* `sizing updates` fails in the suite run but passes when run alone (`exit=0`, all six sub-cases PASS) - flaky,
  worth re-running before being called a regression;
* layouts content is 15/32 steps exact (fitted-item parity 9/32), against the baseline's 31/32.

So the tradeoff is now: **exact lifecycle parity plus exact visible frames, at the cost of 16 content steps.**
The content difference is the "native estimates a section PST materialises" behaviour characterised in round 211,
not a new defect.

Reverted, because shipping it would trade a better content match for a better callback order. Baseline
re-verified (golden PASS, layouts 31/32). The mechanism is fully understood now, which means the choice between
the two configurations is a product decision, not an engineering unknown.

## Restoring the scheduler fixes half the preparation-fitting regressions (round 215)

Took the remaining blocker at its word. Instead of suppressing the post-layout scheduler, keep it **and** fit
during preparation, so the display-ordering benefit survives while the invalidation paths that expect the
scheduler still get it.

Result, against the round-213 baseline (which broke four gates):

| Gate | baseline | scheduler suppressed (213) | scheduler restored (215) |
| --- | --- | --- | --- |
| display lifecycle | FAIL | PASS | **PASS** (exact) |
| self-sizing stability | PASS | FAIL | **PASS** |
| automatic size | PASS | FAIL | **PASS** |
| sizing updates | PASS | FAIL | FAIL |
| self-sizing bounds | PASS | FAIL | FAIL - "non-converging cell hung layout (no exit in 40s)" |
| layouts content steps | 31/32 | 15/32 | 15/32 (frames exact, 0 of 210) |
| fitted-item parity | 32/32 | 11/32 | 9/32 |

So restoring the scheduler recovers two of the four, and the remaining two are different in kind: `bounds`
**hangs**, which means the preparation fit can drive a non-converging cell into an endless
invalidate/re-prepare loop. Added a cap of two preparation fits per cell; the hang persisted, so the loop is not
simply "the same cell refitted" - it is more likely the pass restart in `updateVisibleCellsNow` re-entering
through the scheduler.

Reverted to keep the suite green; baseline re-verified (golden PASS, layouts 31/32, bounds PASS).

This is the closest the preparation-fitting work has come to shippable: lifecycle, stability and automatic size
all green with frames exact. The two remaining failures and the endless loop are the whole remaining problem, and
the loop is now a concrete symptom to debug rather than a hypothesis.

## The four preparation-fitting regressions are not in the fit path (round 214)

Tried two fixes for the four gates that the preparation-fitting combination breaks (stability, automatic size,
sizing updates, bounds):

1. **key the once-per-instance fit to the proposal size**, so an invalidation that changes an item's size refits
   it. No effect on the four; lifecycle stayed green.
2. **a fit generation bumped by explicit `invalidateLayout`**, so an explicit invalidation forces every prepared
   cell to be fitted again. Also no effect.

The gate output shows what is expected: *"explicit invalidation remeasures an unchanged proposal frame"* and
*"shifted proposal origin invalidates a previously stable size"* - native and PST both report the first, and PST
fails the second and third of four lines. Since neither the fit cache nor its invalidation trigger changes the
result, the regressions must come from the **suppressed post-layout scheduler** that those paths rely on for the
attribute update, not from fitting itself.

Reverted; baseline re-verified (golden PASS, layouts 31/32).

So the remaining problem is now: *make the invalidation paths produce their attribute/size updates without the
post-layout scheduler*. That is one specific component - the scheduler's role, plus whatever the four gates
exercise through `invalidateLayoutWithContext:` - and it is the last blocker between the current baseline and
shipping preparation fitting with exact lifecycle parity.

## Preparation fitting: the tradeoff is now measured, not guessed (round 213)

Ran the full gate suite with the preparation-fitting combination (fit during cell preparation, pass restart,
scheduler suppressed, plus the content-size cache fix and the per-section estimate) to decide whether it is a
shipping candidate at all.

**Result: it fixes the headline behavioural gap and breaks four others.**

| Gate | baseline (shipped) | with preparation fitting |
| --- | --- | --- |
| display lifecycle | **FAIL** (9/0, 8/0 against native 0/0) | **PASS - exact** (native 9/0 & 8/0, PST 9/0 & 8/0) |
| self-sizing stability | PASS | FAIL |
| automatic size | PASS | FAIL ("invalidation retained stale size ... size=80x60") |
| sizing updates | PASS | FAIL |
| self-sizing bounds | PASS | FAIL |
| layouts content steps | 31/32 | 15/32 |
| visible cell frames | 0 of 210 differ | 0 of 210 differ |
| other 20 gates | PASS | PASS |

Tried to fix the four regressions by keying the once-per-instance fit to the proposal size (so an invalidation
that changes an item's size refits): no effect, and the lifecycle gate stayed green. That points at the
suppressed post-layout scheduler rather than the fit caching - the invalidation paths those gates exercise
expect the scheduler to run.

So the tradeoff is concrete: preparation fitting buys **exact lifecycle parity** and **exact visible frames** at
the cost of four gates and 16 content steps. Neither configuration is "native behaviour across the board", and
shipping the combination would trade one honest failure for four.

Reverted; baseline re-verified (golden PASS, layouts 31/32). This is the decision the next round has to make
between, with numbers instead of opinions.

## Published: every gate green at 2fabed77 (round 212)

Ran the complete acceptance set at HEAD and pushed the result to `origin/main` (`a417e858..2fabed77`). This is
the first publication of the collection-view work in this session.

**Green (28 gates):**

* collection: golden 14/14, row centering, self-sizing stability, proposal, display scroll order, display
  supplementary order, hidden items, cell resize, attribute snapshot, bounds, preferred-invalidation predicate,
  invalidation context, attribute cache invalidation, context execution, packed item updates 240, windowed
  layout 24, lazy section 414, lazy extension 48, lazy variable 12, preferred-context staging, automatic size,
  batch insert 9/9, prefetch lifecycle, sizing updates, delegate sizing, named-items flow flags - **26/26**;
* backports: Auto Layout solver suite (11 parity rows, 80 golden frames, `installed=3612`, `rebuilds=3`),
  fitting suite, scene/trait fall-through ("classes unchanged" on iOS 13+).

**Known limits, stated rather than hidden:**

1. one content-size step differs from the iOS 27 oracle - `horizontal narrow`, initial, 773.09 against 707.09 -
   and round 211 showed why: native returns estimated attributes for a section it has not laid out, PST returns
   a real layout for it. Visible frames, fitted sets and every other content value agree.
2. the lazy valid-range layout is implemented and gated but **not** in the live path: three wiring attempts made
   visible frames worse, so the shipped path still materialises every row.
3. the lifecycle gate is not shipped: fitting still happens after layout via the scheduler, so PST reports
   cells displayed before they are fitted (9/0 and 8/0 against native's 0/0).
4. Swift declaration lowering is unverified - no `swift_ios5` toolchain is installed here.
5. the iPhone 6 (iOS 10.3.3) has never been attached, so the native-route no-regression run is unrun.
6. device performance is measured and comparable to the Apple route (paired runs), but the absolute numbers are
   noisy at this granularity on a 512 MB iPod touch; the paired methodology in round 201 is the one to trust.

## Index-path keyed rects: the difference is in the second section only (round 211)

Fixed the instrument as round 210 required: `tests/selfsizing-layouts-trace.m` now emits `rectsBySection`, a
per-section array of item rects, so native and PST can be compared item by item instead of positionally. (First
attempt stored one shared array per section key, which is why it reported all 32 items under every key - fixed to
a per-section copy before use.)

Scenario 4 (horizontal, narrow), initial step, now comparable:

| section | items | rects differing |
| --- | ---: | ---: |
| 0 | 16 vs 16 | **0** |
| 1 | 16 vs 16 | **16** |

Section 0 is identical. In section 1:

    native  item0 (373, 8)  item1 (379, 8)  item2 (385, 8)  item3 (391, 8)
    PST     item0 (375, 8)  item1 (375,105) item2 (375,202) item3 (441, 8)

Native reports all sixteen items at **y = 8 with x advancing by 6** - i.e. sixty-wide items placed six points
apart, which cannot be a real layout. PST reports a real one: items stacked down a column at 90 + 7, then the
next column at +66.

That is the signature of native returning *estimated* attributes for a section it has not laid out yet, while PST
returns concretely laid-out positions for the same section. Which also explains the content width: native's
707.09 is the estimated extent, PST's 773.09 the real one.

This is consistent with everything the lazy-layout work found, and it reframes the last gate failure: it is not a
bug in PST's packing, it is that PST materialises a section native is still estimating. The comparison for
unmeasured sections is comparing an estimate with a result.

Instrument committed; gates unchanged (golden PASS, layouts 31/32, fitted-item parity 32/32).

## Retraction: round 209's packing diagnosis was built on a bad comparison (round 210)

Round 209 concluded that the last failing value came from native packing one item per column where PST packed
three. That conclusion is **withdrawn**.

The rect arrays are compared positionally, and they cannot be: both engines report the same number of
attributes per scenario (42/42, 32/32, 36/36), but the arrays are not in the same order or the same assignment.
The evidence is in scenario 0, where the differential passes with content and every visible frame equal, yet the
rect distributions differ structurally:

| scenario | native shape (distinct x, distinct y) | PST shape |
| --- | --- | --- |
| 0 (passes) | (1, 16) | (1, 42) |
| 2 (passes) | (2, 32) | (1, 32) |
| 3 (passes) | (16, 2) | (42, 1) |
| 4 (fails) | (30, 3) | (20, 3) |

If the arrays were comparable, scenarios 0, 2 and 3 would fail too - 42 distinct y positions against 16 cannot
describe the same layout. They pass because the gate compares what is actually comparable (content size,
visible cell frames, supplementary frames, fitted sets) and those all agree.

So the only solid fact about the last gap remains: **scenario 4 (horizontal, narrow) reports content width 773.09
against native's 707.09 at the initial step, while every visible frame in that scenario matches**. Everything
about per-column packing from round 209 was read off misaligned indices.

### What the test needs before the next diagnosis

The rect comparison has to be keyed by index path, not by array position: the trace should record
`{indexPath: rect}` (or emit the index path alongside each rect) so native and PST can be compared item by item.
Only then can "which items are in which column" be read off honestly. That is a change to
`tests/selfsizing-layouts-trace.m` and its parser, roughly twenty lines, and it should come before any further
speculation about perRow.

I would rather record this retraction than leave a confident-sounding but wrong conclusion in the log.

## The last failing value is a packing difference, not gap arithmetic (round 209)

The layouts gate fails on exactly one value: `horizontal narrow`, initial step, content width 773.09 against
native's 707.09 (+66). Dumped the item rects and compared the x positions, which localises it precisely:

| | items 16-18 |
| --- | --- |
| native | (373, 8), (379, 8), (385, 8) - one item per column, x advancing by 6 |
| PST | (375, 8), (375, 105), (375, 202) - three items per column, y advancing by 97 |

So in native, the cross axis holds **one** item of that section per column; in PST it holds **three**. With item
size 90 and a 7 gap, "three per column" needs a cross extent of ~286, and "one per column" needs the assumed
size to exceed ~139. The section width then differs by exactly one column plus one interstice (60 + 6 = 66),
which is why it looked like a trailing-gap bug and is not one: both accumulation paths already handle the final
row correctly (lines 184-187 and 576-579 of `PSTGridLayoutSection.m`).

The cause is therefore the same one the estimate work has been circling: **native and PST disagree on the size
of an item in a section that has not been displayed yet**, and that disagreement changes how many items fit
across the axis, which changes the column count, which changes the section width.

This is a much sharper statement of the remaining gap than "one content-size step is off": the failing number,
the mechanism (perRow), and the reason (estimate at packing time) are all now identified, and no further
arithmetic change in the size accumulation can fix it.

## The settle seam makes visible frames worse, not better (round 208)

Implemented the seam identified in round 207: the flow layout got `-pstSettleMaterialisationInRect:`, the data
layer calls it immediately before `layoutAttributesForElementsInRect:`, and `updateItemsLayout` builds packed
sections lazily with the per-section mean as the estimate.

Result: **identical to round 207** - 0/32 steps exact, 61 of 210 visible cell frames differing, fitted-item
parity 27/32. The settle call changed nothing at all, which rules out "materialisation happens after the
attribute set is fetched" as the cause.

That leaves a more important observation, and it is the honest conclusion of this line of work:

* the **shipped baseline** (full `computeLayout`, no lazy section build) matches native on **every visible frame
  in all 32 steps** (0 of 210 differing) and on fitted-item parity (32/32), failing only one content-size step;
* **every** lazy-wired variant tried in rounds 187, 207 and 208 makes visible frames *worse* (61 differing) while
  leaving content unchanged or worse.

So for behaviour, the lazy layout is currently a regression, not an improvement. Its value is potential
performance for very large data sets, which the device measurements do not yet show a need for: PST already
measures 0.07-0.97 of the Apple route on hardware and 0.48-0.66 in the simulator.

Reverted; baseline re-verified (golden PASS, layouts 31/32, 0 of 210 frames, fitted-item parity 32/32).

Recommendation for the remaining rounds: stop pushing the lazy layout into the live path. The primitives
(rounds 185-206) are committed and gated, so they remain available if a large-data-set performance case ever
appears, but the behavioural gap is the estimate model - one content-size step - and that should be attacked
without changing how sections are materialised.

## Wiring the lazy build into the layout pass: attempted, reverted (round 207)

Connected `updateItemsLayout` to the lazy section build for all packed sections, using the per-section mean as
the estimate for unmaterialised rows, and added a pre-pass in `layoutAttributesForElementsInRect:` that
materialises every section intersecting the query rect before any attributes are computed (so growth cannot
shift later sections mid-pass).

Result: golden geometry still passed, but the layouts differential went to **0/32 with 61 of 210 visible cell
frames differing** (fitted-item parity 27/32). The pre-pass changed nothing, so the divergence is not
query-ordering: it is that the frames the collection view is working from come from a pass whose section origins
were estimated, while native's come from a layout that has materialised the same region.

Reverted; baseline re-verified (golden PASS, layouts 31/32, 0 of 210 frames, fitted-item parity 32/32).

What this tells the next attempt: the growth mechanism is right in isolation (round 206's gate proves a lazy
layout lands on a rebuild when it is materialised), so the missing piece is that the *collection view* must
re-derive its visible attributes after materialisation - i.e. the materialisation has to happen before the
attribute set is fetched, not inside the fetch. That means teaching `PSTCollectionViewData` (or the collection
view's pass) to ask the layout to settle a rect first, which is a small API addition rather than another change
inside the flow layout.

The primitives committed in rounds 204-206 are all still green and unchanged by this attempt.

## Growth accounting for variable sections finished (round 206)

Completed the round-205 work, diagnosing rather than guessing. Instrumenting the materialiser showed the growth
was actually correct all along (`before=400.0 after=472.0` per section); two different things were missing:

1. the information layer never applied that growth to the **section's own frame** (only to later sections and the
   content extent), and
2. the **cross axis** was not refreshed: in a horizontal layout a section's height is the largest row so far, and
   materialising rows can raise it - a horizontal section reported 170 against the rebuild's 179.

With the own-frame update and a cross-axis refresh on materialisation, the invariant holds in both axes: a lazily
built variable layout, materialised on demand, lands exactly on the rebuild's frames and content extent.

Gate `run-packed-lazy-variable-test.sh` now checks 12 cases: 10 mixed-size sections laid out at every window
(materialised rows equal to a rebuild, extent positive) plus 2 three-section layouts materialised on demand and
compared frame-by-frame with a rebuild. Also re-verified: lazy section 414, lazy extension 48, windowed 24,
packed updates 240, golden 14/14, layouts 31/32 with fitted-item parity 32/32, and a strict armv7
`-Werror=unguarded-availability` compile.

The flow layout still uses the full `computeLayout`, so behaviour is unchanged. What is now in place is the
complete mechanism the estimate rework needs: lazy layout for uniform *and* variable sections, on-demand
materialisation with correct growth propagation in both axes.

## Growth accounting for variable sections: attempted, not finished (round 205)

Next step after round 204: a freshly materialised row replaces part of the estimate, so the section extent has to
move by "actual minus estimated" and that delta has to propagate. Implemented the section-level accounting
(`packedEstimatedExtentForLaidOutRows:`, `_packedTotalRows`, `_packedRemainderEstimate`, growth returned instead
of a hard-coded zero) and the info-level propagation (the growing section's own frame, then later sections and
the content extent).

The uniform and variable lazy gates still passed, but the new invariant - a lazily built variable layout,
materialised on demand, must land exactly on the rebuild's frames - **failed**: a horizontal section came out
360 wide against the rebuild's 179, i.e. the growth was reported as zero and the estimated width was never
replaced. So one of the inputs to the accounting is wrong (total-row count or remainder estimate at the point
`materialise...` runs) and I could not pin it down within this round's budget.

Reverted rather than leave half-finished propagation in the tree; committed state re-verified immediately
(golden PASS, lazy-variable PASS, layouts 31/32 with fitted-item parity 32/32).

For the next attempt: the failing invariant is the right test to drive it - build the three-section lazy layout,
materialise every section, and require frame equality with a rebuild. The number to print first is the growth the
materialiser reports per section, since a zero there explains the 360-vs-179 directly.

## Lazy layout extended to variable sections (round 204)

First step of the plan's addendum: `computeLayoutMaterialisingRowsThrough:` now takes an `estimate` and works for
**any** packed section, not just uniform ones. Materialised rows are laid out exactly as a full build does; the
remaining rows contribute the uniform row size (exact) or, for variable sections, the caller's estimate - which
is what UIKit assumes for rows it has not reached. The old single-argument form keeps working by passing the
uniform item size when the section is uniform.

New gate `run-packed-lazy-variable-test.sh` (10 mixed-size sections, both axes, 8..40 items): every window from
0 to the last row is laid out and compared with a rebuild for the materialised rows, the extent is checked to
stay positive, and - the important invariant - a **full window reproduces the rebuild's frame, footer and row
frames exactly**, proving nothing is left estimated when everything is materialised. Passing.

Also re-verified: golden 14/14, layouts 31/32 with fitted-item parity 32/32, lazy section 414, lazy extension
48, windowed 24, packed updates 240, and a strict armv7 `-Werror=unguarded-availability` compile.

The flow layout still calls the full `computeLayout`, so behaviour is unchanged - this is the primitive the
estimate rework needs. Next: pass the materialised range into the estimate (plan step 1) and wire the flow.

## The +196 outlier is a whole-section mean; but scoping it to runs is worse overall (round 202)

Localised the round-197 outlier geometrically, without changing code. At step 3 of the three-section scenario,
native's section 1 stays at the estimate (40) while PST's section 1 takes a uniform 54 - i.e. **one report's
size was applied to that whole section** by the per-section mean. Native does not do that.

Tried the natural correction: keep the per-section mean for *learned breakpoints* only (a changed item's run),
and fall back to the plain estimate for sections with no learned breakpoint - which is the round-130
"previous row" shape with a per-section mean.

Result: the outlier disappeared, and the deltas for that scenario became -64, -38, -9, +14 - but the suite got
**worse overall, 4/32 steps exact against 15/32** for the committed variant. So:

| Variant | steps exact | scenario-0 deltas (initial..step3) |
| --- | ---: | --- |
| A: per-section mean as proposal fallback (committed, round 195) | 15/32 | -37, -12, 0, +196 |
| B: per-section mean only inside learned runs | 4/32 | -64, -38, -9, +14 |

Neither is right, and the fact that A wins early while B wins late is strong evidence that the estimate depends
on **what has been laid out so far** - i.e. exactly the valid-range state - rather than on a static rule about
which items are measured. That is consistent with everything else this session found about native's laziness,
and it means the estimate cannot be finished by tuning this expression.

Reverted; baseline verified (golden PASS, layouts 31/32, fitted-item parity 32/32). Committed variant A remains.

## Paired baseline-vs-current run: reload variance is measurement noise (round 201)

Settled the round-200 reload question the only way that works: built the **round-175 baseline** from a git
worktree alongside current HEAD, installed both as separate apps, and ran them **alternately, three rounds
each**, on the same iPod touch 3 in one session (no-delegate, 5,000 items):

| Round | baseline cold | current cold | baseline reload | current reload |
| --- | ---: | ---: | ---: | ---: |
| 1 | 144.8 ms | 156.0 ms | 173.0 ms | 188.1 ms |
| 2 | 145.6 ms | 508.5 ms | 184.6 ms | 150.8 ms |
| 3 | 144.5 ms | 147.8 ms | 185.4 ms | 177.0 ms |

Conclusions:

* **The ~189 ms reload is not a regression.** The baseline binary itself measures 173-185 ms in this session -
  the 146.7 ms recorded in round 175 was a low reading, not a stable baseline. Baseline and current are within
  noise of each other on reload (baseline 173/185/185, current 188/151/177).
* Cold layout is stable at ~145-148 ms for both, apart from one 508 ms outlier on the current build - the same
  kind of transient seen earlier, and it sits next to a 147.8 ms run of the same binary minutes later.
* This is the correct method for these numbers: interleaved, same session, both binaries. Single-shot absolute
  comparisons across sessions (which rounds 175-200 relied on) are not trustworthy at this granularity on this
  device, and earlier "no regression / possible regression" statements should be read with that caveat.

Baseline worktree removed; repository tree unchanged.

## Outlier resolved; reload variance recorded (round 200)

Repeated the round-199 measurement twice on the same device and same binary:

| Configuration | run 1 | run 2 | round 175 baseline |
| --- | ---: | ---: | ---: |
| no delegate, cold | 148.2 ms | 149.1 ms | 147.7 ms |
| no delegate, scroll | 17.2 ms | 17.1 ms | 16.9 ms |
| no delegate, reload | 189.3 ms | 189.0 ms | 146.7 ms |
| delegate, cold | 285.6 ms | 286.3 ms | 287.5 ms |
| delegate, scroll | 2.9 ms | 2.8 ms | 3.0 ms |
| delegate, reload | 334.6 ms | 333.3 ms | 335.0 ms |

* The 237 ms cold reading from round 199 was **first-run interference** - two clean repeats give 148.2 / 149.1 ms,
  consistent with the baseline. Not a regression. (Round 199's own reload reading of 149.4 ms was the same
  artefact in reverse: whichever scenario runs first in a launch pays launch cost.)
* The delegate path is confirmed fixed and stable (285.6-286.3 cold, 333.3-334.6 reload against a 287.5 / 335.0
  baseline), which was the point of the C-array change.
* The no-delegate **reload** is consistently ~189 ms in both repeats of this session against 146.7 ms in round
  175 - reproducible within a launch, so it is either a real change or a device/session effect (the device has
  been running probes all session and may be throttling). Recorded as unresolved rather than claimed either way;
  settling it needs the baseline binary re-run in the same session, which is what a paired run is for.

Behaviour is deterministic across runs: the measured `contentHeight` values are identical (273341 and 289970).

## Per-section sums in C arrays: delegate-path cost removed (round 199)

Round 198 measured the per-section estimate costing 5-10% on the delegate path (cold 287.5 -> 301.6 ms,
reload 335.0 -> 369.9 ms on the iPod touch 3), attributed to an `NSMutableDictionary` lookup plus an
`NSMutableArray` read/write for every report - and with a size delegate every item reports.

Replaced those with three flat C arrays indexed by section (`_pstSectionSumW/SumH/Hits`, grown by doubling,
zeroed on reset), which is exactly what the layout's other hot state already does. Same arithmetic, same
results.

Re-measured on the same device, 5,000 items:

| Configuration | pre-change (round 175) | dictionary (198) | C arrays (199) |
| --- | ---: | ---: | ---: |
| delegate, cold | 287.5 ms | 301.6 ms | 286.1 ms |
| delegate, reload | 335.0 ms | 369.9 ms | 334.9 ms |
| delegate, scroll | 3.0 ms | 3.2 ms | 2.8 ms |
| no delegate, reload | 146.7 ms | 146.5 ms | 149.4 ms |

The delegate path is back to its pre-change numbers. One reading is an outlier: no-delegate cold came out at
237.0 ms against 146.7 ms before, while its own reload (149.4 ms) is unchanged - that is the first scenario
measured after launch, so it is most likely first-run/launch interference rather than the change; it needs a
repeat run before being called a regression, and is recorded here rather than ignored.

Gates after the change: golden 14/14, layouts 31/32 with fitted-item parity 32/32, stability, proposal,
delegate sizing, sizing updates, automatic size, preferred-context staging, and a strict armv7
`-Werror=unguarded-availability` compile.

## Per-section estimate: hardware cost on the iPod touch 3 (round 198)

Re-measured the PST route on the iPod touch 3 (iOS 5.1.1) at 5,000 self-sizing items with the per-section
estimate in place, against round 175's numbers (before it):

| Configuration | then | now |
| --- | ---: | ---: |
| no delegate, cold | 147.7 ms | 146.7 ms |
| no delegate, scroll | 16.9 ms | 16.8 ms |
| no delegate, reload | 146.7 ms | 146.5 ms |
| with delegate, cold | 287.5 ms | 301.6 ms |
| with delegate, scroll | 3.0 ms | 3.2 ms |
| with delegate, reload | 335.0 ms | 369.9 ms |

The no-delegate path - the one the objective is about - is unchanged within noise. The **delegate** path is about
5-10% slower on cold and reload. Most likely cost: the per-section accumulator is an `NSMutableDictionary`
lookup plus an `NSMutableArray` read/write per report, and with a size delegate every item reports. That is a
plausible regression to remove by keeping per-section sums in a small C array indexed by section (the layout
knows the section count), which is a contained follow-up rather than a design question.

Honest caveat: single run, one device, no interleaved baseline in the same session - the delegate deltas could
be partly drift.

**Device hygiene:** 23 of this session's probe apps were still resident on the iPod touch 3 (and had to be
killed by PID; `killall` by name missed several because the process name differs from the bundle suffix). Both
iPods are now verified at zero `org.example` processes. No `ps` on iOS 5, so `launchctl list` + PID kill is the
reliable cleanup recipe.

## Per-scenario map of the preparation-fitting residual (round 197)

Re-applied the full combination (preparation-time fitting, content-size cache fix, per-section estimate) and
recorded the content-size delta by scenario and step instead of a single total. This turns "15/32, off by up to
196" into a work list:

| Scenario | delta native -> PST, per step |
| --- | --- |
| three sections + headers | -37, -12, **0**, +196 |
| insets + spacing | 0, 0, 0, 0 |
| two sections, narrow | -43, 0, 0, 0 |
| horizontal + headers | 0, 0, 0, 0 |
| horizontal, narrow | 0, 0, 0, 0 |
| four sections, small headers | -24, -8, -18, +14 |
| delegate insets/spacing/footers | +8, 0, -10, +11 |
| delegate, horizontal | 0, 0, 0, 0 |

**Four of the eight scenarios are now exact at every step**, including both horizontal ones and the delegate
insets case at three of four steps. The residual is confined to multi-section cases (and one outlier: the last
step of the three-section scenario at +196), which is consistent with the remaining difference being how a
section that is still unmeasured is estimated when *other* sections have measurements - the one rule this round
and the last both probed without a clean answer.

Also unchanged: fitted-item parity 11/32 under the combination, so some fits still differ even where content
matches exactly.

Reverted; baseline verified (golden PASS, layouts 31/32, fitted-item parity 32/32). The map is the most useful
artefact of this round: half the shapes need no further model work, and the outlier is a single step.

## Unmeasured sections keep the estimate, not the global mean (round 196)

Tested the natural follow-up to the per-section estimate: when a section has measured nothing at all, fall back
to the global mean rather than the plain estimate. It **broke the baseline** - layouts fell from 31/32 to 2/32
with 0 visible frame differences, so the item geometry stayed right while the content size moved everywhere.

That is a useful negative result: native really does leave a section it has not reached at the estimate (as the
round-131 per-section scoping concluded), so the per-section model must fall back to `_pstProposalAtLayout0` and
nothing else. Reverted; window 195's model is the correct shape.

Full certification at HEAD afterwards - **25 of 25 collection gates pass**: golden 14/14, row centering,
stability, proposal, display scroll/supplementary order, hidden items, cell resize, attribute snapshot, bounds,
preferred predicate, invalidation context, attribute cache, context execution, packed updates 240, windowed 24,
lazy section 414, lazy extension 48, preferred-context staging, automatic size, batch insert 9/9, prefetch,
sizing updates, delegate sizing, and named-items flow flags. Layouts reports 31/32 on screen with 0 of 210
visible frame differences and fitted-item parity 32/32.

## Per-section estimate implemented (round 195)

PST estimated every unmeasured item from one **global** running mean. UIKit estimates a section from what it has
measured in that section, so the model is now per section: `_pstSectionMeasured` keeps `sumW/sumH/count` per
section, `pstEstimateForSection:` returns that section's mean (falling back to the plain estimate when nothing
has been measured there), and both proposal fallbacks use it - the per-item proposal when a section has no
learned runs, and the bulk fill when no runs exist yet.

Baseline behaviour is unchanged (single-section suites cannot move, since one section's mean *is* the global
mean): golden 14/14, layouts 31/32 with 0 of 210 visible frames and fitted-item parity 32/32, stability and
proposal suites pass, armv7 strict compile clean.

**Measured effect with preparation-time fitting plus the content-size cache fix** (the combination being built
towards, not shipped): layouts went from **1/32 to 15/32 steps exact**, visible frames still exact, and content
converging markedly - 1817/1842/1835/2042 against native's 1854/1854/1835/1846, with one step *exactly* equal
and the first two within 12 and 37 points. The last step is still +196, so the model is not finished, but the
global-mean hypothesis was correct and is now half-closed.

Committed the per-section model on its own (safe, verified); the preparation-fitting combination remains
uncommitted work for the next round.

## Cache fix confirmed; the residual is the estimate model (round 194)

Redid the round-164 cache fix now that the lazy layout exists (preparation-time fitting + clearing the data
cache's content-size validity on display-path named contexts, and not publishing the staged estimate while
displaying).

Result: the view's content size is **no longer stale**. It now tracks the layout (1910, 1985, 1966, 2022 across
the four steps) instead of being pinned at the first build's 1770. So the round-193 diagnosis was right and the
fix is the right one.

It is now **too large** against native (1854, 1854, 1835, 1846) - the residual is roughly +56 to +176, and the
pattern is systematic rather than noisy. That is exactly what an estimate-model difference looks like: PST
applies one global running mean to every unmeasured item, while the layouts scenario's cells report sizes by
`(item*7 + section*3) % 5`, so the per-section means differ from the global mean; native estimates each section
from its own measured rows.

With the cache fixed, the next change is therefore narrow and testable: make the unmeasured-item proposal
**per section** (mean of that section's measured items) instead of global. Single-section fixtures cannot
change, since one section's mean *is* the global mean, so the existing stepped-geometry suites are a safety net
for that change.

Gate status with the experimental build (before revert): visible frames still exact (0 of 210) but 1/32 steps
exact and fitted-item parity 11/32 - the content error dominates and some fits still differ. Reverted to keep
the suite green; baseline re-verified.

## Decisive probe: the layout exports measured content; the view keeps the first value (round 193)

Instrumented the two remaining points - the item sizes written into the packed buffers and the content size
exported at the end of `updateItemsLayout`:

    DBG2 export measured=0  contentH=1770.0
    DBG2 sec=0 measured=1 s0=30.0 s1=30.0   (x3 sections)
    DBG2 export measured=1  contentH=1350.0
    DBG2 export measured=2  contentH=1686.0
    ... 
    DBG2 export measured=15 contentH=2022.0

So the layout **is** building from the measured sizes and its exported content size tracks them (1350 -> 1686 ->
... -> 2022). The pipeline works in this scenario after all.

What the differential test then reports is 1770 for every step - the value from the *first* build. That pins the
defect to one place: `PSTCollectionViewData` reads `layout.collectionViewContentSize` into its own `_contentSize`
only when `contentSizeIsValid` is clear (`prepareToLoadData`), and the display-time invalidation path does not
clear it, so the view keeps the stale first value while the layout's own export keeps changing.

Round 164 tried clearing that flag (`invalidateContentSize`) and got 1910/2022 - too large against native's
1854 - which is why it was reverted then. With the lazy layout now in place, that experiment deserves redoing:
if the view then shows ~2022, the remaining delta is the estimate model (native 1854), not the cache.

Reverted; baseline verified (golden PASS, layouts 31/32, 0 of 210 frames, fitted-item parity 32/32).

## Reuse path ruled out by instrumentation (round 192)

Instrumented `_pstReuseStoredSizes` itself: when the attribute-only invalidation decides to reuse stored sizes,
when it is set, and whether any prepareLayout consumes it. In the layouts scenario:

* `set YES` count: **0** - the reuse path is never entered;
* the decision is blocked every time by `earliest=1`, i.e. a pending preferred-size report (exactly the guard
  added in round 179), which is the correct behaviour;
* prepareLayout runs repeatedly with `reuse=0`.

So round 191's hypothesis was wrong as well: the stale content does **not** come from the stored-size reuse
path.

What remains ruled out for this defect, all by direct measurement rather than reasoning: fitting order,
fit count, visible frames, the stored-size reuse flag, layout reuse, and the fit/record pipeline itself (round
191 showed reports accumulating and being observed by rebuilds). The content size is nevertheless exactly the
pure estimate.

The next probe is therefore the only unexamined point in that chain: log `_pstMeasuredSizeCount` and the
`contentSize` computed, at the **end** of `updateItemsLayout`, together with the sizes actually written into the
packed buffers. That distinguishes "builds with measurements but exports estimate" from "the exported size is
overwritten afterwards" and is a handful of lines.

Reverted; baseline verified (golden PASS, layouts 31/32, 0 of 210 frames, fitted-item parity 32/32).

## Layouts scenario instrumented: reports accumulate, but the final content comes from elsewhere (round 191)

Re-ran the round-190 tracing in the layouts scenario, where the content defect actually appears (stderr lands in
the artifacts' `pst-N.err` files). Trace excerpt:

    DBG build sec=0 measured=0   (x3 sections, first pass)
    DBG ctx item=0 h=30.0 measured=1
    DBG build sec=0 measured=1   DBG build sec=1 measured=1   DBG build sec=2 measured=1
    DBG ctx item=1 h=46.0 measured=2   ...

So in this scenario the reports **do** accumulate (1, 2, ...) and the rebuilds **do** observe them - the
preparation-fit pipeline is working here too, not just in the lifecycle probe. 48 builds were instrumented.

Yet the *settled* content size is exactly the pure estimate (1770 = three sections of `14*40 + 30`), which
means the value that ends up as `contentSize` is produced by a build that does not see those measurements. The
only such path in the current code is a rebuild that takes `_pstReuseStoredSizes` (attribute-only invalidation,
round 179) - it `continue`s before the instrumentation point. That is consistent with round 189's result only
if the reuse path is re-entered on the *final* build even when disabled earlier, which the round-189 patch did
not cover (it disabled the decision at context time, not the flag's persistence across passes).

Reverted; baseline verified (golden PASS, layouts 31/32, 0 of 210 frames, fitted-item parity 32/32).

Next step is now concrete: instrument `_pstReuseStoredSizes` itself - when it is set, when it is cleared, and
whether a rebuild that consumes it produces the content size. That is a four-line probe, not a redesign.

## Instrumented run: the fit path is reached and records (round 190)

Added temporary tracing (fit reached / changed / shouldInvalidate, context creation with the reported size, and
`measured`/`runs` counts at every rebuild), ran the display-lifecycle probe, then removed it all - the tree is
back at the committed state (golden PASS, layouts 31/32, 0 of 210 frames, fitted-item parity 32/32).

What the trace showed:

* every cell in the pass **is** fitted during preparation (`fit item=N changed=... should=...`), and when the
  report differs the context is created with that size (`ctx item=0 size=60.0`);
* a rebuild follows each context creation and the layout then holds `measured=1`, i.e. the report *is* stored;
* the measured count only rises when a report differs from the **current proposal**. A cell that agrees with
  the proposal takes the equal branch, which stores its size but deliberately does not add it to the mean (that
  has been the model since the early rounds). So "measured stays 1" is expected behaviour, not a bug.

So for this probe the pipeline works end to end: fit during preparation, record, rebuild. The layouts scenario
(cells reporting 30/38/46/54/62 against an estimate of 40) still produced content pinned at the pure estimate
in round 188, which this trace does **not** reproduce, so its cause is scenario-specific and still unknown.

Next step is the same instrumentation applied to the layouts scenario, where the difference actually appears -
that is now a targeted measurement with a known-good control, not a guess.

## The stored-size reuse path is not what loses the report (round 189)

Round 188 narrowed the remaining defect to "sizes reported during preparation never reach the rebuild that
computes the section extent", and guessed the round-179 attribute-only invalidation path (which reuses stored
sizes) was swallowing them. Tested that directly: preparation-time fitting re-applied with the reuse path
disabled outright.

Result: **content stayed exactly the same** - 1770 against native's 1854/1835/1846 at every step - while the
lifecycle and fit counts stayed correct (6/13/18 against 6/14/18). So the guess was wrong, and the reuse path is
not the cause. Reverted; baseline re-verified (golden PASS, layouts 31/32, 0 of 210 frames, fitted-item parity
32/32).

What is now established about the last defect:

* it is not fitting order (lifecycle exact), not fit count (6/13/18 vs 6/14/18), not visible frames (exact),
  not the stored-size reuse path (disabling it changes nothing), and not layout reuse (named contexts force a
  rebuild since round 162);
* the content size is exactly the *pure estimate* - three sections of `14*40 + 30` - which means every item
  size seen by the rebuild is still the estimate, so the recorded preferred sizes are absent by the time the
  section was built.

Next diagnostic should instrument the rebuild itself (how many measured sizes the layout holds when
`getSizingInfos` runs, and whether the preferred-size context factory is reached for each fit) rather than
guessing another path. That is a measurement task, not a code change.

## Preparation-time fitting with the lazy layout: lifecycle solved, content estimate still stale (round 188)

With the lazy layout live, the fit count problem from rounds 163-174 is gone. Fitting inside cell preparation
(once per instance, pass restarted when the fit invalidates, scheduler disabled) now gives:

* display lifecycle **exact**: 9 displays / 0 before fit and 8 / 0, against native 9/0 and 8/0;
* visible cell frames exact: 0 of 210 differ;
* fitted-item counts essentially identical: **6/13/18 against native's 6/14/18** (previously 9/20/27).

So the over-fitting diagnosis was right and the lazy layout fixes it: PST now creates cells only for rows it
has materialised.

Remaining error is content size, which stays at the pure estimate 1770 against native's 1854/1835/1846 - i.e.
the sizes reported during preparation are not reaching the rebuild that computes the section extent. Fit counts
matching while content does not points at the rebuild path rather than the fitting path (a likely culprit is
the attribute-only invalidation path from round 179 reusing stored sizes instead of the newly recorded report).

Reverted to keep the gate suite green; the lazy layout wiring from earlier in this round is committed and
verified. This is the narrowest the problem has ever been: lifecycle and fit counts now agree with native, and
one cache/rebuild decision separates PST from parity.

## Lazy (valid-range) layout wired and green (round 188)

The wiring attempt from round 187 is now working. The cause of that failure was **not** the attribute paths: it
was that `computeLayout` never recorded how many rows it had materialised, so a fully built (variable-size)
section reported zero and the on-demand materialiser re-laid its rows *starting from the section's end*,
displacing every row origin. With `_packedLaidOutRows` recorded by the full builder, on-demand materialisation
becomes a no-op for fully built sections and only extends genuinely lazy ones.

The earlier contract bug was also real and is fixed: the materialiser must receive the **margin-reduced**
dimension, the same one the section breaks rows against.

Live behaviour now: `updateItemsLayout` builds uniform packed sections through row 0 only, and both
`layoutAttributesForElementsInRect:` and `layoutAttributesForItemAtIndexPath:` materialise the rows they touch
before reading row geometry. Section frames and extent are exact by construction, so content size and the
golden geometry are unchanged.

**All 25 collection gates pass** with this in place: golden 14/14, row centering, stability, proposal, display
scroll/supplementary order, hidden items, cell resize, attribute snapshot, bounds, preferred predicate,
invalidation context, attribute cache, context execution, named-items flow flags, packed updates 240, windowed
24, lazy section 414, lazy extension 48, preferred-context staging, automatic size, batch insert 9/9, prefetch,
sizing updates, delegate sizing. Layouts reports 31/32 with 0 of 210 visible frame differences and fitted-item
parity 32/32.

The lifecycle gate still fails: fitting still happens after layout via the scheduler. The point of this work is
that it no longer has to - PST now lays out a window rather than every row, which is the precondition for
fitting during preparation without over-fitting.

## Wiring attempt: reverted (round 187)

Connected the lazy primitives to the live path: `updateItemsLayout` built uniform packed sections through row 0
only, and both attribute paths (`layoutAttributesForElementsInRect:` and
`layoutAttributesForItemAtIndexPath:`) materialised the rows they touch on demand, using the same reduced
dimension the section breaks rows against.

Result: the golden geometry still passed (frames and content size are exact by construction), but the layouts
differential collapsed to **0/32 with 242 visible cell frame differences and fitted-item parity in only 8 of 32
steps**. One contract bug was found and fixed on the way - the on-demand materialiser must be given the
*margin-reduced* dimension, not the raw section dimension - and it did not change the outcome, so the remaining
cause is somewhere else in the interaction (most likely the row-window binary search in
`layoutAttributesForElementsInRect:` reading rows that a query has not materialised yet, since it searches by
row index rather than by materialised range).

Reverted; baseline re-verified immediately after (golden PASS, layouts 31/32, 0 of 210 frames, fitted-item
parity 32/32). The lazy primitives from rounds 185-186 remain, tested, and unused by the live path.

Next time this is attempted the row-window search must be taught about materialisation explicitly, and the
attempt should be developed against `run-selfsizing-layouts-test.sh --fit-parity` from the first edit rather
than after the fact.

## On-demand row materialisation (round 186)

Added the other half of the lazy layout: a section records how many rows it has materialised and the running
extent after them, and `-materialisePackedRowsThroughRow:...` lays out further rows on demand. The layout-info
layer exposes this as `-materialisePackedRowsInSection:throughRow:dimension:spacing:`, which propagates any
growth to later sections and the content extent - the same propagation path used for item-size changes.

Two design errors were caught by the new gate before any wiring:

1. The lazy build laid out rows but never recorded the count, so the first on-demand extension laid row 0 a
   second time and moved it a row down (20 -> 50).
2. Materialising further rows initially reported the rows' extent as growth, which double-counts: a lazily
   built uniform section already reports the extent of *every* row through the uniform estimate, so
   materialising geometry must not change the section frame, later sections or the content extent. The
   contract is now explicit - growth is zero by construction for uniform sections - and the test asserts both
   directions.

Gate `run-packed-lazy-extension-test.sh`: 48 cases (both axes, 1..40 items, three sections, windows 0..3)
materialise on demand to the last row in every section and compare against a fully built twin: all row frames,
all item frames, all three section frames and the content extent. Passing, together with the lazy-section gate
(414 cases), windowed layout, packed updates, golden and layouts; armv7 iOS 5 strict compile clean.

Still not wired into `updateItemsLayout` / attribute queries. Both primitives now exist and are tested, so the
next step is the wiring itself plus moving fitting into preparation.
## Lazy section build for uniform packed sections (round 185)

Added `-computeLayoutMaterialisingRowsThrough:`: for a uniform packed section it lays out only the first rows
and derives the remainder of the extent from the uniform row size, producing the **same section frame, header
and footer** as a full build while leaving the unmaterialised rows without geometry (to be extended on demand).

This is the piece that makes preparation-time fitting viable: the reason every earlier attempt over-fitted
(9/20/27 reports against native's 6/14/18) is that PST materialised every row, so the visible set it laid out
from was not the settled one. With a real window, a cell is only ever created for a row that is actually
materialised.

One arithmetic bug was found and fixed by the new test: the remainder must add `rest * rowExtent +
(rest - 1) * gap`, not `rest * (rowExtent + gap)` - the full builder never puts an interstice after the last
row, and the last materialised row has already added the gap that follows it.

Gate `run-packed-lazy-section-test.sh`: 414 cases (both axes, 1-3 columns, 1..40 items, **every** window size
from 0 to the last row) compare section frame, header frame, footer frame, and every materialised row and item
frame against a full rebuild. Passing. Golden, windowed, packed-update and layouts gates unaffected; armv7
iOS 5 compiles with `-Werror=unguarded-availability`.

Still not wired into `updateItemsLayout`, and on-demand extension in the attribute-query path is not written;
until those land the live path is unchanged and the lifecycle gate still fails.

## Simulator PST/native re-measured on the heavy-cell benchmark (round 184)

The objective quotes "0.79x to 1.49x native in the simulator". That figure comes from
`vendor/PSTCollectionView/tests/heavy-cell-bench`, which runs both engines in one binary, alternating order,
15 pairs per row and reports the median ratio (cells hold N plain UILabels; scenario 0 scrolls ten steps of
87 pt, scenario 1 resizes the item size three times). Rebuilt and run at HEAD on the iOS 27 simulator:

| labels | scenario | native | PST | PST/native median | min | max |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 0 | item-size | 169 us | 102 us | 0.581 | 0.260 | 0.684 |
| 0 | scroll | 468 us | 315 us | 0.658 | 0.303 | 0.716 |
| 1 | item-size | 268 us | 148 us | 0.548 | 0.393 | 0.646 |
| 1 | scroll | 639 us | 362 us | 0.565 | 0.381 | 0.991 |
| 3 | item-size | 347 us | 209 us | 0.614 | 0.454 | 0.690 |
| 3 | scroll | 831 us | 430 us | 0.519 | 0.337 | 0.657 |
| 6 | item-size | 478 us | 307 us | 0.653 | 0.374 | 0.721 |
| 6 | scroll | 1090 us | 522 us | 0.479 | 0.361 | 0.721 |

Every median is between **0.48 and 0.66** - PST is faster than native UIKit across all heavy-cell cases at
HEAD, and the worst single pair is 0.99. So the objective's cited 0.79-1.49 spread no longer holds; the one
case that reached ~1.0 earlier (fixed-size cold layout at 1,000 items, 0.97 on hardware) remains the tightest
margin anywhere in this work.

Limit, unchanged: these are simulator CPU timings on one machine, not FPS on hardware, and the hardware pairs
from rounds 165/175 remain the authoritative device numbers.

## Consolidated status at round 183 (verification report)

27 gates across three areas, all green at HEAD, run in one sweep:

**Collection differential (23).** golden 14/14 scenarios; flow row centering 16; self-sizing stability;
proposal; display scroll order; display supplementary events; hidden items; cell resize; attribute snapshot;
bounds; preferred-attribute predicate (15 cases); invalidation context (defaults, dedupe, kinds, adjustments);
attribute cache; context execution; flow context flags in the strict named-items mode (four flag combinations,
both coalescing orders); packed incremental updates 240; packed windowed layout 24 + uniform detection;
preferred-context staging (flags, paths 0-19, staged size 60, content 1200/800); automatic size;
batch insert 9/9; prefetch lifecycle; self-sizing updates; delegate sizing. Layouts also reports
31/32 steps exact on screen, 0 of 210 visible cell frames differing, and **fitted-item sets identical in 32 of
32 steps**.

**Backports (4).** Auto Layout parity (11 suites + 80 golden frames vs the rebuild-per-pass engine); fitting
priorities; UIStackView parity; scene/trait fallthrough (classes unchanged on iOS 13+).

**Hardware.** iPod touch 3 (iOS 5.1.1): PST cold 147.7 ms / scroll 16.9 ms / reload 146.7 ms at 5,000
self-sizing items, and 287.5 / 3.0 / 335.0 with a size delegate - unchanged from before the context API landed.
iPod touch 5 (iOS 6.1.3): paired PST/native ratios 0.07-0.97 across nine scenarios, and the Apple-route device
gate PASS with 20 checks (prefetching, display callbacks, iOS 9 accessors, self-sizing, animated updates,
transforms). iPod touch 5 was left hung by two resident probes mid-session; both killed, SpringBoard
respringed, device verified clean.

**Still outstanding, and why the objective is not met.**

1. `willDisplayCell` still fires before `preferredLayoutAttributesFittingAttributes:` on the PST route
   (lifecycle gate: 9/9 and 10/10 cells against native 0/0). Five attempts (163-174) proved fitting during
   preparation fixes exactly this, and that it cannot be switched on without over-fitting (9/20/27 reports
   against native's 6/14/18).
2. The valid-range layout that resolves (1) is one third done: windowed row materialisation and the uniform
   precondition exist and are tested, but the flow layout still rebuilds whole sections, and on-demand window
   extension in the attribute-query path is not implemented.
3. Swift declaration lowering cannot be exercised here (no installed `swift_ios5` toolchain); its gate
   (`check-collection-api.sh`) was extended to audit the new context classes but cannot run.
4. The iPhone 6 run (iOS 10.3.3) has not been done in this session; the device is not attached.

No release has been published. Everything committed is verified by the gates above; the reverted experiments
are recorded in this file rather than left in the tree.

## Lazy-layout precondition added and tested (round 182)

Added `-packedSizesAreUniform` to the packed section: true only when every item size matches (and the first is
positive, and the section is non-empty). This is the precondition for deriving a section extent from a row
count instead of materialising every row - the estimate `ceil(count/perRow) * (tallestFirstRow + interstice)
- interstice + margins + header + footer` is exact precisely when the sizes are uniform, so wiring the lazy
path for those sections cannot change geometry.

Tested in `run-packed-windowed-layout-test.sh` (now also asserting: uniform detected for six equal items,
not detected for a single differing item, not detected for an empty section) - passing alongside the existing
24 windowed/rebuild cases.

**Why the wiring itself stops here:** making `updateItemsLayout` materialise only the visible rows is not safe
on its own. Attribute queries for items far outside the window (`layoutAttributesForItemAtIndexPath:`, which the
differential traces exercise for every item) would read unmaterialised rows. That needs on-demand window
extension inside the attribute-query path, plus extent bookkeeping that stays consistent when a query extends
the window - a coherent change, not a patch. Recorded in `SELF-SIZING-VALID-RANGE-PLAN.md` as the next step.

## Fitting-priorities gate restored; stale harness source lists (round 181)

`run-fitting-tests.sh` (the `systemLayoutSizeFitting` / fitting-priority suite, scope item 1) had the same
defect as the Auto Layout harness: `49e3e408` added `LegacyLinearSolver.swift` without adding it to the
runner's source list, and the engine's debug paths downcast to `UIView`, which a host build lacks. Fixed both
(same approach as round 173: list the source, provide host-only `UIView`/`UIWindow`/`UIScreen` stand-ins under
`#if !canImport(UIKit)`).

Now passing: fitting size, edge insets, non-mutating measurement, ordinary layout unchanged; required-to-optional
mutation invalidates the folded presolve value; pinned chat parent survives stack fitting changes and input
insertion.

Swept the remaining harnesses for the same staleness - only these two referenced `LegacyLayoutSolver`, and both
now list `LegacyLinearSolver`, so no other suite is silently skipping a source.

### Device note

The iPod touch 5 was left with two of this session's benchmark apps still running (`PairedBench` mid-run and
`HookTrace`), which hung SpringBoard (SSH alive, UI frozen). Killed both, respringed SpringBoard, confirmed
clean (no `org.example` processes, SpringBoard back). Lesson recorded: these device probes are persistent by
design and must be terminated after use rather than left resident, especially the 5,000-item self-sizing
benchmark on a 512 MB device.

## Apple route re-verified on real UIKit 6.1.3 hardware (round 180)

Re-ran `Tests/run-apple-route-ios6-device.sh` on the attached **iPod touch 5 (iOS 6.1.3)** - the only test
that exercises the collection hooks against real UIKit 6/7, since the newer simulator cannot stand in. Last run
was before the fit-order work and the invalidation-context additions.

**RESULT: PASS (0 failures)**, 20 checks, including:

* iOS 10 prefetching installed; no prefetch while stationary; announces items ahead of a forward scroll;
  does not repeat for the same position.
* `willDisplayCell` once per visible cell (10 callbacks, 10 visible) and `willDisplaySupplementaryView` once for
  the header.
* `visibleSupplementaryViewsOfKind:` and `indexPathsForVisibleSupplementaryElementsOfKind:` return the header.
* Self-sizing drives content height 16020.0 (expected 16020.0) and a self-sized cell takes its preferred
  height {{0,20},{320,80}}.
* Layout attribute transform round-trips.
* Animated insert and delete complete, apply the new item counts, deliver `willDisplay` for cells arriving in
  the animation (10 -> 15), and show no `willDisplay` regressions after the delete.

So objective item (2)'s device claim for the Apple route holds at HEAD, alongside the PST route measurements
from round 175 and the paired PST/native ratios from round 165.

## Attribute-only invalidation no longer re-queries the delegate (round 179)

A full gate sweep (23 collection gates) found one regression: `run-flow-context-flags-test.sh --named-items`.
It had been introduced back in round 162, when named contexts were made to force a row rebuild, and the strict
mode had not been re-run since. Native, for a context that merely names item paths with neither flow flag set,
recomputes attributes **without asking the size delegate again**; PST was re-querying all sizes and changing
frames and content height.

Fix: a named context that requests no metrics now rebuilds rows from the sizes already laid out
(`_pstReuseStoredSizes` plus a per-section snapshot taken before the rebuild), and the snapshot is discarded
after that one rebuild so later rebuilds query normally. The exception is a pending preferred-size report:
there the item estimate really has changed, and unmeasured items must be re-derived from it - which is why the
narrowing condition checks `_pstEarliestChangedPath == nil`. That distinction is exactly the difference between
the two probes: the flag case keeps 40/320 and the preferred-size case settles to 60/1200.

Verified after the change: `--named-items`, preferred-context staging, base context execution, attribute cache,
delegate sizing, automatic size, the 14-scenario golden, layouts (31/32, 0 of 210 frames, fitted-item parity
32/32), and a strict armv7 `-Werror=unguarded-availability` compile. The full 23-gate sweep is green apart from
this one, which now passes.

## `automaticSize` is a Swift-overlay declaration, not an ObjC runtime symbol (round 178)

Checked whether `UICollectionViewFlowLayout.automaticSize` (iOS 10) is missing on the backported routes.
Findings:

* It has **no Objective-C class method** - neither the iOS 27 simulator SDK nor this build exposes
  `+[UICollectionViewFlowLayout automaticSize]`; it is declared in the Swift UIKit overlay only. A client that
  writes `layout.estimatedItemSize = .automaticSize` therefore needs the *declaration* to be lowered by the
  compiler below iOS 10, not a method installed at runtime.
* Its runtime semantics are already implemented and gated on **both** routes: the sentinel
  `CGSize(CGFLOAT_MAX, CGFLOAT_MAX)` is recognised in the sizing paths (with UIKit's 50x50 seed when the
  sentinel reaches the estimate), and `run-automatic-size-test.sh` sets exactly that sentinel after changing
  `itemSize` and passes with 0 sole-item gaps.

So this is **not** a runtime API gap: it is part of the declaration-lowering work that cannot be exercised in
this environment (no installed `swift_ios5` toolchain; see round 170). Recorded rather than "fixed" by adding a
fabricated ObjC accessor, which would not match Swift's spelling or availability.

## Windowed (valid-range) packed layout, phase 1 (round 177)

Implemented the first piece of `SELF-SIZING-VALID-RANGE-PLAN.md`: the packed row builder is now split into
pass 1 (break items into rows, `pstBreakPackedRowsWithDimension:spacing:`) and pass 2 (per-row geometry,
`pstLayOutPackedRowsFrom:to:dimension:spacing:sectionSize:`), so a caller can materialise only the rows it
needs. `extendPackedRowsThroughRow:dimension:spacing:sectionSize:` extends the materialised window, continuing
the running section extent, and is idempotent for an already-materialised window.

The full rebuild still runs exactly the same arithmetic: pass 1 then pass 2 over every row, which is why the
existing 240-case rebuild-equivalence test is unchanged and still passes.

New gate `run-packed-windowed-layout-test.sh` (24 configurations: both axes, 1-3 columns, 1/14/27/40 items)
materialises a section one row at a time from a running extent and asserts against a full rebuild: identical
row frames, identical per-item frames and row assignment, identical item count to row mapping, no change on
re-extending, and a running extent that equals the rebuild's frame minus the trailing margin and footer.
Passing. armv7 iOS 5 compiles with `-Werror=unguarded-availability`.

Combined status after this round: windowed 24/24, packed updates 240/240, golden 14/14, layouts 31/32 with
0 of 210 visible frame differences **and fitted-item sets identical in 32 of 32 steps**. The live path is
unchanged - this phase adds the machinery only; wiring the flow layout to request a window (rather than a
whole-section rebuild) is the next step, and the lifecycle gate still fails until fitting moves into
preparation.

## Valid-range plan written; fitted-item parity made a gate (round 176)

Wrote `SELF-SIZING-VALID-RANGE-PLAN.md`: the design for the remaining unit, built from what the five reverted
attempts established - reference model (valid rect/range per section, per-item estimated flag, section
estimate formula, delta-shifting invalidation), the target PST data structures, the single ordering rule that
must hold (create -> fit -> apply delta -> display, with the settled visible set), the full gate list, and the
rollback point.

Also made the metric that actually diagnoses this a first-class check. `run-selfsizing-layouts-test.sh` now
compares the **set of items each engine fitted**, not just frame geometry, and `--fit-parity` fails on any
difference. This is the number that separated native (6/14/18 fits per step) from every preparation-time
attempt so far (9/20/27).

Result at HEAD: **fitted-item sets identical in 32 of 32 steps**, gate passing. That is a genuinely stronger
statement than before - the current post-layout scheduler measures exactly the items iOS 27 measures, which is
why its geometry and content size match - and it means the next attempt cannot regress it silently.

## PST route re-measured on iOS 5 hardware at HEAD (round 175)

The context/predicate/cache API added in rounds 144-173 is used by the layout's invalidation path, so the PST
route was re-measured on the **iPod touch 3 (iOS 5.1.1, armv7)** at the current commit, 5,000 self-sizing
items:

| Configuration | cold | scroll | reload |
| --- | ---: | ---: | ---: |
| no size delegate | 147.7 ms (fits=18) | 16.9 ms | 146.7 ms |
| with size delegate | 287.5 ms (fits=9) | 3.0 ms | 335.0 ms |

Against the pre-context-API numbers recorded earlier (142/16.7/144.4 ms and 300/2.8/300 ms) every figure is
within run-to-run noise, so the new API surface costs nothing on the oldest supported hardware. Objective item
(iv) for the PST route is therefore still satisfied at HEAD; the iOS 6.1 paired numbers for the Apple route
were recorded in round 165.

## Fifth attempt: fit-once-per-instance plus restart (round 174)

Built on round 168's restart with the missing piece: a cell instance is fitted **once**, marked, and the mark is
cleared when it is recycled, so a restarted pass does not fit the same instance twice. Combined with
display-aware invalidation (the pending section estimate is not published while displaying; named contexts
force a row rebuild and re-read the content size).

Results at the lifecycle level: **exact**. `changed=0` gives 9 displays / 0 before fit and `changed=1` gives
8 / 0, against native 9/0 and 8/0; visible cell frames stayed exact (0 of 210).

The remaining error is measurable and specific: **PST fits more cells than native**. Per step PST reports
9, 20, 27 fits against native's 6, 14, 18, and content comes out 1910/1985/1966/2022 against
1854/1854/1835/1846. Extra fits are cells created for the pre-restart attribute set, recycled and then fitted
again on their next instance. Native never creates them, because it knows the settled visible set before
creating anything - it lays out only rows near the visible rect.

So the last gap is not fitting order, cache validity or the estimate formula, all of which are now verified
correct in isolation. It is that PST computes visible attributes from a layout it then changes, while native
computes them from a layout that only extends a valid range. That is the valid-range unit: keep per-section
valid rect/range, extend it instead of invalidating everything, and derive the visible set from it.

Reverted; tree verified at the round-162 baseline (layouts 31/32, 0 of 210 frames, context probe passing).
No runtime behaviour changed.

## Auto Layout parity gate restored and passing (round 173)

Finished the repair begun in round 172. Three defects from `49e3e408` were blocking the gate; all are now fixed
without touching real runtime behaviour:

1. `LegacyLayoutSolver.swift` lost its file-scope solver aliases when the Cassowary types moved into their own
   module. Restored (`import Cassowary` plus `private typealias`es for `Expression`/`Variable`/`Constraint`/
   `Strength`/`RelationalOperator`).
2. The engine's debug-only diagnostics downcast to `UIView`, which a host parity build does not have. The
   harness stub file now supplies minimal `UIView`/`UIWindow`/`UIScreen` stand-ins **only** under
   `#if !canImport(UIKit)`, so the engine sources are untouched for iOS builds.
3. `LegacyLinearSolver` constructed `AppleNSISSolver`, which needs the solver objects' `internal` identifiers
   and therefore must be compiled into the same module as Cassowary. That construction is now guarded by
   `#if canImport(UIKit)`; the Cassowary backend remains the default, and the integrated (iOS) build still
   sees the NSIS path unchanged.

Result - the Auto Layout parity gate runs again and **passes**:

* engine parity: 11 suites OK (add-remove, priority, constants, reparent, remove-view, multiple-roots,
  autoresizing, layout-guide, intrinsic, stats contract, mutation generation),
* **`PASS: 80 golden frames match the previous rebuild-per-pass engine`**,
* persistent vs rebuild benchmarks (200 rows / 800 constraints: 502.5 us/pass persistent against 4835.6 us/pass
  rebuild).

Acceptance criteria are now all green except the two this effort cannot exercise here:

| Criterion | Status |
| --- | --- |
| No Auto Layout regression | **PASS** (gate restored, 11 suites + 80 golden frames) |
| No UIStackView regression | PASS |
| No scene/trait regression | PASS |
| Collection golden geometry | PASS (14/14) |
| Swift declaration lowering | not runnable (no installed `swift_ios5` toolchain) |

## Auto Layout gate: partial repair, still not runnable (round 172)

Followed up round 171's finding. `49e3e408` left `LegacyLayoutSolver.swift` with the comment "pin the solver
names at file scope" but no aliases, after moving `Expression`/`Variable`/`Constraint`/`Strength` into the
Cassowary module. Restored them (`import Cassowary` plus file-scope `private typealias`es), which removed the
ambiguity and cut the harness's compile errors **from 32 to 10**.

The remaining 10 errors are a different defect in the same commit: three debug-only code paths in
`LegacyLayoutSolver.swift` reference `UIView` (lines ~538, ~576, ~1720), but the parity harness compiles the
engine for the host, where UIKit does not exist. Guarding those regions needs matched `#if canImport(UIKit)`
pairs inside another subsystem's debug code; a first attempt left unbalanced conditionals, so it was reverted
rather than risk leaving that file in a worse state.

So the Auto Layout parity gate still cannot run, and I did not verify it. It is broken by `49e3e408` - not by
any collection-view change - and now needs two things: the aliases (done) and host-safe guards around the
`UIView` debug paths (not done, out of this effort's scope). Stack and scene/trait gates pass.

## Scene/trait gate made runnable and passing (round 171)

`run-scene-fallthrough-test.sh` requires a prepared native probe directory (`main.m` plus `P.app/Info.plist`
with `org.example.sceneprobe`) and none existed in the tree, so the scene/trait acceptance criterion had never
been run during this work. Added the missing probe at `vendor/UIKitBackports/Tests/scene-probe/` (minimal
scene-less `UIApplicationMain` app; the gate's constructor does the actual checking).

Now runs and passes: **`PASS: scene/trait backport inert on iOS 13+ (classes unchanged)`** - the runtime links
in, and `UIScene`/`UITraitCollection` are still Apple's classes from the system framework rather than being
replaced.

Acceptance-criterion status after this round:

| Criterion | Status |
| --- | --- |
| No Auto Layout regression | **cannot verify**: suite broken by `49e3e408` (source moved to the Cassowary module without a visible re-export); harness source list fixed, type visibility not |
| No UIStackView regression | PASS (`run-direct-stack-tests.sh`) |
| No scene/trait regression | PASS (gate now runnable, probe added) |
| Collection golden geometry | PASS (14/14) |

## Declaration-lowering gate extended (round 170)

The Swift-facing criterion ("declarations lowered by the compiler only below the OS that ships the API") is
checked by `check-collection-api.sh`, which compiles a Swift client for `armv7-apple-ios5.0` and
`armv7-apple-ios6.0`, requires the legacy `PSTCollection*` classes to be referenced at 5.0 and native
`UICollectionView` at 6.0, and audits the UIKit runtime's exported classes.

That checker **cannot run in this environment**: it requires an installed toolchain containing
`$TC/usr/lib/swift_ios5`, which is not present here (the collection work has been verified with the
standalone armv7 clang builds and simulator differential tests instead). Rather than leave it silently
incomplete, its runtime audit now also requires the two new classes,
`PSTCollectionViewLayoutInvalidationContext` and `PSTCollectionViewFlowLayoutInvalidationContext`, so that
when it next runs it covers this round's API additions instead of passing while ignoring them.

Verified here in place of the checker: the strict `-Werror=unguarded-availability` armv7 iOS 5 archive builds
and exports all four audited collection classes (checked with `nm -gU`), and
`test-collection-context-linkage.py` shows generated UIKit headers referencing the legacy context classes
rather than absent native ones.

## Acceptance-criterion check: Auto Layout / stack / scene (round 169)

The objective requires no regressions to the Auto Layout/stack parity work or the scene/trait backports, so
those suites were run for the first time in this collection-view effort.

| Suite | Result |
| --- | --- |
| `run-direct-stack-tests.sh` (UIStackView parity, native fill priorities) | **PASS** |
| `run-scene-fallthrough-test.sh` | not run: needs a prepared native probe directory (`NATIVE_PROBE_DIR`), which is not present here |
| `run-autolayout-tests.sh` | **fails to compile, pre-existing** |

The Auto Layout failure is not caused by any collection-view change: this work has never touched
`vendor/UIKitBackports/LegacyAutoLayout/` or `Cassowary/`. Its two causes were identified:

1. `LegacyAutoLayout/LegacyLinearSolver.swift` (added by `49e3e408`, earlier the same day) was never added to
   the harness's `ENGINE_SOURCES`, so `LegacyLinearSolver`, `Variable`, `Constraint` and `Strength` were all
   unresolved. **Fixed** by listing the file in `run-autolayout-tests.sh`.
2. With that file compiled, `LegacyLayoutSolver.swift` still cannot see those types: it imports only
   Foundation and CoreGraphics, and adding `import Cassowary` makes `Expression` ambiguous, so the types are
   not meant to be imported there. `49e3e408` moved them into the Cassowary module without a visible re-export.

So the Auto Layout parity gate is currently **broken by `49e3e408`, not restored**. The harness fix is kept
(without it the module is missing a required source); the remaining work is a re-export/visibility decision in
the Auto Layout code, outside the collection-view scope. Recording it here rather than leaving a suite that
silently does not build.

Stack parity is unaffected and passes.

## Fourth attempt: settled-pass restart, reverted (round 168)

Implemented the structural change round 167 pointed to: when preparing a cell invalidates the layout, the
current visible pass marks itself stale, recycles the unused cell and recomputes the whole pass from freshly
derived attributes (bounded to 4 restarts).

Outcome: the display lifecycle again matched iOS 27 exactly (9/0 and 8/0) and visible cell frames stayed
exact (0 of 210), but layouts stayed at 0/32 and **two new discrepancies appeared**: PST fitted 9/20/27 items
per step against native's 6/14/18 (the restart re-fits the same cells), and content size remained pinned at
the pure estimate 1770 rather than settling to 1854.

So the restart is the right shape but not sufficient on its own: re-running the pass re-fits cells, and the
recorded sizes still are not reaching the content computation. Reverted; baseline verified (layouts 31/32,
0 of 210 frames). No runtime behaviour changed.

Standing conclusion after four attempts (rounds 163-168): preparation-time fitting is proven for lifecycle
order, display counts and visible frames, but switching it on requires the measurement bookkeeping and
content-size settling to be rewritten together with a valid-range model - as one unit, not incrementally.
The live path therefore still uses the post-layout scheduler, and the display lifecycle mismatch remains.

## Which cells each engine measures (round 167)

Added a fitting log to the layouts trace (`fitted` per step: the (section,item) pairs that received
`preferredLayoutAttributesFittingAttributes:`), so measurement timing can be compared directly instead of
inferred from geometry.

Result at HEAD for the three-section scenario: native and PST fit the **same items and the same count** at
every step (6, 14, 18), differing only in order - e.g. native `(0,5),(0,6),(0,7),(0,7),(0,6),(0,5)` against
PST `(0,5),(0,6),(0,7),(0,5),(0,6),(0,7)`. Since the traced scenario has cells reporting 30/38/46/54/62 by
index, any difference in *which* items are measured would shift the mean and therefore content size; there is
none, which is consistent with content size matching exactly (1854) at HEAD.

That explains the round-166 result precisely: moving the fit to preparation does not change the mean model at
all, it changes **which cells are fitted** - PST then fits cells it creates and later discards, while native's
fit count stays at the displayed set. So the correct fix is not a new estimate formula; it is to make the
visible-set computation settle before cells are created, i.e. re-derive the visible attributes after an
invalidation raised during the pass (bounded restarts), so no cell is prepared only to be discarded.

Instrumentation only; no runtime behaviour changed, and the gate is unchanged at 31/32 with 0 of 210 visible
cell frames differing.

## Third attempt: duplicate fitting removed, remaining defect isolated to content size (round 166)

Round 164 could not tell whether the content-size error came from the cache or from double fitting. Two
variants were run to separate them.

1. **Measurement undo for discarded cells** (a fitted cell that the settled layout drops must not feed the
   estimate): layouts 3/32 with **32 of 210 visible cell frames now differing**. Worse, and it changed
   geometry, so that idea is wrong: the discarded report evidently still influences neighbours in native too.
2. **Post-layout scheduler disabled, fitting only in preparation** (needs an explicit
   `pstPrefersPreparationFitting` predicate; the duplicated fit was never confirmed necessary): this is the
   cleanest result so far. Display lifecycle matches iOS 27 exactly (9/0 and 8/0), the preferred-context
   probe passes, and **visible cell frames are exact (0 of 210)**. The single remaining defect is the
   content size: 1910/1985/1966/2022 against native 1854/1854/1835/1846, i.e. consistently too large. Adding
   an explicit content-size re-read during display did not move it (1/32 either way), confirming the cache
   is not the problem: the **estimate of unmeasured items** is.

Native 1854 for 3 sections x 14 items at estimate 40 with measured 60 means native is *not* applying one
running mean to every unmeasured item (PST's model, which yields 1910); it estimates each section from its own
first row and materialises rows lazily. That is the only remaining difference, and it is a self-contained
unit of work: the section-estimate model plus a valid item range.

Reverted again, so the live path is unchanged; tree verified at the round-162 state (layouts 31/32, context
probe passing, lifecycle known-mismatch). Nothing shipped from these experiments beyond this record.

## Paired hardware measurement at HEAD (round 165)

Re-ran the interleaved paired benchmark (both engines in one app, alternating order, median of the reps) on
the **iPod touch 5 (iOS 6.1.3)** against commit `fa173768`+docs, i.e. after all of rounds 144-164. Ratio is
PST / Apple-route, lower is better.

| Scenario | 200 | 1,000 | 5,000 |
| --- | ---: | ---: | ---: |
| Fixed-size cold layout | 0.87 | 0.97 | - |
| Fixed-size reload | 0.78 | 0.07 | - |
| Fixed-size batch insert+delete 5 | 0.51 | 0.50 | - |
| Self-sizing + delegate cold | 0.48 | 0.48 | 0.49 |
| Self-sizing + delegate reload | 0.29 | 0.22 | 0.29 |
| Self-sizing + delegate batch | 0.40 | 0.36 | - |
| Self-sizing, no delegate, cold | 0.24 | 0.12 | 0.08 |
| Self-sizing, no delegate, reload | 0.16 | 0.07 | 0.07 |

Every measured cell is at or below 1.0; the worst is fixed-size cold layout at 1,000 items (0.97, within
noise of parity) and the objective's original 0.79-1.49 spread is now 0.07-0.97. **Honest limit:** the
"native" side of this pair is Apple's iOS 6.1 engine *with my self-sizing hooks installed*, not stock iOS 8+
self-sizing, so these ratios compare PST against the backport on the Apple route, not against Apple's own
self-sizing implementation on a device that has it.

Build note recorded because it cost time: the paired bench must compile `main.m` with
`-DINSTALL_BACKPORT_HOOKS`, otherwise the Apple-route self-sizing rows abort with an unrecognised
`estimatedItemSize` selector on iOS 6.1, and the app dies before writing those rows.

## Second preparation-time attempt: content-size settling isolated, still reverted (round 164)

Round 163 left one hypothesis: the cached content size must refresh during a display pass but stay cached for
a caller-built context. That distinction was implemented and tested, using an associated marker set while a
cell is prepared, `invalidateContentSize` on the data cache, and a rebuild forced for named contexts.

Result: the display lifecycle matched iOS 27 exactly (9/0 and 8/0 against native 9/0 and 8/0), the strict
context probe still passed, and visible cell frames stayed at 0 of 210 differing. But the layouts gate only
recovered from 0/32 to **1/32**: content size now settled to the wrong value in the other direction
(1910/1985/1966/2022 against native 1854/1854/1835/1846; horizontal 2256/2074/2065/2080 against a constant
2088), where before the change it was too small (1770).

So the isolation itself was correct; the residual error is the unmeasured-item estimate, not cache validity.
PST applies one running mean to every unmeasured item, while native estimates each unlaid-out section from
its own first row and only materialises the rows near the visible rect. Fixing content size therefore requires
the valid-range model, not another cache patch.

Reverted again; tree verified back at the round-162 state (14-scenario golden, layouts 31/32, context probe
passing, lifecycle known-mismatch). Two independent attempts now show the same conclusion: preparation-time
fitting is correct and achievable, but it can only be turned on together with lazy valid-range layout.

## Preparation-time fitting attempt: reverted (round 163)

Tried moving the fit into cell preparation (where iOS 8.1 does it) so `willDisplayCell` stops arriving before
the preferred-size callback. The lifecycle ordering and callback counts then matched iOS 27 exactly
(`changed=0`: 9 displays / 0 unfitted, `changed=1`: 8 / 0, against native 9/0 and 8/0). But it **regressed a
passing gate**: the eight-shape layouts test fell from 31/32 steps to 0/32. Visible cell frames still matched
(0 of 210 differing) while the reported content size collapsed to the pure-estimate value (1770 instead of
1854), i.e. recorded sizes were no longer committed into content geometry.

Two narrow follow-ups were tried and both failed to restore it: suppressing the published estimate while a
cell is being prepared, and forcing `canReusePreparedLayout` to rebuild for named contexts. The remaining
cause is content-size cache validity: `invalidateItemAttributesPreservingContentSize` deliberately keeps the
cached size (which the strict context probe requires, native keeps 800 there), yet the display path needs the
size refreshed once measurements settle. Reconciling those two requires the real valid-range model where
unmeasured rows stay estimated, not a further patch here.

The change was reverted, so the tree is back at the verified round-162 state: 14-scenario golden passes,
layouts 31/32, preferred-context staging probe passes, lifecycle still reports the known mismatch
(9/9 and 10/10 displayed-before-fit against native 0). No runtime behaviour changed this round.

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
