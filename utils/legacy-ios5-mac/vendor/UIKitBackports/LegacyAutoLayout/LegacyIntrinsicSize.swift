import UIKit
import ObjectiveC

// iOS 6 gave every UIKit control that has a natural size an `intrinsicContentSize`
// (UISwitch, UITextField, UIStepper, UIPageControl, UISegmentedControl, UISlider's
// height, UIToolbar's height, ...). On iOS 5 those controls already know their natural
// size through `-sizeThatFits:`; the system implementation of that method is the single
// source of truth, so the legacy engine derives the intrinsic size from it instead of
// keeping a table of classes that would go stale.
//
// The rule, applied to the nearest *system* class that implements `-sizeThatFits:`:
//   * the view's size is `sizeThatFits(.greatestFiniteMagnitude)`;
//   * an axis that merely echoes the proposed size is flexible (a slider's width, a
//     toolbar's width) and reports `UIViewNoIntrinsicMetric`, exactly as UIKit does;
//   * scroll views never report an intrinsic size (UIScrollView, UITableView, UITextView);
//   * app-defined subclasses are ignored here: a custom `sizeThatFits:` has never produced
//     an intrinsic size, only overriding `intrinsicContentSize` does.
//
// The per-class decision (which axes are flexible, whether a system implementation exists)
// is made once and cached; evaluating an instance costs one `sizeThatFits:` call.

private struct LegacyIntrinsicPolicy {
    var providesSize: Bool
    var axesProbed = false
    var widthFlexible = false
    var heightFlexible = false
}

@MainActor private var legacyIntrinsicPolicies: [ObjectIdentifier: LegacyIntrinsicPolicy] = [:]

/// A class is the app's own when its image lives inside the app bundle (the executable, its
/// Frameworks or a plug-in). Everything else - UIKit, and the legacy UIKit overlay that
/// stands in for it - is the system. Decided from the image path, not from a class list.
internal func legacyIsAppClass(_ cls: AnyClass) -> Bool {
    guard let image = class_getImageName(cls) else { return true }
    let bundle = Bundle.main.bundlePath
    return !bundle.isEmpty && String(cString: image).hasPrefix(bundle)
        && !String(cString: image).contains("libswiftUIKit")
}

/// True when the class is implemented by the OS's own frameworks (not the app, not the backport overlay).
@MainActor private var legacySystemClassCache: [ObjectIdentifier: Bool] = [:]

@MainActor
internal func legacyIsSystemUIKitClass(_ cls: AnyClass) -> Bool {
    let key = ObjectIdentifier(cls)
    if let cached = legacySystemClassCache[key] { return cached }
    var result = false
    if let image = class_getImageName(cls) {
        let path = String(cString: image)
        result = path.contains("/System/Library/") && !path.contains("libswiftUIKit")
    }
    legacySystemClassCache[key] = result
    return result
}

/// Class-level decision only (runtime metadata, no call into the instance), so it is safe to
/// evaluate from inside `-setNeedsDisplay` / `-setNeedsLayout` on a half-initialised view.
@MainActor
private func legacyIntrinsicPolicy(for view: UIView) -> LegacyIntrinsicPolicy {
    let key = ObjectIdentifier(type(of: view))
    if let cached = legacyIntrinsicPolicies[key] { return cached }

    let selector = #selector(UIView.sizeThatFits(_:))
    let baseImplementation = class_getMethodImplementation(UIView.self, selector)
    var provides = false
    if !(view is UIScrollView) {
        var cls: AnyClass? = type(of: view)
        while let current = cls, current != UIView.self {
            if !legacyIsAppClass(current),
               let method = class_getInstanceMethod(current, selector),
               method_getImplementation(method) != baseImplementation {
                provides = true
                break
            }
            cls = class_getSuperclass(current)
        }
    }
    let policy = LegacyIntrinsicPolicy(providesSize: provides)
    legacyIntrinsicPolicies[key] = policy
    return policy
}

/// Which axes track the proposal is learned once per class from a real instance.
@MainActor
private func legacyIntrinsicAxes(for view: UIView) -> LegacyIntrinsicPolicy {
    var policy = legacyIntrinsicPolicy(for: view)
    guard policy.providesSize, !policy.axesProbed else { return policy }
    let small = view.sizeThatFits(CGSize(width: 1000, height: 1000))
    let large = view.sizeThatFits(CGSize(width: 5000, height: 5000))
    policy.widthFlexible = abs(small.width - large.width) > 1 && large.width >= 4999
    policy.heightFlexible = abs(small.height - large.height) > 1 && large.height >= 4999
    policy.axesProbed = true
    legacyIntrinsicPolicies[ObjectIdentifier(type(of: view))] = policy
    return policy
}

extension UIView {
    /// The intrinsic size a system control reports, or `nil` when the view has none.
    /// Cached per view until UIKit invalidates the view's content (see
    /// `legacyContentMayHaveChanged`), so a layout pass never re-measures an unchanged control.
    @MainActor
    internal var legacyProvidesSystemIntrinsicSize: Bool { legacyIntrinsicPolicy(for: self).providesSize }

    @MainActor
    internal var legacySystemIntrinsicSize: CGSize? {
        if let imageView = self as? UIImageView, imageView.image == nil && imageView.highlightedImage == nil {
            return CGSize(width: LegacyLayoutMetrics.noIntrinsicMetric, height: LegacyLayoutMetrics.noIntrinsicMetric)
        }
        guard legacyIntrinsicPolicy(for: self).providesSize else { return nil }
        if let cached = LegacyViewState.existing(of: self)?.systemIntrinsicCache { return cached }
        let policy = legacyIntrinsicAxes(for: self)
        let size = sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude,
                                       height: CGFloat.greatestFiniteMagnitude))
        let none = LegacyLayoutMetrics.noIntrinsicMetric
        let result = CGSize(width: policy.widthFlexible ? none : size.width,
                            height: policy.heightFlexible ? none : size.height)
        LegacyViewState.of(self).systemIntrinsicCache = result
        return result
    }

    /// iOS 6 UIKit calls `invalidateIntrinsicContentSize` from the setters that change a
    /// control's natural size (text, font, title, image, border style...). iOS 5 UIKit does
    /// not, but every such change invalidates the view's display or layout. Called from the
    /// `-setNeedsDisplay` / `-setNeedsLayout` hooks for views the engine has measured.
    ///
    /// UIKit also calls those methods for reasons that do not change the size (a text field's
    /// caret, a button highlight, the layout pass itself), so the size is re-measured and the
    /// engine is told only when it really changed. That keeps an edited text field or a
    /// highlighted button from re-dirtying layout on every frame, and costs one
    /// `-sizeThatFits:` per call on controls that are part of a constraint layout.
    @MainActor
    internal func legacyContentMayHaveChanged() {
        guard !LegacyAutoLayoutRuntime.isApplyingLayoutFrames,
              let state = LegacyViewState.existing(of: self),
              state.systemIntrinsicObserved else { return }
        // Views whose size is computed outside the cache (a wrapping label) have no previous
        // value to compare with, so any invalidation is treated as a possible change.
        guard let previous = state.systemIntrinsicCache else {
            LegacyLayoutMutation.bump()
            legacySetNeedsUpdateConstraints()
            return
        }
        state.systemIntrinsicCache = nil
        guard let current = legacySystemIntrinsicSize else { return }
        if current != previous {
            LegacyLayoutMutation.bump()
            legacySetNeedsUpdateConstraints()
        }
    }
}
