# Self-sizing: valid-range layout plan

Status: design only. Not implemented. The live PST path still uses the post-layout measuring scheduler, so
`willDisplayCell` currently fires before `preferredLayoutAttributesFittingAttributes:` and the lifecycle gate
fails (9/9 and 10/10 cells unfitted against native's 0/0). Nothing in this document is shipped behaviour.

## Why this document exists

Five attempts (rounds 163, 164, 166, 168, 174) tried to switch on preparation-time fitting incrementally.
Each produced a precise partial result and each was reverted:

| Attempt | Lifecycle | Visible frames | Content size | Other |
| --- | --- | --- | --- | --- |
| 163 fit in preparation | exact | exact | too small (1770 vs 1854) | layouts 0/32 |
| 164 isolate cache settling | exact | exact | too large (1910) | layouts 1/32 |
| 166 disable duplicate scheduler | exact | exact | too large (1910) | layouts 1/32 |
| 168 restart pass | exact | exact | 1770 | re-fits: 9/20/27 vs 6/14/18 |
| 174 fit-once-per-instance + restart | exact | exact | 1910-2022 | re-fits: 9/20/27 vs 6/14/18 |

Common conclusion: lifecycle order and frames are *already solved* by fitting during preparation. What fails is
that PST derives the visible attribute set from a layout it then changes, so it fits cells that are never
displayed. Native never creates them: it lays out only rows near the visible rect and extends a valid range.

## Reference model (behavioural, from the iOS 8.1 decompilation recorded earlier)

1. Cell creation fits the new cell and, if the size differs and the layout agrees, applies an invalidation
   context. Nothing is accumulated after layout has finished.
2. Each `_UIFlowLayoutSection` carries a `validRect` and a `validItemRange`. Laying out a rect extends the
   range; rows outside it are not materialised.
3. Each item carries `positionEstimated`. Only estimated items are re-derived when a report changes.
4. Unmeasured sections are sized by formula: `ceil(count / perRow) * (tallestItemInFirstRow + interstice)
   - interstice + margins + header + footer`.
5. A changed size updates the item, names later items *within the valid range* as invalidated, shifts later
   sections by the delta and adjusts the content size by the same delta. The context requests no delegate
   rebuild.

## Target design for PST

Per `PSTGridLayoutSection` (packed storage already has the flat arrays needed):

* `CGRect validRect` — section-local rect the rows currently describe.
* `NSInteger validFirstRow, validRowCount` — materialised row window.
* `BOOL positionEstimated` per item (bit array, one byte per item alongside `_packedSizes`).

Per flow layout:

* `pstEnsureLayoutInRect:` — the only entry point that materialises rows. If `rect` is inside `validRect`,
  return. Otherwise extend the window to cover `rect`, laying out rows incrementally from the nearest
  materialised row, and widen `validRect`.
* `pstSizeForItem` returns the measured size when known, else the section estimate (never a global mean for
  items outside the valid range).
* `pstApplyPreferredSize:forItem:` — stage size, mark the item measured, recompute its row, shift later
  materialised rows and the content size by the delta, and record the delta for the invalidation context.
  If the change crosses the scroll axis it reflows just this section from stored sizes (already implemented
  as `reflowPackedItemAtIndex:`).
* Content size = sum over sections of (materialised extent for the valid window, estimate for the rest).

## The one ordering rule that must hold

Create → fit → apply delta → **display**, where "display" only happens for items the settled layout places in
the visible rect. Because the delta only shifts rows and never invalidates the whole layout, the visible set
after applying is a superset of the previous one by at most one row, so no prepared cell is ever discarded.
That is what makes native's fit count equal its displayed count (6/14/18 in the trace) and what PST currently
violates (9/20/27).

## Test plan (all gates already exist)

1. `run-selfsizing-display-lifecycle-test.sh --gate` — must go from the current failure to 9/0 and 8/0.
2. `run-selfsizing-layouts-test.sh --gate` — must stay at 31/32 with 0 of 210 visible frame differences and,
   additionally, its `fitted` log must show PST's per-step fit list equal to native's list, not merely the
   same length. Add that comparison to the runner.
3. `run-preferred-context-geometry-test.sh` — must keep passing (staging semantics).
4. `run-packed-item-update-test.sh` — 240 rebuild-equivalence cases must keep passing.
5. `run-selfsizing-stability-test.sh`, `run-selfsizing-bounds-test.sh`, `run-display-scroll-test.sh`,
   `run-display-supp-test.sh`, `run-batch-insert-visibility-test.sh`, `run-automatic-size-test.sh`,
   `run-prefetch-lifecycle-test.sh`, the 14-scenario golden and `flow-row-centering`.
6. Hardware: paired bench on the iPod touch 5 and the PST bench on the iPod touch 3, both must not regress
   from the round-165/175 numbers (PST/native 0.07-0.97; iPod 3 cold 147.7 ms, scroll 16.9 ms, reload
   146.7 ms at 5,000 items).

## Risks

* Incremental row extension is the highest-risk piece: the packed row builder currently assumes it lays out a
  whole section. Extension must produce bit-identical geometry to a full rebuild for the same sizes, which is
  what `run-packed-item-update-test.sh` already asserts for single changes; it needs extending to window
  growth.
* `runsToScreenScale` rounding and row alignment must be applied identically when extending.
* Content size will briefly be an estimate; the existing staging probe pins the exact numbers, so regressions
  are detectable rather than silent.

## Rollback

All work sits behind the flow layout's self-sizing path with the existing gates as the acceptance boundary.
If any gate cannot be made green, revert to the round-162 baseline, which is the state verified today
(layouts 31/32, 0 of 210 frames, preferred-context staging passing, lifecycle failing as documented).

## Addendum (after rounds 195-202): the estimate is a function of layout state

The remaining behavioural gap is no longer "which formula". Five variants were measured against the iOS 27
oracle and none wins everywhere:

| Variant | layouts steps exact | scenario-0 content deltas (initial..step3) |
| --- | ---: | --- |
| global running mean (pre-195) | 1/32 | large, direction varies |
| per-section mean as proposal fallback (195, committed) | 15/32 | -37, -12, 0, +196 |
| per-section mean only inside learned runs (202) | 4/32 | -64, -38, -9, +14 |
| global mean fallback for unmeasured sections (196) | 2/32 | breaks baseline entirely |
| no change to fallback, cache fix only (194) | 1/32 | stale |

A wins the early steps, B wins the late ones, and the geometric localisation of A's outlier showed a single
report being applied to a whole section that native had not reached. Taken together this says the estimate is a
function of **what has been laid out so far**, not of which items happen to have reports: native extends its
valid range as the view scrolls, and the estimate grows over the region it has materialised.

### What that means for the implementation

1. The estimate lookup needs the materialised range, so it belongs where the layout knows it - in the flow
   layout's size query, not in a static proposal expression. `pstEstimateForSection:` becomes
   `pstEstimateForSection:throughRow:`: measured mean for rows inside the materialised range, the plain
   estimate beyond it.
2. That only has meaning if non-uniform sections are also laid out lazily. Today only uniform packed sections
   are (round 185); variable sections still call `computeLayout` and materialise everything, so their materialised
   range is "all rows" and the rule degenerates to variant A. Extending the lazy path to variable sections is
   therefore the prerequisite - `pstBreakPackedRows*` and `pstLayOutPackedRowsFrom:to:` already separate row
   breaking from row layout, which is what makes that possible.
3. Acceptance is unchanged and already instrumented: `run-selfsizing-layouts-test.sh --gate --fit-parity`
   (per-scenario content deltas and the fitted-item set), then the 24 other collection gates, then the paired
   device bench against a worktree baseline.

### What not to do again

Tuning the expression is exhausted: rounds 195, 196 and 202 each changed only the formula and each fixed one
scenario while breaking others. Any further attempt should carry the materialised range into the estimate,
which is a change of data flow, not of arithmetic.
