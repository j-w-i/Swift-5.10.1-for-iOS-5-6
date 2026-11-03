//
//  LegacyViewState.swift
//  LegacyAutoLayout
//
//  Per-view state for the legacy Auto Layout bridge.
//
//  Previously every backported property (constraints, translates flag, intrinsic
//  size, priorities, baselines, dirty flags, autoresizing reference) lived in a
//  separate associated object, so every access was an `objc_getAssociatedObject`
//  call. The bridge now stores one `LegacyViewState` instance per view: a single
//  lookup gives the whole state, and reads/writes are ordinary stored-property
//  accesses afterwards. Behaviour and defaults are unchanged.
//

import Foundation
import CoreGraphics
import ObjectiveC

/// The per-view storage for the legacy Auto Layout bridge.
internal final class LegacyViewState: NSObject {

    /// The view's legacy constraints, in sorted-by-priority order.
    internal var constraints: [RRLayoutConstraint] = []

    /// Whether `constraints` is currently sorted ascending by priority.
    /// Add/remove only append/delete; the sort happens lazily when the engine
    /// reads the list (never on the add path, which used to re-sort every time).
    internal var constraintsSorted = true

    /// `translatesAutoresizingMaskIntoConstraints`; nil means UIKit's default (true).
    internal var translatesAutoresizingMaskIntoConstraints: Bool?

    /// `intrinsicContentSize`; nil means no intrinsic size set.
    internal var intrinsicContentSize: CGSize?
    internal var stackFittingProposal: CGSize?
    internal var stackFittingResult: CGSize?

    /// `UILabel.preferredMaxLayoutWidth`; nil means the iOS 5 default (0 = auto).
    internal var preferredMaxLayoutWidth: CGFloat?
    /// The width a multi-line label with no `preferredMaxLayoutWidth` was last re-measured at. UIKit's layout pass does the
    /// same: a first measure at an unbounded width, then a re-measure at the width Auto Layout actually gave the label.
    internal var measuredWrapWidth: CGFloat?

    internal var contentHuggingPriorityHorizontal: CGFloat?
    internal var contentHuggingPriorityVertical: CGFloat?
    internal var contentCompressionResistancePriorityHorizontal: CGFloat?
    internal var contentCompressionResistancePriorityVertical: CGFloat?

    internal var firstBaselineOffsetFromTop: CGFloat?
    internal var lastBaselineOffsetFromBottom: CGFloat?

    /// Constraint objects generated from the autoresizing mask (diagnostics only).
    internal var translatedAutoresizingConstraints: [RRLayoutConstraint]?

    /// The geometry the engine last generated autoresizing constraints from.
    internal var autoresizingReference: LegacyAutoresizingReference?

    /// `constraintsAreClean`; false means the constraints need updating.
    internal var constraintsAreClean = false
    /// Own callback dirtiness is separate from an ancestor's dirty-subtree walk.
    internal var needsConstraintUpdateCallback = true
    internal var isUpdatingConstraintCallbacks = false
    internal var isPerformingAutomaticLayout = false

    /// `needsLayout`; false when the view is clean.
    internal var needsLayout = false
    /// A settled bounds size changed during the legacy frame write-back, so -layoutSubviews must
    /// be delivered for this view once the pass completes (UIKit's lifecycle, which the backport
    /// otherwise skipped even though the frames were right).
    internal var pendingLayoutSubviews = false
    /// Conservative participation bit propagated on constraint mutation/reparenting.
    /// Sticky true avoids subtree scans in UIKit's hot geometry setters; removal
    /// may cause an extra invalidation but can never suppress a required update.
    internal var geometryAnchorsLayout = false
    /// Whether this view already asked its container for a layout pass since the
    /// last constraints/layout pass. Constraint bursts (a stack view activating
    /// dozens of constraints) used to send one native `setNeedsLayout` per
    /// constraint to the container; one per burst is enough and is what native
    /// Auto Layout effectively does.
    internal var containerInvalidated = false

    /// Intrinsic size derived from the system control's `-sizeThatFits:`; nil when stale.
    internal var systemIntrinsicCache: CGSize?
    /// Content inputs the cached system intrinsic size was measured from. iOS 6 invalidates the
    /// cache from the setters that change them; iOS 5 does not, so the read path compares this
    /// key and re-measures when the content changed.
    internal var intrinsicMeasurementKey: String?
    /// The engine has consumed this system control's intrinsic size, so a later content
    /// change must invalidate it (views the engine never measured need no bookkeeping).
    internal var systemIntrinsicObserved = false

    /// Last global invalidation counter consumed by this view's constraint walk.
    internal var handledInvalidation = -1
}

private var legacyViewStateKey: UInt8 = 0

internal extension LegacyViewState {

    /// The view's state, or nil when nothing was ever stored for it.
    @MainActor
    static func existing(of view: UIView) -> LegacyViewState? {
        objc_getAssociatedObject(view, &legacyViewStateKey) as? LegacyViewState
    }

    /// The view's state, creating it on first use.
    @MainActor
    static func of(_ view: UIView) -> LegacyViewState {
        if let state = existing(of: view) { return state }
        let state = LegacyViewState()
        objc_setAssociatedObject(view, &legacyViewStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }
}
