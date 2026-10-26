// Author-owned toolchain integration. See THIRD-PARTY-NOTICES.md.
import ObjectiveC
import CUIKitBackports

@_cdecl("UICLegacyInitializeAutoLayout")
public func _uicLegacyInitializeAutoLayout() {
    LegacyAutoLayout.ensureInstalled()
    UICInstallConstraintClassMethods()
}

private var _uicActiveConstraintKey: UInt8 = 0

/// The view UIKit would install `constraint` on: the closest common ancestor of
/// the two items (or the first item for a single-item constraint).
///
/// Nonisolated on purpose: the public shims that call it are ordinary
/// synchronous UIKit calls (see LegacyAutoLayoutIOS5.swift).
private func _uicConstraintOwner(_ constraint: NSLayoutConstraint) -> UIView? {
    guard let first = constraint.firstItem as? UIView else { return nil }
    guard let second = constraint.secondItem as? UIView else { return first }
    var ancestor: UIView? = first
    while let candidate = ancestor {
        var other: UIView? = second
        while let next = other { if next === candidate { return candidate }; other = next.superview }
        ancestor = candidate.superview
    }
    return nil
}

// `NSLayoutConstraint` is the public type throughout. On iOS 5 the class is
// registered by the runtime bridge (NativeAPIBridge.swift) and the instances app
// code holds are genuine instances of that class; `legacyLayoutModel(for:)`
// recovers the engine model behind one. On iOS 6+ the class is UIKit's own, no
// instance carries a model, and every entry point dispatches to UIKit by
// selector.
//
// The members are deliberately not `@MainActor` (see LegacyAutoLayoutIOS5.swift).
public extension NSLayoutConstraint {

    /// Backport of `NSLayoutConstraint.isActive` (iOS 8).
    @available(iOS, introduced: 5.0, obsoleted: 8.0)
    @_disfavoredOverload
    var isActive: Bool {
        get {
            if legacyLayoutModel(for: self) == nil {
                let selector = NSSelectorFromString("isActive")
                if let method = class_getInstanceMethod(type(of: self), selector) {
                    typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
                    return unsafeBitCast(method_getImplementation(method), to: Getter.self)(self, selector)
                }
            }
            return (objc_getAssociatedObject(self, &_uicActiveConstraintKey) as? NSNumber)?.boolValue ?? false
        }
        set {
            if legacyLayoutModel(for: self) != nil {
                // iOS 5: the instance is the runtime bridge's object. Activate it
                // through the ordinary UIView constraint API, exactly as UIKit
                // does, so `view.constraints` lists this same object and
                // deactivation removes it again.
                if let owner = _uicConstraintOwner(self) {
                    if newValue { owner.addConstraint(self) } else { owner.removeConstraint(self) }
                } else if newValue {
                    preconditionFailure("Cannot activate constraint without a common ancestor")
                }
                objc_setAssociatedObject(self, &_uicActiveConstraintKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                return
            }

            // iOS 8+: UIKit owns activation.
            let selector = NSSelectorFromString("setActive:")
            if let method = class_getInstanceMethod(type(of: self), selector) {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(method_getImplementation(method), to: Setter.self)(self, selector, newValue)
            } else if let owner = _uicConstraintOwner(self) {
                // iOS 6/7: UIKit has constraints but no `isActive` property yet.
                let ownerSelector = NSSelectorFromString(newValue ? "addConstraint:" : "removeConstraint:")
                _ = owner.perform(ownerSelector, with: self)
            } else if newValue {
                preconditionFailure("Cannot activate constraint without a common ancestor")
            }
            objc_setAssociatedObject(self, &_uicActiveConstraintKey, NSNumber(value: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    /// Backport of `NSLayoutConstraint.activate(_:)` (iOS 8).
    @available(iOS, introduced: 5.0, obsoleted: 8.0)
    @_disfavoredOverload
    class func activate(_ constraints: [NSLayoutConstraint]) { for constraint in constraints { constraint.isActive = true } }

    /// Backport of `NSLayoutConstraint.deactivate(_:)` (iOS 8).
    @available(iOS, introduced: 5.0, obsoleted: 8.0)
    @_disfavoredOverload
    class func deactivate(_ constraints: [NSLayoutConstraint]) { for constraint in constraints { constraint.isActive = false } }
}
