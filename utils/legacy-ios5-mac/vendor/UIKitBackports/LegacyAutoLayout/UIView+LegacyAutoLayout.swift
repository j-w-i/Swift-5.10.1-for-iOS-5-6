//
//  UIView+LegacyAutoLayout.swift
//  LegacyAutoLayout
//
//  UIView side of the legacy Auto Layout backport: associated-object constraint storage,
//  translatesAutoresizingMask/intrinsic-size/hugging/compression backports and the
//  `LegacyLayoutItem` conformance consumed by `LegacyLayoutEngine`.
//
//  Ported from RRAutoLayout's UIView+RRConstraintBasedLayout (Classes/View) and
//  RRLayoutConstraint (Classes/Module):
//    Copyright (c) 2012 Rolandas Razma <rolandas@razma.lt>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this
//  software and associated documentation files (the "Software"), to deal in the Software
//  without restriction, including without limitation the rights to use, copy, modify,
//  merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
//  permit persons to whom the Software is furnished to do so, subject to the following
//  conditions:
//
//  The above copyright notice and this permission notice shall be included in all copies
//  or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
//  INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
//  PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
//  CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
//  OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

import UIKit
import ObjectiveC

// MARK: - Defaults and state helpers

/// Default values that exist even when no state has been stored for a view.
private enum LegacyAutoLayoutDefaults {
    static let translatesAutoresizingMaskIntoConstraints = true
    static let contentHuggingPriority: CGFloat = 250 // RRLayoutPriorityDefaultLow
    static let contentCompressionResistancePriority: CGFloat = 750 // RRLayoutPriorityDefaultHigh
    static let intrinsicContentSize = CGSize(
        width: LegacyLayoutMetrics.noIntrinsicMetric,
        height: LegacyLayoutMetrics.noIntrinsicMetric
    )
    static let baselineOffset: CGFloat = 0
}

/// Drops the captured autoresizing reference so the next layout pass re-captures the current geometry.
///
/// UIKit regenerates its autoresizing constraints from the view's current frame; the backport captures
/// that geometry once and lets the engine refresh it after a successful pass. Any change that can move
/// the view or change what its autoresizing constraints should be (translates flag flip, added or
/// removed constraints) invalidates the captured reference.
@MainActor
internal func legacyClearAutoresizingReference(_ view: UIView) {
    LegacyViewState.existing(of: view)?.autoresizingReference = nil
}

/// The view's state, created on first write.
@MainActor
private func legacyMutableState(_ view: UIView) -> LegacyViewState {
    LegacyViewState.of(view)
}

/// The RRAutoLayout-compatible UIView surface plus the `LegacyLayoutItem` mapping.
///
/// Everything here is `@MainActor`: UIKit's own layout APIs are main-actor isolated and the bridge
/// must never run a layout pass off the main thread (docs §6 "Threading").
@MainActor
extension UIView {

    // MARK: Constraint storage (the `-[UIView constraints]` equivalent)

    /// Constraints owned by this view for the legacy path — the backport equivalent of `-[UIView constraints]`.
    ///
    /// This never reads or writes the system `NSLayoutConstraint` machinery: on iOS 6+ the real
    /// `constraints` array stays untouched by every `legacy*` API. The list is sorted by priority
    /// lazily, on the first read after a change, instead of on every add.
    var legacyConstraints: [RRLayoutConstraint] {
        guard let state = LegacyViewState.existing(of: self), !state.constraints.isEmpty else {
            return []
        }
        if !state.constraintsSorted {
            state.constraints.sort { $0.priority < $1.priority }
            state.constraintsSorted = true
        }
        // Copy-on-write: the caller gets the storage directly and a later add
        // copies it, so a layout pass does not allocate a fresh array per item.
        return state.constraints
    }

    /// Adds a constraint to this view's legacy storage.
    ///
    /// Mirrors RRAutoLayout: the constraint is appended and the view (and its container) are marked
    /// as needing a constraint update/layout. Sorting by priority happens lazily on the next read,
    /// so adding n constraints is O(n) instead of O(n^2 log n).
    func legacyAddConstraint(_ constraint: RRLayoutConstraint) {
        LegacyAutoLayout.ensureInstalled()
        let state = legacyMutableState(self)
        if !state.constraints.contains(where: { $0 === constraint }) {
            state.constraints.append(constraint)
            state.constraintsSorted = false
            LegacyLayoutMutation.bump()
        }
        // Constraint changes can change the solved geometry; force a fresh autoresizing capture.
        legacyClearAutoresizingReference(self)
        legacySetNeedsUpdateConstraints()
    }

    /// Adds several constraints through `legacyAddConstraint(_:)`.
    func legacyAddConstraints(_ constraints: [RRLayoutConstraint]) {
        LegacyAutoLayout.ensureInstalled()
        for constraint in constraints {
            legacyAddConstraint(constraint)
        }
    }

    /// Removes `constraint` from this view's legacy storage (identity comparison, like UIKit).
    func legacyRemoveConstraint(_ constraint: RRLayoutConstraint) {
        guard let state = LegacyViewState.existing(of: self),
              let index = state.constraints.firstIndex(where: { $0 === constraint }) else {
            return
        }
        state.constraints.remove(at: index)
        LegacyLayoutMutation.bump()
        legacyClearAutoresizingReference(self)
        legacySetNeedsUpdateConstraints()
    }

    /// Removes several constraints through `legacyRemoveConstraint(_:)`.
    func legacyRemoveConstraints(_ constraints: [RRLayoutConstraint]) {
        for constraint in constraints {
            legacyRemoveConstraint(constraint)
        }
    }

    // MARK: translatesAutoresizingMaskIntoConstraints

    /// Backport of `translatesAutoresizingMaskIntoConstraints` (default `true`).
    ///
    /// Defaulting to `true` is what makes the backport a drop-in replacement: views created in code or
    /// loaded from a nib before Auto Layout existed rely on their autoresizing mask/frame, and the
    /// engine pins their current frame exactly like UIKit's translation step does (docs §5.3).
    var legacyTranslatesAutoresizingMaskIntoConstraints: Bool {
        get {
            LegacyViewState.existing(of: self)?.translatesAutoresizingMaskIntoConstraints
                ?? LegacyAutoLayoutDefaults.translatesAutoresizingMaskIntoConstraints
        }
        set {
            legacyMutableState(self).translatesAutoresizingMaskIntoConstraints = newValue
            LegacyLayoutMutation.bump()
            // A flag flip changes whether (and from which geometry) autoresizing constraints are
            // generated, so the captured reference is stale.
            legacyClearAutoresizingReference(self)
            legacySetNeedsUpdateConstraints()
        }
    }

    // MARK: Intrinsic content size

    /// Backport of `intrinsicContentSize` (default `UIViewNoIntrinsicMetric`).
    var legacyIntrinsicContentSize: CGSize {
        get {
            if let value = LegacyViewState.existing(of: self)?.intrinsicContentSize {
                return value
            }
            if self is UILabel || self is UIButton || self is UIImageView {
                return sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
            }
            return LegacyAutoLayoutDefaults.intrinsicContentSize
        }
        set {
            legacyMutableState(self).intrinsicContentSize = newValue
            LegacyLayoutMutation.bump()
            legacySetNeedsUpdateConstraints()
        }
    }

    // MARK: Content hugging / compression resistance

    /// Content hugging priority backport. Defaults to `RRLayoutPriorityDefaultLow` (250) on both axes,
    /// matching UIKit.
    func legacyContentHuggingPriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        let stored = LegacyViewState.existing(of: self)
        if axis == .horizontal {
            return RRLayoutPriority(stored?.contentHuggingPriorityHorizontal
                ?? LegacyAutoLayoutDefaults.contentHuggingPriority)
        }
        return RRLayoutPriority(stored?.contentHuggingPriorityVertical
            ?? LegacyAutoLayoutDefaults.contentHuggingPriority)
    }

    func legacySetContentHuggingPriority(_ priority: RRLayoutPriority, for axis: RRLayoutAxis) {
        let state = legacyMutableState(self)
        if axis == .horizontal {
            state.contentHuggingPriorityHorizontal = CGFloat(priority)
        } else {
            state.contentHuggingPriorityVertical = CGFloat(priority)
        }
        LegacyLayoutMutation.bump()
        // UIKit treats a hugging-priority change as an intrinsic-size invalidation.
        legacySetNeedsUpdateConstraints()
    }

    /// Content compression resistance priority backport. Defaults to `RRLayoutPriorityDefaultHigh`
    /// (750) on both axes, matching UIKit.
    func legacyContentCompressionResistancePriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        let stored = LegacyViewState.existing(of: self)
        if axis == .horizontal {
            return RRLayoutPriority(stored?.contentCompressionResistancePriorityHorizontal
                ?? LegacyAutoLayoutDefaults.contentCompressionResistancePriority)
        }
        return RRLayoutPriority(stored?.contentCompressionResistancePriorityVertical
            ?? LegacyAutoLayoutDefaults.contentCompressionResistancePriority)
    }

    func legacySetContentCompressionResistancePriority(_ priority: RRLayoutPriority, for axis: RRLayoutAxis) {
        let state = legacyMutableState(self)
        if axis == .horizontal {
            state.contentCompressionResistancePriorityHorizontal = CGFloat(priority)
        } else {
            state.contentCompressionResistancePriorityVertical = CGFloat(priority)
        }
        LegacyLayoutMutation.bump()
        legacySetNeedsUpdateConstraints()
    }

    // MARK: Baselines

    /// Backport of `firstBaselineOffsetFromTop` (default `0`).
    ///
    /// The value is stored unconditionally, but the `LegacyLayoutItem` conformance reports a baseline
    /// only once a caller has explicitly set one: a plain `UIView` has no cross-view baseline
    /// participation, so "unset" maps to the protocol's `nil` ("no baseline support"), which keeps the
    /// engine from inventing baseline equations for every view.
    var legacyFirstBaselineOffsetFromTop: CGFloat {
        get {
            LegacyViewState.existing(of: self)?.firstBaselineOffsetFromTop
                ?? LegacyAutoLayoutDefaults.baselineOffset
        }
        set {
            legacyMutableState(self).firstBaselineOffsetFromTop = newValue
            LegacyLayoutMutation.bump()
            legacySetNeedsUpdateConstraints()
        }
    }

    /// Backport of `lastBaselineOffsetFromBottom` (default `0`).
    var legacyLastBaselineOffsetFromBottom: CGFloat {
        get {
            LegacyViewState.existing(of: self)?.lastBaselineOffsetFromBottom
                ?? LegacyAutoLayoutDefaults.baselineOffset
        }
        set {
            legacyMutableState(self).lastBaselineOffsetFromBottom = newValue
            LegacyLayoutMutation.bump()
            legacySetNeedsUpdateConstraints()
        }
    }

    // MARK: Layout / constraint-update driving

    /// Runs the legacy layout pass over this view's subtree.
    ///
    /// This is the explicit opt-in path: it runs the engine even when the ObjC bridge is not
    /// installed (i.e. on iOS 6+, for tests and for library shims that need deterministic layout).
    /// When the bridge *is* installed (iOS < 6), the swizzled `layoutSubviews` pass calls this same
    /// code path. It deliberately does not consult `isActive` — the direct `legacy*` API is documented
    /// as usable on any OS (docs §1, §6).
    ///
    /// The engine keeps a persistent solver per root, so a dirty pass only applies the changed
    /// constraints; a clean pass is served from the cached solution.
    func legacyLayoutIfNeeded() {
        LegacyAutoLayout.ensureInstalled()
        legacyUpdateConstraintsIfNeeded()

        let engine = LegacyLayoutEngine(direction: LegacyAutoLayoutSemanticDirection.current)
        // The engine writes frames through `layoutSetFrame(_:)`; flag that so the swizzled
        // setBounds:/setCenter: hooks do not re-dirty the constraint graph for every written frame
        // (that is what would turn an RR-style pass into a layout feedback loop).
        let wasApplyingLayoutFrames = LegacyAutoLayoutRuntime.isApplyingLayoutFrames
        LegacyAutoLayoutRuntime.isApplyingLayoutFrames = true
        engine.layout(self)
        LegacyAutoLayoutRuntime.isApplyingLayoutFrames = wasApplyingLayoutFrames

        legacyMutableState(self).needsLayout = false
    }

    /// Marks this view as needing a layout pass (backport of `setNeedsLayout`).
    func legacySetNeedsLayout() {
        LegacyAutoLayout.ensureInstalled()
        legacyMutableState(self).needsLayout = true
        legacySetNeedsUpdateConstraints()
    }

    /// Marks this view (and its container) as needing a constraint update.
    func legacySetNeedsUpdateConstraints() {
        LegacyAutoLayout.ensureInstalled()
        legacyMutableState(self).constraintsAreClean = false
        legacyInformContainerThatSubviewsNeedUpdateConstraints()
    }

    /// Runs the pending constraint update for this view and its subviews (backport of
    /// `updateConstraintsIfNeeded`). Mirrors RRAutoLayout's recursive dirty-flag walk.
    func legacyUpdateConstraintsIfNeeded() {
        LegacyAutoLayout.ensureInstalled()
        guard !(LegacyViewState.existing(of: self)?.constraintsAreClean ?? false) else { return }

        legacyUpdateConstraints()
        for subview in subviews {
            subview.legacyUpdateConstraintsIfNeeded()
        }

        legacyMutableState(self).constraintsAreClean = true
    }

    // MARK: Internal bridge hooks (used by LegacyAutoLayoutSwizzling)

    /// The body of the backported `-updateConstraints`, mirroring RRAutoLayout's split into a content
    /// size hook and an autoresizing-translation hook. Subclasses cannot override this in Swift (no
    /// ObjC category override), so it is an internal, documented extension point rather than a method
    /// that apps are expected to override.
    internal func legacyUpdateConstraints() {
        legacyUpdateContentSizeConstraints()
        legacyUpdateAutoresizingConstraints()
    }

    /// Content-size hook (the equivalent of RRAutoLayout's `rr_updateContentSizeConstraints`).
    ///
    /// Intrinsic sizes are exposed to the engine through `layoutIntrinsicContentSize` and the hugging/
    /// compression priorities, so no extra constraints are materialised here; the hook exists so the
    /// swizzled `-updateConstraints` call flow is structurally identical to the upstream backport.
    internal func legacyUpdateContentSizeConstraints() {}

    /// Autoresizing hook (the equivalent of RRAutoLayout's `rr_updateAutoresizingConstraints`).
    ///
    /// The real `NSAutoresizingMaskLayoutConstraint` equations are generated by the engine from the
    /// item's mask plus the captured `layoutAutoresizingReference` (docs §5.3 / semantics §3.1); the
    /// bridge only stores that reference (see the `LegacyLayoutItem` conformance below). This hook keeps
    /// the small RRAutoLayout-compatible constraint form in dedicated storage (never mixed into
    /// `legacyConstraints`, which must stay the user-owned list) for the nib/ObjC `addConstraint:`
    /// flow and for tests; it does not feed the engine.
    internal func legacyUpdateAutoresizingConstraints() {
        let translated: [RRLayoutConstraint] = LegacyLayoutMutation.withSuppressed {
            if legacyTranslatesAutoresizingMaskIntoConstraints {
                return LegacyAutoLayoutAutoresizing.framePinningConstraints(for: self)
            }
            return []
        }
        legacyMutableState(self).translatedAutoresizingConstraints = translated
    }

    /// The constraints the bridge generated from the autoresizing mask/frame (internal diagnostics).
    internal var legacyTranslatedAutoresizingConstraints: [RRLayoutConstraint] {
        LegacyViewState.existing(of: self)?.translatedAutoresizingConstraints ?? []
    }

    /// Whether a geometry change on this view can affect the legacy constraint graph.
    ///
    /// Views that do not participate in Auto Layout (default `translatesAutoresizingMaskIntoConstraints`,
    /// no legacy constraints, no intrinsic size) are positioned by frames alone. Dirtying the
    /// constraint graph for every frame assignment made non-Auto Layout containers (collection-view
    /// cells, overlay views) re-solve and re-invalidate on each layout pass.
    internal var legacyGeometryAffectsConstraints: Bool {
        guard let state = LegacyViewState.existing(of: self) else { return false }
        if !state.constraints.isEmpty { return true }
        if state.translatesAutoresizingMaskIntoConstraints == false { return true }
        if let intrinsic = state.intrinsicContentSize { return true }
        return false
    }

    /// Last global invalidation counter value consumed by this view's constraint walk.
    internal var legacyHandledLayoutInvalidation: Int {
        get { LegacyViewState.existing(of: self)?.handledInvalidation ?? -1 }
        set { legacyMutableState(self).handledInvalidation = newValue }
    }

    /// Whether the backported layout pass is pending for this view.
    ///
    /// Used to skip solving the constraint system when nothing in this view changed: the swizzled
    /// `-layoutSubviews` hook otherwise runs a complete solver pass for every view in the hierarchy.
    internal var legacyNeedsLayoutPass: Bool {
        LegacyViewState.existing(of: self)?.needsLayout ?? false
    }

    /// Whether this view's backported `constraintsAreClean` flag is clear (internal, for tests).
    internal var legacyConstraintsAreDirty: Bool {
        !(LegacyViewState.existing(of: self)?.constraintsAreClean ?? false)
    }

    /// RRAutoLayout's `rr_informContainerThatSubviewsNeedUpdateConstraints`: constraint changes on a
    /// subview must schedule a layout of the container, not of the subview in isolation.
    internal func legacyInformContainerThatSubviewsNeedUpdateConstraints() {
        guard let superview = superview else { return }
        LegacyAutoLayoutRuntime.containerLayoutInvalidationCount += 1
        superview.setNeedsLayout()
    }
}

/// The semantic layout direction the legacy engine should resolve `leading`/`trailing` against.
///
/// iOS 6 derived this from the *application's* localization (one process-wide direction; there was no
/// per-view override until `semanticContentAttribute` in iOS 9), and RRAutoLayout had no direction
/// handling at all. `UIApplication.userInterfaceLayoutDirection` is the closest faithful query; it is
/// iOS 9+, so older systems stay left-to-right — which matches the documented iOS 6 behaviour for
/// non-RTL-localized apps (semantics research §2.4).
@MainActor
internal enum LegacyAutoLayoutSemanticDirection {

    internal static var current: RRLayoutDirection {
        if #available(iOS 9.0, *) {
            return UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
                ? .rightToLeft
                : .leftToRight
        }
        return .leftToRight
    }
}

// MARK: - LegacyLayoutItem

/// `UIView` is the only UIKit-backed `LegacyLayoutItem` in the backport (UILayoutGuide-style items are
/// out of scope: constraints that reference a non-UIView item simply have no layout item behind the
/// `Any?` reference and are ignored by the engine, exactly as they are by RRAutoLayout).
///
/// `layoutSetFrame(_:)` writes `bounds` + `center` instead of `frame`, exactly like RRAutoLayout's
/// ad-hoc pass did: `setFrame:` rounds through `setBounds:`/`setCenter:` and would re-enter the
/// swizzled invalidation hooks (and is wrong under a non-identity transform), whereas
/// `bounds`/`center` are the two primitives UIKit itself uses.
@MainActor
extension UIView: LegacyLayoutItem {

    var layoutSuperitem: LegacyLayoutItem? {
        superview
    }

    var layoutSubitems: [LegacyLayoutItem] {
        subviews
    }

    var layoutFrame: CGRect {
        frame
    }

    func layoutSetFrame(_ frame: CGRect) {
        // Defensive: the engine clamps as well, but a negative size must never reach UIKit.
        let size = CGSize(width: max(0, frame.size.width), height: max(0, frame.size.height))
        let targetCenter = CGPoint(
            x: frame.origin.x + size.width / 2,
            y: frame.origin.y + size.height / 2
        )

        // Skip no-op writes: each write can schedule UIKit layout work, so a converged engine pass
        // should not keep dirtying views.
        if abs(bounds.size.width - size.width) < 0.0001,
           abs(bounds.size.height - size.height) < 0.0001,
           abs(center.x - targetCenter.x) < 0.0001,
           abs(center.y - targetCenter.y) < 0.0001 {
            return
        }

        var newBounds = bounds
        newBounds.size = size
        bounds = newBounds
        center = targetCenter
    }

    var layoutConstraints: [RRLayoutConstraint] {
        legacyConstraints
    }

    var layoutTranslatesAutoresizingMaskIntoConstraints: Bool {
        legacyTranslatesAutoresizingMaskIntoConstraints
    }

    /// The view's real `autoresizingMask`, mapped into the UIKit-raw-value `RRAutoresizingMask`.
    var layoutAutoresizingMask: RRAutoresizingMask {
        RRAutoresizingMask(rawValue: autoresizingMask.rawValue)
    }

    /// The geometry the engine last generated this view's autoresizing-mask constraints from.
    ///
    /// Stored as an associated object so it survives layout passes; the engine captures it implicitly
    /// when `nil` and calls `layoutUpdateAutoresizingReference(_:)` after a successful write-back.
    var layoutAutoresizingReference: LegacyAutoresizingReference? {
        LegacyViewState.existing(of: self)?.autoresizingReference
    }

    /// Records the geometry the engine generated the autoresizing-mask constraints from.
    func layoutUpdateAutoresizingReference(_ reference: LegacyAutoresizingReference) {
        legacyMutableState(self).autoresizingReference = reference
    }

    var layoutIntrinsicContentSize: CGSize {
        legacyIntrinsicContentSize
    }

    func layoutContentHuggingPriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        legacyContentHuggingPriority(for: axis)
    }

    func layoutContentCompressionResistancePriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        legacyContentCompressionResistancePriority(for: axis)
    }

    var layoutFirstBaselineOffsetFromTop: CGFloat? {
        LegacyViewState.existing(of: self)?.firstBaselineOffsetFromTop
    }

    var layoutLastBaselineOffsetFromBottom: CGFloat? {
        LegacyViewState.existing(of: self)?.lastBaselineOffsetFromBottom
    }
}
