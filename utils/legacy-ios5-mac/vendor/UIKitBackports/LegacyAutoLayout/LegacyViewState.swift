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

    /// `needsLayout`; false when the view is clean.
    internal var needsLayout = false
    /// Whether this view already asked its container for a layout pass since the
    /// last constraints/layout pass. Constraint bursts (a stack view activating
    /// dozens of constraints) used to send one native `setNeedsLayout` per
    /// constraint to the container; one per burst is enough and is what native
    /// Auto Layout effectively does.
    internal var containerInvalidated = false

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
