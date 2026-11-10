import UIKit

extension UIView {
    /// The view whose coordinate space the automatic layout pass solves in.
    ///
    /// UIKit 6.1 keeps one layout engine per window (UIView _layoutEngine @0054d5b0 forwards to
    /// the window's engine), so the view that triggers a pass is never treated as a fixed
    /// boundary. `-[UIView layoutBelowIfNeeded]` (@00054306) instead makes the participating view
    /// a variable of that engine, and for a hierarchy with no engine it creates a temporary engine
    /// and walks to the topmost ancestor (@0005439a–@000545ec), pinning that ancestor's geometry.
    ///
    /// Solving the triggering view itself pins its *current* frame at required strength and omits
    /// the ancestor-owned equations that are supposed to size it: a container that must grow to fit
    /// a newly inserted bubble stays at its old height and its content is compressed away.
    ///
    /// This backport cannot collect a whole window for every callback, so it promotes one level: to
    /// the immediate ancestor that owns an equation crossing from this view to that ancestor. That
    /// is the smallest scope in which this view's own geometry is a variable, and it avoids pulling
    /// unrelated system-managed internals (UIButton/UIImageView labels and images, whose translating
    /// masks carry stale authoring frames) into the solver.
    @MainActor
    internal func legacyAutomaticLayoutRoot() -> UIView {
        if window == nil {
            // No engine hierarchy exists: UIKit's temporary-engine path anchors the top ancestor.
            var top: UIView = self
            while let parent = top.superview { top = parent }
            return top
        }
        if let promoted = legacyConstrainedAncestorBoundary() { return promoted }
        guard !legacyTranslatesAutoresizingMaskIntoConstraints,
              let scroll = superview as? UIScrollView,
              scroll.layoutHasScrollContent else { return self }
        let contentBoundary = scroll.legacyConstraints.contains { constraint in
            guard constraint.relation == .equal,
                  constraint.firstAttribute == .bottom,
                  constraint.secondAttribute == .bottom else { return false }
            return ((constraint.firstItem as? UIView) === self && (constraint.secondItem as? UIView) === scroll)
                || ((constraint.secondItem as? UIView) === self && (constraint.firstItem as? UIView) === scroll)
        }
        return contentBoundary ? scroll : self
    }

    /// The immediate ancestor owning a constraint that crosses from this view to it, or nil when
    /// this view is unconstrained from above. See `legacyAutomaticLayoutRoot()` for why only one
    /// level is promoted.
    @MainActor
    private func legacyConstrainedAncestorBoundary() -> UIView? {
        guard !legacyTranslatesAutoresizingMaskIntoConstraints,
              let parent = superview else { return nil }
        // Only promote when the parent leaves this view's size to its content: an inequality on
        // width/height with no equality pinning that dimension. A view whose size the parent pins
        // with equalities is fully determined locally, and promoting would re-solve (and sometimes
        // collapse) the enclosing container — the channel list pane shrank that way.
        // Decided per axis: a parent that pins only this view's width says nothing about its height. The
        // typing-bubble host (width pinned to the screen, height left to its content with its own
        // `height >= 1`) must still promote, or its current 1pt height is pinned at required strength and
        // the content it holds is compressed away.
        var sizedByContent = (width: false, height: false)
        var pinnedByEquality = (width: false, height: false)
        func record(_ attribute: RRLayoutAttribute, _ relation: RRLayoutRelation, pinning: Bool) {
            guard attribute == .width || attribute == .height else { return }
            if relation == .equal {
                if pinning { if attribute == .width { pinnedByEquality.width = true } else { pinnedByEquality.height = true } }
            } else if relation == .greaterThanOrEqual || relation == .lessThanOrEqual {
                if attribute == .width { sizedByContent.width = true } else { sizedByContent.height = true }
            }
        }
        for constraint in parent.legacyConstraints {
            let first = constraint.firstItem as? UIView
            let second = constraint.secondItem as? UIView
            guard first === self || second === self else { continue }
            let ownAttribute = first === self ? constraint.firstAttribute : constraint.secondAttribute
            record(ownAttribute, constraint.relation, pinning: true)
        }
        // The view's own single-item inequalities (e.g. `height >= 1`) leave that axis to its content too.
        for constraint in legacyConstraints {
            guard (constraint.firstItem as? UIView) === self, constraint.secondItem == nil else { continue }
            record(constraint.firstAttribute, constraint.relation, pinning: false)
        }
        let promoteWidth = sizedByContent.width && !pinnedByEquality.width
        let promoteHeight = sizedByContent.height && !pinnedByEquality.height
        // Direct stacks omit their arranged-view equations. With only center
        // anchors the parent's equations, not the stack's incumbent bounds, must
        // position its changing natural size. A local pass would pin the old
        // width and discard the very equations that must let a label grow.
        let centeredDirectStack = legacyUsesDirectStackLayout && parent.legacyConstraints.contains { constraint in
            guard constraint.relation == .equal else { return false }
            let first = constraint.firstItem as? UIView
            let second = constraint.secondItem as? UIView
            let attribute = first === self ? constraint.firstAttribute : constraint.secondAttribute
            guard first === self || second === self else { return false }
            return (attribute == .centerX && !pinnedByEquality.width)
                || (attribute == .centerY && !pinnedByEquality.height)
        }
        return (promoteWidth || promoteHeight || centeredDirectStack) ? parent : nil
    }

    /// Only the automatic callback path changes root. Explicit
    /// fitting/dry-layout APIs retain their caller-selected coordinate spaces.
    @MainActor
    internal func legacyPerformAutomaticLayoutIfNeeded() {
        guard !LegacyAutoLayoutRuntime.isApplyingLayoutFrames else { return }
        let root = legacyAutomaticLayoutRoot()
        let state = LegacyViewState.of(root)
        guard !state.isPerformingAutomaticLayout else { return }
        state.isPerformingAutomaticLayout = true
        defer { state.isPerformingAutomaticLayout = false }
        root.legacyLayoutIfNeeded()
        if root !== self, let caller = LegacyViewState.existing(of: self) {
            caller.needsLayout = false
            caller.containerInvalidated = false
        }
    }
}
