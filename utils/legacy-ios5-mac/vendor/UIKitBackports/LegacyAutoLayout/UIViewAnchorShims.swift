// Anchor spelling for the legacy UIKit overlay.
//
// UIKit's anchor API (`NSLayoutAnchor` and `UIView.*Anchor`) is iOS 9. The
// legacy runtime installs equivalent Objective-C selectors, and the compiler
// lowers the SDK's own declarations to a legacy iOS 5 deployment target. This
// file gives app code the same ordinary spelling through the Swift overlay, so
// the surface is available at every deployment target the backport supports:
//
//   * iOS 5: the constraint is built as the legacy engine model wrapped in a
//     real runtime `NSLayoutConstraint` object (the class the runtime registers).
//   * iOS 6-8: UIKit has `NSLayoutConstraint` but not anchors, so the constraint
//     is built with UIKit's own initializer.
//   * iOS 9+: obsoleted; UIKit's native anchor API takes over.
//
// The `Anchor` compatibility type is only ever returned by the anchor
// properties; applications do not spell it themselves. The constraints it
// produces are ordinary `NSLayoutConstraint` objects.
//
// Author-owned toolchain integration, adapted from the UIKitCompatKit APIShims
// snapshot. See THIRD-PARTY-NOTICES.md.
#if canImport(UIKit)
import UIKit
import CoreGraphics
import ObjectiveC

/// Builds the constraint for an anchor pair.
@available(iOS, introduced: 5.0, obsoleted: 9.0)
private func legacyAnchorConstraint(item: AnyObject?,
                                    attribute: NSLayoutConstraint.Attribute,
                                    relatedBy: NSLayoutConstraint.Relation,
                                    toItem: AnyObject?,
                                    secondAttribute: NSLayoutConstraint.Attribute,
                                    multiplier: CGFloat,
                                    constant: CGFloat) -> NSLayoutConstraint {
    if #available(iOS 6.0, *) {
        return NSLayoutConstraint(item: item! as Any, attribute: attribute, relatedBy: relatedBy,
                                  toItem: toItem, attribute: secondAttribute,
                                  multiplier: multiplier, constant: constant)
    }
    // iOS 5: no NSLayoutConstraint class exists yet. Register it, build the
    // engine model, and hand back the runtime object that carries the model.
    LegacyAutoLayout.ensureInstalled()
    let model = legacyConstraint(item: item,
                                 attribute: RRLayoutAttribute(rawValue: attribute.rawValue)!,
                                 relatedBy: RRLayoutRelation(rawValue: relatedBy.rawValue)!,
                                 toItem: toItem,
                                 attribute: RRLayoutAttribute(rawValue: secondAttribute.rawValue)!,
                                 multiplier: multiplier, constant: constant)!
    if let bridged = legacyAttach(model: model) { return bridged }
    preconditionFailure("The iOS 5 Auto Layout bridge could not create NSLayoutConstraint.")
}

/// Expressive anchor backport type, providing the fluid iOS 9+ constraint API on
/// the systems whose UIKit lacks anchors. It is returned by the anchor
/// properties below; it is not a UIKit class.
@available(iOS, introduced: 5.0, obsoleted: 9.0)
public class Anchor {
    weak var item: AnyObject?
    let attribute: NSLayoutConstraint.Attribute

    internal init(item: AnyObject?, attribute: NSLayoutConstraint.Attribute) {
        self.item = item
        self.attribute = attribute
    }
}

@available(iOS, introduced: 5.0, obsoleted: 9.0)
public extension Anchor {
    func constraint(equalTo other: Anchor,
                    multiplier: CGFloat = 1.0,
                    constant: CGFloat = 0) -> NSLayoutConstraint {
        legacyAnchorConstraint(item: item, attribute: attribute, relatedBy: .equal,
                               toItem: other.item, secondAttribute: other.attribute,
                               multiplier: multiplier, constant: constant)
    }

    func constraint(lessThanOrEqualTo other: Anchor,
                    multiplier: CGFloat = 1.0,
                    constant: CGFloat = 0) -> NSLayoutConstraint {
        legacyAnchorConstraint(item: item, attribute: attribute, relatedBy: .lessThanOrEqual,
                               toItem: other.item, secondAttribute: other.attribute,
                               multiplier: multiplier, constant: constant)
    }

    func constraint(greaterThanOrEqualTo other: Anchor,
                    multiplier: CGFloat = 1.0,
                    constant: CGFloat = 0) -> NSLayoutConstraint {
        legacyAnchorConstraint(item: item, attribute: attribute, relatedBy: .greaterThanOrEqual,
                               toItem: other.item, secondAttribute: other.attribute,
                               multiplier: multiplier, constant: constant)
    }

    func constraint(equalToConstant constant: CGFloat) -> NSLayoutConstraint {
        legacyAnchorConstraint(item: item, attribute: attribute, relatedBy: .equal,
                               toItem: nil, secondAttribute: .notAnAttribute,
                               multiplier: 1, constant: constant)
    }

    func constraint(greaterThanOrEqualToConstant constant: CGFloat) -> NSLayoutConstraint {
        legacyAnchorConstraint(item: item, attribute: attribute, relatedBy: .greaterThanOrEqual,
                               toItem: nil, secondAttribute: .notAnAttribute,
                               multiplier: 1, constant: constant)
    }

    func constraint(lessThanOrEqualToConstant constant: CGFloat) -> NSLayoutConstraint {
        legacyAnchorConstraint(item: item, attribute: attribute, relatedBy: .lessThanOrEqual,
                               toItem: nil, secondAttribute: .notAnAttribute,
                               multiplier: 1, constant: constant)
    }
}

// MARK: - UIView anchor accessors

@available(iOS, introduced: 5.0, obsoleted: 9.0)
public extension UIView {
    var leadingAnchor: Anchor { Anchor(item: self, attribute: .leading) }
    var trailingAnchor: Anchor { Anchor(item: self, attribute: .trailing) }
    var topAnchor: Anchor { Anchor(item: self, attribute: .top) }
    var bottomAnchor: Anchor { Anchor(item: self, attribute: .bottom) }
    var widthAnchor: Anchor { Anchor(item: self, attribute: .width) }
    var heightAnchor: Anchor { Anchor(item: self, attribute: .height) }
    var centerXAnchor: Anchor { Anchor(item: self, attribute: .centerX) }
    var centerYAnchor: Anchor { Anchor(item: self, attribute: .centerY) }
    var leftAnchor: Anchor { Anchor(item: self, attribute: .left) }
    var rightAnchor: Anchor { Anchor(item: self, attribute: .right) }
}

#endif
