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
        let start = LegacyBridgeStats.begin()
        defer { if start != 0 { LegacyBridgeStats.record(start, &LegacyBridgeStats.legacyAdd) } }
        LegacyAutoLayout.ensureInstalled()
        let stateStart = LegacyBridgeStats.begin()
        let state = legacyMutableState(self)
        if stateStart != 0 { LegacyBridgeStats.record(stateStart, &LegacyBridgeStats.legacyStorage) }
        if !state.constraints.contains(where: { $0 === constraint }) {
            state.constraints.append(constraint)
            state.constraintsSorted = false
            LegacyLayoutMutation.bumpConstraints()
        }
        // Constraint changes can change the solved geometry; force a fresh autoresizing capture.
        state.autoresizingReference = nil
        legacyMarkNeedsConstraintsUpdate(state)
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
        let start = LegacyBridgeStats.begin()
        defer { if start != 0 { LegacyBridgeStats.record(start, &LegacyBridgeStats.legacyRemove) } }
        guard let state = LegacyViewState.existing(of: self),
              let index = state.constraints.firstIndex(where: { $0 === constraint }) else {
            return
        }
        state.constraints.remove(at: index)
        LegacyLayoutMutation.bumpConstraints()
        state.autoresizingReference = nil
        legacyMarkNeedsConstraintsUpdate(state)
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
            let state = legacyMutableState(self)
            state.translatesAutoresizingMaskIntoConstraints = newValue
            LegacyLayoutMutation.bump()
            // A flag flip changes whether (and from which geometry) autoresizing constraints are
            // generated, so the captured reference is stale.
            state.autoresizingReference = nil
            legacyMarkNeedsConstraintsUpdate(state)
        }
    }

    // MARK: Intrinsic content size

    /// The value returned by a subclass's own `-intrinsicContentSize`, or nil when the view only has the backport's
    /// forwarding method (or the system's).
    @MainActor
    private func legacyIntrinsicContentSizeOverride() -> CGSize? {
        // A class whose image is the system's own UIKit (UIButton, UILabel, ...) has an -intrinsicContentSize that
        // chains into the backport's method, which would recurse. Classes from the app or from the backport
        // library (OAStackView / UIStackView) may supply a real override.
        // Which implementation (if any) a class contributes is a property of the class, so it is resolved once per class
        // instead of per view per layout pass (class_getImageName + string tests + a method lookup each time).
        let selector = NSSelectorFromString("intrinsicContentSize")
        let cls: AnyClass = type(of: self)
        let key = ObjectIdentifier(cls)
        let entry: LegacyIntrinsicOverride.ClassEntry
        if let cached = LegacyIntrinsicOverride.classEntries[key] { entry = cached } else {
            var resolved: IMP? = nil
            if !legacyIsSystemUIKitClass(cls), let method = class_getInstanceMethod(cls, selector) {
                let implementation = method_getImplementation(method)
                if implementation != LegacyIntrinsicOverride.backportImplementation,
                   implementation != LegacyIntrinsicOverride.uiViewImplementation { resolved = implementation }
            }
            entry = LegacyIntrinsicOverride.ClassEntry(implementation: resolved)
            LegacyIntrinsicOverride.classEntries[key] = entry
        }
        guard let implementation = entry.implementation else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> CGSize
        return unsafeBitCast(implementation, to: Getter.self)(self, selector)
    }

    /// Backport of `intrinsicContentSize` (default `UIViewNoIntrinsicMetric`).
    var legacyIntrinsicContentSize: CGSize {
        get {
            if let label = self as? UILabel {
                let key = "\(label.text?.hashValue ?? 0):\(label.attributedText?.length ?? 0):"
                    + "\(label.font?.fontName ?? ""):\(label.font?.pointSize ?? 0):"
                    + "\(label.numberOfLines):\(label.lineBreakMode.rawValue)"
                let state = legacyMutableState(label)
                if state.intrinsicMeasurementKey != key {
                    state.intrinsicMeasurementKey = key
                    state.systemIntrinsicCache = nil
                }
            }
            if let value = LegacyViewState.existing(of: self)?.intrinsicContentSize {
                return value
            }
            // A subclass that overrides -intrinsicContentSize (how every Auto Layout app supplies it) is the
            // authority, exactly as in iOS 6, where the engine messages the view. The backport's own method
            // forwards here, so it must be skipped to avoid recursion.
            if let overridden = legacyIntrinsicContentSizeOverride() { return overridden }
            if legacyUsesDirectStackLayout {
                let fitted = sizeThatFits(CGSize(width: max(0, bounds.width), height: -1))
                return CGSize(width: LegacyLayoutMetrics.noIntrinsicMetric, height: fitted.height)
            }
            if legacyProvidesSystemIntrinsicSize { LegacyViewState.of(self).systemIntrinsicObserved = true }
            // Real iOS 6+ UILabel measurement: a multiline label that would be
            // wider than `preferredMaxLayoutWidth` reports that width and the
            // height it needs at it. Zero keeps the automatic behaviour.
            if let label = self as? UILabel, label.numberOfLines != 1,
               let state = LegacyViewState.existing(of: self),
               let preferred = (state.preferredMaxLayoutWidth ?? 0) > 0 ? state.preferredMaxLayoutWidth : state.measuredWrapWidth,
               preferred > 0 {
                let natural = sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
                if natural.width > preferred {
                    let height = sizeThatFits(CGSize(width: preferred, height: CGFloat.greatestFiniteMagnitude)).height
                    return CGSize(width: preferred, height: height)
                }
                return natural
            }
            if let size = legacySystemIntrinsicSize { return size }
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

    /// Runs the legacy layout pass covering this view's subtree.
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
        // Apps call layoutIfNeeded from completion handlers on background queues. The engine's caches and solvers are
        // process-wide mutable state, so concurrent passes corrupt them (traps, spinning hash lookups). Serialize them.
        LegacyLayoutLock.shared.lock()
        defer { LegacyLayoutLock.shared.unlock() }
        legacyUpdateConstraintsIfNeeded()

        let engine = LegacyLayoutEngine(direction: LegacyAutoLayoutSemanticDirection.current)
        // The engine writes frames through `layoutSetFrame(_:)`; flag that so the swizzled
        // setBounds:/setCenter: hooks do not re-dirty the constraint graph for every written frame
        // (that is what would turn an RR-style pass into a layout feedback loop).
        let wasApplyingLayoutFrames = LegacyAutoLayoutRuntime.isApplyingLayoutFrames
        LegacyAutoLayoutRuntime.isApplyingLayoutFrames = true
        // The pass root follows the automatic callback path's selection (legacyAutomaticLayoutRoot):
        // UIKit 6.1's layoutBelowIfNeeded never solves a triggering view in isolation. A hierarchy
        // with no engine gets a temporary engine at the topmost ancestor, pinned to its current
        // frame; a windowed view promotes to the ancestor owning the crossing equations. Solving
        // the triggering view as its own root drops the ancestor-owned equations that size it,
        // leaving its geometry an undetermined degree of freedom that the tableau resolves to
        // near-zero instead of the incumbent geometry (differential: children of aspect-sized
        // containers drifted 0.125–0.5pt off the native solution on every subtree pass — round 117).
        let passRoot = legacyAutomaticLayoutRoot()
        engine.layout(passRoot)
        // UIKit's second measuring step: multi-line labels the app gave no preferredMaxLayoutWidth are re-measured at the
        // width layout just gave them, then layout runs again. Bounded: a label settles in one or two rounds.
        var rounds = 0
        while rounds < 3, LegacyIntrinsicOverride.remeasureEnabled, legacyRemeasureWrappingLabels() {
            legacyUpdateConstraintsIfNeeded()
            engine.layout(passRoot)
            rounds += 1
        }
        LegacyAutoLayoutRuntime.isApplyingLayoutFrames = wasApplyingLayoutFrames

        // UIKit delivers -layoutSubviews to every view whose bounds size changed during the pass,
        // parents before children. The legacy engine only writes frames, so deliver it explicitly;
        // the reentrancy guard above is already released and each view is cleared before the call.
        legacyDeliverLayoutSubviews(from: passRoot)

        let state = legacyMutableState(passRoot)
        state.needsLayout = false
        state.containerInvalidated = false
        if passRoot !== self, let caller = LegacyViewState.existing(of: self) {
            caller.needsLayout = false
            caller.containerInvalidated = false
        }
    }


    /// Records the solved width of every multi-line label in this subtree that has no app-provided preferred width and
    /// invalidates its intrinsic size when that width changed. Returns whether anything was invalidated.
    @MainActor
    private func legacyRemeasureWrappingLabels() -> Bool {
        var changed = false
        var stack: [UIView] = [self]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard let label = view as? UILabel, label.numberOfLines != 1,
                  (LegacyViewState.existing(of: label)?.preferredMaxLayoutWidth ?? 0) <= 0 else { continue }
            let width = label.bounds.width
            guard width > 0 else { continue }
            let state = legacyMutableState(label)
            if let previous = state.measuredWrapWidth, abs(previous - width) < 0.5 { continue }
            state.measuredWrapWidth = width
            state.systemIntrinsicCache = nil
            label.legacySetNeedsUpdateConstraints()
            LegacyLayoutMutation.bump()
            changed = true
        }
        return changed
    }

    /// Delivers -layoutSubviews in Apple's order (depth-first, parent before children) for views
    /// whose settled bounds size changed in this pass. Apple's engine marks exactly those views dirty
    /// and UIKit lays them out; the legacy engine has to do it itself because it writes frames directly.
    /// `scope` widens the walk to a pass root promoted above `self` (see `legacyLayoutIfNeeded`).
    @MainActor
    private func legacyDeliverLayoutSubviews(from scope: UIView? = nil) {
        func deliver(_ view: UIView) {
            if let state = LegacyViewState.existing(of: view), state.pendingLayoutSubviews {
                state.pendingLayoutSubviews = false
                if !LegacyAutoLayoutRuntime.isApplyingLayoutFrames {
                    view.layoutSubviews()
                }
            }
            for child in view.subviews { deliver(child) }
        }
        let start = scope ?? self
        for child in start.subviews { deliver(child) }
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
        let state = legacyMutableState(self)
        legacyMarkNeedsConstraintsUpdate(state)
    }

    /// Dirty marking with an already-resolved state object (one associated-object
    /// lookup for the whole add/remove/flag change).
    private func legacyMarkNeedsConstraintsUpdate(_ state: LegacyViewState) {
        state.needsConstraintUpdateCallback = true
        state.constraintsAreClean = false
        // A constraint update is not a layout pass. The layer's update walk can
        // clear constraintsAreClean before -layoutSubviews; preserve this view's
        // pending solve independently or a detached controller root stays at its
        // children's zero authoring frames after it is attached to the window.
        state.needsLayout = true
        state.stackFittingResult = nil
        legacyPropagateGeometryParticipation()
        guard let superview = superview else {
            if !state.containerInvalidated {
                state.containerInvalidated = true
                LegacyAutoLayoutRuntime.containerLayoutInvalidationCount += 1
                setNeedsLayout()
            }
            return
        }
        // Every ancestor must see the change. UIKit lays the root view out once before
        // the controller adds its subviews and constraints, which leaves the root
        // flagged clean; the layoutSubviews hook and the constraint walk both start
        // from that flag, so without this the whole hierarchy keeps zero frames.
        // The walk stops at the first ancestor that is already flagged.
        var ancestor: UIView? = superview
        while let current = ancestor {
            let ancestorState = LegacyViewState.of(current)
            ancestorState.stackFittingResult = nil
            if ancestorState.needsLayout && !ancestorState.constraintsAreClean { break }
            ancestorState.needsLayout = true
            ancestorState.constraintsAreClean = false
            ancestor = current.superview
        }
        // Dedupe at the container, not at this view: a stack view activating 80
        // constraints on 20 children used to send 20 native setNeedsLayout calls
        // (and one per constraint on a host-owned burst). The container flag is
        // cleared when the container's constraints/layout pass runs.
        let containerState = LegacyViewState.of(superview)
        guard !containerState.containerInvalidated else { return }
        containerState.containerInvalidated = true
        let start = LegacyBridgeStats.begin()
        LegacyAutoLayoutRuntime.containerLayoutInvalidationCount += 1
        superview.setNeedsLayout()
        if start != 0 { LegacyBridgeStats.record(start, &LegacyBridgeStats.containerInvalidation) }
    }

    /// Runs the pending constraint update for this view and its subviews (backport of
    /// `updateConstraintsIfNeeded`). Mirrors RRAutoLayout's recursive dirty-flag walk.
    func legacyUpdateConstraintsIfNeeded() {
        LegacyAutoLayout.ensureInstalled()
        guard !(LegacyViewState.existing(of: self)?.constraintsAreClean ?? false) else { return }

        let state = legacyMutableState(self)
        guard !state.isUpdatingConstraintCallbacks else { return }
        state.isUpdatingConstraintCallbacks = true
        defer { state.isUpdatingConstraintCallbacks = false }
        // Native UIKit updates descendants before dispatching this view's public
        // override. A direct Swift helper call silently bypasses subclass methods.
        for subview in subviews {
            subview.legacyUpdateConstraintsIfNeeded()
        }
        if state.needsConstraintUpdateCallback {
            state.needsConstraintUpdateCallback = false
            if let controller = LegacyControllerConstraintUpdates.owner(of: self) {
                _ = controller.perform(LegacyControllerConstraintUpdates.selector)
            } else {
                _ = perform(NSSelectorFromString("updateConstraints"))
            }
        }

        state.constraintsAreClean = !state.needsConstraintUpdateCallback
        state.containerInvalidated = false
    }

    // MARK: Internal bridge hooks (used by LegacyAutoLayoutSwizzling)

    /// The body of the backported `-updateConstraints`, mirroring RRAutoLayout's split into a content
    /// size hook and an autoresizing-translation hook. Subclasses cannot override this in Swift (no
    /// ObjC category override), so it is an internal, documented extension point rather than a method
    /// that apps are expected to override.
    internal func legacyUpdateConstraints() {
        legacyUpdateContentSizeConstraints()
        legacyUpdateAutoresizingConstraints()
        // A public direct update consumes this view's pending callback too, not
        // only an update dispatched by the recursive walker. Native iOS 6 marks
        // the view clean in the base method. Keep subtree traversal dirty here:
        // a descendant may still need its own callback after this direct call.
        legacyMutableState(self).needsConstraintUpdateCallback = false
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
        if let state = LegacyViewState.existing(of: self) {
            if !state.constraints.isEmpty { return true }
            if state.translatesAutoresizingMaskIntoConstraints == false { return true }
            if state.intrinsicContentSize != nil { return true }
        }
        if LegacyLayoutEngine.diagnosticDisableGeometryPropagation { return false }
        return LegacyViewState.existing(of: self)?.geometryAnchorsLayout ?? false
    }

    /// O(depth) only when participation first reaches an ancestor; geometry reads
    /// remain O(1). Insertion propagates a moved participating subtree too.
    internal func legacyPropagateGeometryParticipation() {
        var ancestor: UIView? = self
        while let current = ancestor {
            let state = LegacyViewState.of(current)
            if state.geometryAnchorsLayout { break }
            state.geometryAnchorsLayout = true
            ancestor = current.superview
        }
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
        let state = legacyMutableState(self)
        guard !state.containerInvalidated else { return }
        state.containerInvalidated = true
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
/// Geometry uses bounds/center, like native Auto Layout: public frame setters
/// can clamp control sizes and are undefined under non-identity transforms.
/// Native controls retain ownership of their internal subview layout.
@MainActor
extension UIView: LegacyLayoutItem {

    var layoutSuperitem: LegacyLayoutItem? {
        superview
    }

    var layoutSubitems: [LegacyLayoutItem] {
        // A collection view positions its cells itself (frames come from the layout object, never from constraints
        // of an ancestor) and every cell is laid out as its own root by its own layoutSubviews. Descending into
        // them made each ancestor pass re-solve hundreds of unrelated variables whenever cells were recycled.
        if LegacyCollectionViewClass.isCollectionView(self) || legacyUsesDirectStackLayout { return [] }
        if self is UITextView || self is UIControl || legacyProvidesSystemIntrinsicSize {
            // UIKit owns the internal geometry of its composite leaf controls:
            // text canvases, progress tracks, slider thumbs and button labels.
            // Solving those implementation details as authoring-time autoresizing
            // children replays stale sizes over the native control's layout.
            // Explicitly opted-in client overlay subviews still participate.
            return subviews.filter { child in
                guard let state = LegacyViewState.existing(of: child) else { return false }
                return state.translatesAutoresizingMaskIntoConstraints == false
                    || !state.constraints.isEmpty || state.intrinsicContentSize != nil
            }
        }
        return subviews
    }

    var layoutHasScrollContent: Bool {
        // iOS 6 Auto Layout resolves a scroll view's leading/trailing/top/bottom against its CONTENT area when the
        // other item is a descendant, and sizes contentSize from it. Verified against native Auto Layout by
        // Tests/run-simulator-chat-test.sh. LEGACY_AUTOLAYOUT_NO_SCROLL_CONTENT=1 restores viewport edges (diagnostics).
        !LegacyScrollContent.disabled && self is UIScrollView &&
            !(self is UITextView) && !LegacyCollectionViewClass.isCollectionView(self)
    }

    func layoutSetScrollContentSize(_ size: CGSize) {
        guard let scroll = self as? UIScrollView else { return }
        if scroll.contentSize != size { scroll.contentSize = size }
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

        // A settled bounds size change is what makes UIKit deliver -layoutSubviews after the pass.
        if abs(bounds.size.width - size.width) >= 0.0001
            || abs(bounds.size.height - size.height) >= 0.0001 {
            legacyMutableState(self).pendingLayoutSubviews = true
        }

        // Skip no-op writes: each write can schedule UIKit layout work, so a converged engine pass
        // should not keep dirtying views.
        if abs(bounds.size.width - size.width) < 0.0001,
           abs(bounds.size.height - size.height) < 0.0001,
           abs(center.x - targetCenter.x) < 0.0001,
           abs(center.y - targetCenter.y) < 0.0001 {
            return
        }

        if LegacyLayoutStats.enabled, NSStringFromClass(type(of: self)).contains("InputView") {
            FileHandle.standardError.write(Data("legacy-write: \(type(of: self)) \(bounds.size.width)x\(bounds.size.height) -> \(size.width)x\(size.height) at t=\(CFAbsoluteTimeGetCurrent())\n".utf8))
        }
        if let text = self as? UITextView, transform.isIdentity,
           !text.responds(to: NSSelectorFromString("textContainer")) {
            LegacyAutoLayoutInstaller.resizeLegacyTextViewport(text, frame: CGRect(origin: frame.origin, size: size))
        }
        // Notify normal control geometry setters (UISlider resizes its owned
        // implementation view there). If a legacy setter clamps a required
        // dimension, finish through UIView's native primitives so the layout
        // result, not the control's authoring-time default, wins.
        var newBounds = bounds
        newBounds.size = size
        bounds = newBounds
        center = targetCenter
        if abs(bounds.width - size.width) >= 0.0001 || abs(bounds.height - size.height) >= 0.0001
            || abs(center.x - targetCenter.x) >= 0.0001 || abs(center.y - targetCenter.y) >= 0.0001 {
            LegacyAutoLayoutInstaller.writeLayoutGeometry(to: self, bounds: newBounds, center: targetCenter)
        }
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


/// Detects the collection view backport without linking against it (the runtime is a separate archive).
@MainActor
internal enum LegacyCollectionViewClass {
    private static let classes: [AnyClass] = ["PSTCollectionView", "UICollectionView"].compactMap { NSClassFromString($0) }
    @inline(__always)
    static func isCollectionView(_ view: UIView) -> Bool {
        for cls in classes where view.isKind(of: cls) { return true }
        return false
    }
}


extension UIView {
    internal var legacyUsesDirectStackLayout: Bool {
        let sel = NSSelectorFromString("uic_usesDirectStackLayout")
        guard let method = class_getInstanceMethod(type(of: self), sel) else { return false }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(self, sel)
    }

    /// Lets a container that writes its children's frames itself (OAStackView's direct layout) mark those writes as
    /// layout output, exactly like the engine does, so the geometry hooks do not treat them as outside changes that
    /// invalidate the children's cached fitting sizes. Returns the previous value, to be restored by the caller.
    @objc(uic_beginApplyingLayoutFrames)
    internal static func uicBeginApplyingLayoutFrames() -> Bool {
        let previous = LegacyAutoLayoutRuntime.isApplyingLayoutFrames
        LegacyAutoLayoutRuntime.isApplyingLayoutFrames = true
        return previous
    }

    @objc(uic_endApplyingLayoutFrames:)
    internal static func uicEndApplyingLayoutFrames(_ previous: Bool) {
        LegacyAutoLayoutRuntime.isApplyingLayoutFrames = previous
    }

    /// Clears the cached fitting size of this view and every ancestor. Callers that own their
    /// children's frames (OAStackView's direct layout) change the content those caches describe
    /// without going through `legacySetNeedsUpdateConstraints`; without this, a local layout pass
    /// reuses the pre-change fitting size and the container keeps its stale height.
    @objc(uic_clearStackFittingCaches)
    internal func uicClearStackFittingCaches() {
        var view: UIView? = self
        while let current = view {
            let state = LegacyViewState.of(current)
            if state.stackFittingResult != nil || state.stackFittingProposal != nil {
                state.stackFittingResult = nil
                state.stackFittingProposal = nil
            }
            view = current.superview
        }
        LegacyLayoutMutation.bump()
    }

    /// Solves this view's constraints for a size near `target`, each axis pulled at its own priority.
    /// Nothing is written to the view: this is a measurement.
    internal func legacyFittingSize(_ target: CGSize, _ horizontal: Float, _ vertical: Float) -> CGSize {
        if legacyUsesDirectStackLayout { return sizeThatFits(target) }
        LegacyLayoutLock.shared.lock(); defer { LegacyLayoutLock.shared.unlock() }
        let fitting = LegacyLayoutSolver(root: self, direction: LegacyAutoLayoutSemanticDirection.current)
        fitting.fittingProposal = (width: nil, height: nil)
        fitting.fittingTargets = (width: target.width, widthPriority: horizontal, height: target.height, heightPriority: vertical)
        _ = fitting.solve(writingFrames: false)
        return fitting.fittedRootSize
    }

    /// Private, dynamically dispatched bridge so CGRect/CGSize use Objective-C's platform ABI.
    @objc(uic_legacyStackFittingSize:)
    internal func legacyStackFittingSize(_ proposal: CGSize) -> CGSize {
        if legacyUsesDirectStackLayout { return sizeThatFits(proposal) }
        if self is UILabel || self is UIImageView || self is UIButton {
            let measured = sizeThatFits(CGSize(width: proposal.width >= 0 ? proposal.width : 100000,
                                              height: proposal.height >= 0 ? proposal.height : 100000))
            return CGSize(width: proposal.width >= 0 ? proposal.width : measured.width,
                          height: proposal.height >= 0 ? proposal.height : measured.height)
        }
        let state = LegacyViewState.of(self)
        if state.stackFittingProposal == proposal, let cached = state.stackFittingResult { LegacyLayoutDebug.fitHits += 1; return cached }
        LegacyLayoutDebug.fitMisses += 1
        if state.stackFittingResult == nil && state.stackFittingProposal != nil { LegacyLayoutDebug.fitMissInvalidated += 1 }
        else if state.stackFittingProposal != nil { LegacyLayoutDebug.fitMissProposal += 1 } else { LegacyLayoutDebug.fitMissFirst += 1 }
        let fitting = LegacyLayoutSolver(root: self, direction: LegacyAutoLayoutSemanticDirection.current)
        fitting.fittingProposal = (width: proposal.width >= 0 ? proposal.width : nil,
                                   height: proposal.height >= 0 ? proposal.height : nil)
        _ = fitting.solve(writingFrames: false)
        state.stackFittingProposal = proposal
        state.stackFittingResult = fitting.fittedRootSize
        return fitting.fittedRootSize
    }
}

/// Serializes every legacy layout pass (the engine state is global and not thread-safe).
internal final class LegacyLayoutLock {
    internal static let shared = NSRecursiveLock()
}


internal enum LegacyScrollContent {
    internal static let disabled: Bool = legacyEnvironmentFlag("LEGACY_AUTOLAYOUT_NO_SCROLL_CONTENT")
}


/// Identity of the implementations that must NOT be treated as a subclass override.
internal enum LegacyIntrinsicOverride {
    /// The backport's forwarding method, installed on UIView (written once, on the main thread, at install).
    nonisolated(unsafe) static var backportImplementation: IMP? = nil
    /// UIView's own implementation (when the OS has one), captured before any backport method is added.
    nonisolated(unsafe) static var uiViewImplementation: IMP? = nil
    /// Per-class result of the override lookup (nil implementation = the class adds no override).
    struct ClassEntry { let implementation: IMP? }
    nonisolated(unsafe) static var classEntries: [ObjectIdentifier: ClassEntry] = [:]
    /// Device A/B switch (env.txt: LEGACY_AUTOLAYOUT_NO_REMEASURE=1) for the second measuring step.
    nonisolated(unsafe) static let remeasureEnabled: Bool = getenv("LEGACY_AUTOLAYOUT_NO_REMEASURE") == nil
}
