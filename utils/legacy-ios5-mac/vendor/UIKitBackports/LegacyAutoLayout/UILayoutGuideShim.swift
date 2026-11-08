// Swift UILayoutGuide for the legacy UIKit overlay.
//
// UIKit's `UILayoutGuide` class is iOS 9. The runtime cannot register a class of
// that name (a target-5 binary running on iOS 9+ must not shadow the native
// class), so the legacy overlay supplies a Swift type with the same spelling and
// the same public surface. Each guide owns a hidden proxy view inside its owning
// view, which is the item the Auto Layout engine and UIKit both understand; the
// guide's anchors are the proxy view's anchors, so guide constraints behave like
// native guide constraints.
//
// Author-owned toolchain integration, adapted from the UIKitCompatKit APIShims
// snapshot. See THIRD-PARTY-NOTICES.md.
#if canImport(UIKit)
import UIKit
import ObjectiveC

private var layoutGuidesKey: UInt8 = 0
private var guideLayoutFrameKey: UInt8 = 0

/// Native NSLayoutConstraint accepts only views and native guides, so the Objective-C factory shim
/// asks this helper to turn a backport guide into its proxy view before calling UIKit.
@_cdecl("UICLegacyGuideProxyView")
public func _uicLegacyGuideProxyView(_ item: AnyObject?) -> AnyObject? {
    (item as? UILayoutGuide)?.proxyViewForConstraints
}

/// Ordinary `UILayoutGuide` spelling for systems without the native class.
@available(iOS, introduced: 5.0, obsoleted: 9.0)
public final class UILayoutGuide {
    /// The view this guide participates in, or `nil` before `addLayoutGuide`.
    public private(set) weak var owningView: UIView?

    /// Hidden proxy view used as the layout item for this guide's anchors.
    fileprivate let proxy = UIView()
    fileprivate var proxyViewForConstraints: UIView { proxy }

    public init() {
        proxy.translatesAutoresizingMaskIntoConstraints = false
        proxy.isHidden = true
        proxy.isUserInteractionEnabled = false
    }

    /// The guide's frame in its owning view's coordinate space.
    public var layoutFrame: CGRect {
        get {
            guard let owningView else { return .zero }
            return proxy.convert(proxy.bounds, to: owningView)
        }
        set {
            guard let owningView, let superview = proxy.superview else { return }
            proxy.frame = superview.convert(newValue, from: owningView)
        }
    }

    /// iOS 9 API kept for source compatibility; the backport has no identifier
    /// semantics beyond the debug description.
    public var identifier: String?

    fileprivate func attach(to view: UIView) {
        owningView = view
        if proxy.superview !== view { view.addSubview(proxy) }
    }

    fileprivate func detach() {
        proxy.removeFromSuperview()
        owningView = nil
    }
}

@available(iOS, introduced: 5.0, obsoleted: 9.0)
public extension UILayoutGuide {
    var leadingAnchor: Anchor { Anchor(item: proxy, attribute: .leading) }
    var trailingAnchor: Anchor { Anchor(item: proxy, attribute: .trailing) }
    var topAnchor: Anchor { Anchor(item: proxy, attribute: .top) }
    var bottomAnchor: Anchor { Anchor(item: proxy, attribute: .bottom) }
    var widthAnchor: Anchor { Anchor(item: proxy, attribute: .width) }
    var heightAnchor: Anchor { Anchor(item: proxy, attribute: .height) }
    var centerXAnchor: Anchor { Anchor(item: proxy, attribute: .centerX) }
    var centerYAnchor: Anchor { Anchor(item: proxy, attribute: .centerY) }
    var leftAnchor: Anchor { Anchor(item: proxy, attribute: .left) }
    var rightAnchor: Anchor { Anchor(item: proxy, attribute: .right) }
}

@available(iOS, introduced: 5.0, obsoleted: 9.0)
public extension UIView {
    /// All guides added to this view, in add order.
    var layoutGuides: [UILayoutGuide] {
        objc_getAssociatedObject(self, &layoutGuidesKey) as? [UILayoutGuide] ?? []
    }

    func addLayoutGuide(_ guide: UILayoutGuide) {
        var current = layoutGuides
        guard !current.contains(where: { $0 === guide }) else { return }
        guide.attach(to: self)
        current.append(guide)
        objc_setAssociatedObject(self, &layoutGuidesKey, current, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        invalidateIntrinsicContentSize()
    }

    func removeLayoutGuide(_ guide: UILayoutGuide) {
        var current = layoutGuides
        current.removeAll { $0 === guide }
        objc_setAssociatedObject(self, &layoutGuidesKey, current, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        guide.detach()
    }

    /// The view's margins guide, created on first use.
    var layoutMarginsGuide: UILayoutGuide {
        if let existing = objc_getAssociatedObject(self, &layoutMarginsGuideKey) as? UILayoutGuide {
            return existing
        }
        let guide = UILayoutGuide()
        addLayoutGuide(guide)
        // Pin the guide to the owning view's layout margins. `layoutMargins` is an iOS 8 API, so it must be
        // availability-checked here: the legacy slice compiles with availability lowered to 5.0 and never
        // takes the else branch, while an armv7s/arm64 slice built at an iOS 7 floor uses the default insets.
        let insets: UIEdgeInsets
        if #available(iOS 8.0, *) {
            insets = layoutMargins
        } else {
            insets = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        }
        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            guide.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
            guide.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            guide.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right)
        ])
        objc_setAssociatedObject(self, &layoutMarginsGuideKey, guide, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return guide
    }
}

private var safeAreaLayoutGuideKey: UInt8 = 0

@available(iOS, introduced: 5.0, obsoleted: 9.0)
public extension UIView {
    /// Genuine UIKit API (iOS 11) for the legacy configuration. No armv7 system
    /// that can run this binary implements safe areas, and on those systems the
    /// safe area equals the view's own bounds (no notch and no home indicator),
    /// so the backport guide is pinned to the bounds and reports them.
    var safeAreaLayoutGuide: UILayoutGuide {
        if let existing = objc_getAssociatedObject(self, &safeAreaLayoutGuideKey) as? UILayoutGuide {
            return existing
        }
        let guide = UILayoutGuide()
        addLayoutGuide(guide)
        // iOS 11+ has real safe areas (notch, home indicator, status bar under extended layout).
        // The guide must follow the system's own guide, not the view's bounds, or content sits
        // under the sensor housing. The native guide is reached by selector because this module
        // is compiled against the lowered backport surface; anchors come back as ordinary
        // NSLayoutAnchor objects. Below iOS 11 there are no safe areas and bounds are exact.
        let selector = NSSelectorFromString("safeAreaLayoutGuide")
        if responds(to: selector), let native = perform(selector)?.takeUnretainedValue() {
            // Native NSLayoutConstraint accepts the system's own guide as an item, and the factory
            // shim unwraps the backport guide to its proxy view on this side.
            let pairs: [(NSLayoutConstraint.Attribute, CGFloat)] = [(.top, 0), (.bottom, 0), (.leading, 0), (.trailing, 0)]
            NSLayoutConstraint.activate(pairs.map { attribute, constant in
                NSLayoutConstraint(item: guide, attribute: attribute, relatedBy: .equal,
                                   toItem: native, attribute: attribute, multiplier: 1, constant: constant)
            })
        } else {
            NSLayoutConstraint.activate([
                guide.topAnchor.constraint(equalTo: topAnchor),
                guide.bottomAnchor.constraint(equalTo: bottomAnchor),
                guide.leadingAnchor.constraint(equalTo: leadingAnchor),
                guide.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])
        }
        objc_setAssociatedObject(self, &safeAreaLayoutGuideKey, guide, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return guide
    }
}
private var layoutMarginsGuideKey: UInt8 = 0
#endif
