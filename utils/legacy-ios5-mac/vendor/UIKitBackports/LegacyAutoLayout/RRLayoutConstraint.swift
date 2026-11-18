//
//  RRLayoutConstraint.swift
//  LegacyAutoLayout
//
//  Swift port of `RRLayoutConstraint` from RRAutoLayout, aligned with
//  `NSLayoutConstraint`'s public API so that code and nib archives written for
//  the system class keep working.
//
//  RRAutoLayout
//  Copyright (c) 2012 Rolandas Razma <rolandas@razma.lt>
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//
//  Ownership / memory semantics
//  ----------------------------
//  Upstream RRAutoLayout stored the two items in `__unsafe_unretained` ivars
//  because Apple's Auto Layout never lets a constraint keep its views alive (and
//  a strong reference would create retain cycles through the constraint arrays
//  the views own). This port keeps that behaviour with Swift `weak` storage: a
//  constraint does not retain its items; if an item is deallocated,
//  `firstItem`/`secondItem` read as `nil` and the engine treats the constraint as
//  unsupported (it is skipped, never crashes).
//
//  Constraint validation
//  ---------------------
//  UIKit validates a constraint when it is created and raises
//  `NSInvalidArgumentException` for illegal attribute pairings. That behaviour is
//  part of what apps observe, so it is reproduced here (docs/legacy-autolayout.md
//  §4; /tmp/autolayout-semantics.md §2.1-§2.3):
//
//    * a location attribute cannot be paired with a size attribute;
//    * size attributes pair with size attributes in any combination, including
//      width <-> height (aspect-ratio constraints such as width == 2 * height);
//    * vertical attributes cannot be paired with horizontal attributes;
//    * `leading`/`trailing` cannot be paired with `left`/`right`;
//    * a constant constraint (`secondItem == nil`, `notAnAttribute`) is only
//      legal for `width`/`height`, and its multiplier is ignored;
//    * `firstAttribute == .notAnAttribute` is never legal.
//
//  The validation is exposed as the non-throwing
//  `RRLayoutConstraint.validationError(...)` (used by the NIB decoder and by
//  tests); the public initializer raises like UIKit does. Note that the
//  documented "no nonidentity multiplier with location attributes" rule is *not*
//  enforced: the same Apple guide demonstrates the `centerX == 0.5 *
//  trailing` idiom, and the engine expands attributes algebraically so the
//  equation is well-defined either way.
//
//  `isActive`
//  ----------
//  `NSLayoutConstraint.isActive` (iOS 8) is a backport here. The engine discovers
//  constraints in two ways: (1) `layoutConstraints` of every item in the solved
//  subtree, and (2) the module-internal registry of activated constraints. The
//  registry lets `RRLayoutConstraint.activate([...])` work for any
//  `LegacyLayoutItem` without requiring the item protocol to expose a mutable
//  constraint storage API. Constraints are held weakly by the registry, so an
//  activated constraint that nothing else retains does not leak (or outlive the
//  caller).
//

import Foundation
import CoreGraphics

// MARK: - Validation errors

/// Why a constraint is illegal.
///
/// Mirrors the situations in which UIKit raises `NSInvalidArgumentException` from
/// `+[NSLayoutConstraint constraintWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:]`.
/// The `failureReason` strings follow Apple's wording closely enough to be useful
/// in logs; the exact private text is not API.
enum LegacyLayoutConstraintError: Error, Equatable, CustomStringConvertible {

    /// `firstAttribute == .notAnAttribute`; a constraint must refer to a real
    /// attribute of the first item.
    case firstAttributeNotAnAttribute

    /// A location attribute was used with no second item ("location equal to a
    /// constant" is illegal; location attributes must be specified in pairs).
    case locationEqualToConstant(attribute: RRLayoutAttribute)

    /// The two attributes form an illegal pairing (position x size,
    /// horizontal x vertical, leading/trailing x left/right, ...).
    case invalidPairing(first: RRLayoutAttribute, second: RRLayoutAttribute)

    /// A second item was supplied together with `.notAnAttribute`, or an attribute
    /// was supplied without a second item.
    case invalidSecondAttribute(first: RRLayoutAttribute, second: RRLayoutAttribute)

    /// The reason string, in Apple's style.
    var failureReason: String {
        switch self {
        case .firstAttributeNotAnAttribute:
            return "NSLayoutConstraint: Invalid pairing of layout attributes. A constraint cannot use notAnAttribute as its first attribute."
        case .locationEqualToConstant:
            return "A multiplier of 0 or a nil second item together with a location for the first attribute creates an illegal constraint of a location equal to a constant. Location attributes must be specified in pairs."
        case .invalidPairing(let first, let second):
            return "NSLayoutConstraint: Invalid pairing of layout attributes (\(first) and \(second))."
        case .invalidSecondAttribute(let first, let second):
            return "NSLayoutConstraint: Invalid pairing of layout attributes (\(first) and \(second)); the second item and second attribute must both be present or both absent."
        }
    }

    var description: String {
        return "LegacyLayoutConstraintError: \(failureReason)"
    }
}

// MARK: - Constraint

/// A single Auto Layout constraint.
///
/// The constraint equation is the same as `NSLayoutConstraint`'s:
///
///     firstItem.firstAttribute  <relation>  multiplier * secondItem.secondAttribute + constant
///
/// Attribute and relation raw values are identical to UIKit's, which is required
/// for decoding archived (NIB) constraints.
final class RRLayoutConstraint: NSObject {

    // MARK: Items (weak, like Apple's unowned references)

    private weak var _firstItem: AnyObject?
    private weak var _secondItem: AnyObject?

    // MARK: Immutable configuration

    private let _firstAttribute: RRLayoutAttribute
    private let _relation: RRLayoutRelation
    private let _secondAttribute: RRLayoutAttribute
    private let _multiplier: CGFloat

    // MARK: Mutable configuration

    /// The priority of the constraint. Defaults to `.required`.
    ///
    /// Values `>= 1000` behave as required. A priority of `0` means "do not
    /// enforce" and is mapped to the weakest strength (see `RRLayoutPriority.swift`);
    /// modern UIKit rejects priorities `<= 0` at creation, but this backport stays
    /// tolerant so corrupt archives cannot crash the layout pass.
    var priority: RRLayoutPriority = RRLayoutPriorityValue.required {
        didSet { LegacyLayoutMutation.bumpConstraints() }
    }

    /// The constant term of the constraint equation. Settable, like Apple's.
    var constant: CGFloat {
        didSet { LegacyLayoutMutation.bumpConstraints() }
    }

    /// An optional identifier for debugging. Settable, like Apple's.
    var identifier: String?

    private var _isActive: Bool = false

    // MARK: Init

    /// Creates an unchecked constraint. The public initializers validate first;
    /// this one is the designated initializer and skips validation so the
    /// convenience initializer can validate before constructing.
    internal init(uncheckedItem firstItem: Any?,
                  attribute firstAttribute: RRLayoutAttribute,
                  relatedBy relation: RRLayoutRelation,
                  toItem secondItem: Any?,
                  attribute secondAttribute: RRLayoutAttribute,
                  multiplier: CGFloat,
                  constant: CGFloat) {
        retainNativeAPIBootstrap()
        self._firstItem = firstItem as AnyObject?
        self._firstAttribute = firstAttribute
        self._relation = relation
        self._secondItem = secondItem as AnyObject?
        self._secondAttribute = secondAttribute
        self._multiplier = multiplier
        self.constant = constant
        super.init()
    }

    /// Creates a constraint, validating it the way UIKit does.
    ///
    /// - Note: Raises `NSInvalidArgumentException` (like `NSLayoutConstraint`)
    ///   when the attributes form an illegal pairing. Use
    ///   `RRLayoutConstraint.validationError(...)` first if a non-throwing check
    ///   is needed (e.g. when decoding an archive from an old nib).
    convenience init(item firstItem: Any?,
                            attribute firstAttribute: RRLayoutAttribute,
                            relatedBy relation: RRLayoutRelation,
                            toItem secondItem: Any?,
                            attribute secondAttribute: RRLayoutAttribute,
                            multiplier: CGFloat,
                            constant: CGFloat) {
        if let error = RRLayoutConstraint.validationError(item: firstItem,
                                                          attribute: firstAttribute,
                                                          toItem: secondItem,
                                                          attribute: secondAttribute) {
            NSException(name: NSExceptionName.invalidArgumentException,
                        reason: error.failureReason,
                        userInfo: nil).raise()
        }
        self.init(uncheckedItem: firstItem,
                  attribute: firstAttribute,
                  relatedBy: relation,
                  toItem: secondItem,
                  attribute: secondAttribute,
                  multiplier: multiplier,
                  constant: constant)
    }

    /// Backport of `+[NSLayoutConstraint constraintWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:]`,
    /// as declared by RRAutoLayout.
    class func constraint(item: Any?,
                                 attribute: RRLayoutAttribute,
                                 relatedBy: RRLayoutRelation,
                                 toItem: Any?,
                                 attribute secondAttribute: RRLayoutAttribute,
                                 multiplier: CGFloat,
                                 constant: CGFloat) -> RRLayoutConstraint {
        return RRLayoutConstraint(item: item,
                                  attribute: attribute,
                                  relatedBy: relatedBy,
                                  toItem: toItem,
                                  attribute: secondAttribute,
                                  multiplier: multiplier,
                                  constant: constant)
    }

    // MARK: Validation

    /// Returns `nil` when the attribute/attribute combination is legal, or the
    /// reason it is not. Never throws and never mutates anything, so it can be
    /// used by decoders and tests.
    ///
    /// Rules (from Apple's *Auto Layout Guide*, "Constraints Express Relationships
    /// Between Views" / "Anatomy of a Constraint"; reproduced on the iOS 27
    /// simulator in /tmp/autolayout-semantics.md §2):
    ///
    /// * constant constraint (`secondItem == nil`): only `width`/`height` are
    ///   legal; the multiplier is ignored;
    /// * location x location is legal only on the same axis and within the same
    ///   family: `left`/`right` pair with each other and with `centerX`,
    ///   `leading`/`trailing` pair with each other and with `centerX`, but
    ///   `leading`/`trailing` cannot pair with `left`/`right`;
    /// * vertical location attributes (`top`, `bottom`, `centerY`, `baseline`)
    ///   pair among themselves; `firstBaseline` only pairs with `firstBaseline`;
    /// * size attributes pair with size attributes in any combination
    ///   (`width`/`height`, so aspect-ratio constraints are legal);
    /// * horizontal and vertical attributes cannot be paired.
    class func validationError(item firstItem: Any?,
                                      attribute firstAttribute: RRLayoutAttribute,
                                      toItem secondItem: Any?,
                                      attribute secondAttribute: RRLayoutAttribute) -> LegacyLayoutConstraintError? {
        guard firstAttribute != .notAnAttribute else {
            return .firstAttributeNotAnAttribute
        }
        // Constant constraint form.
        if secondItem == nil && secondAttribute == .notAnAttribute {
            guard firstAttribute.isSizeAttribute else {
                return .locationEqualToConstant(attribute: firstAttribute)
            }
            return nil
        }
        // Exactly one of (secondItem, secondAttribute) present: not a valid pair.
        if secondItem == nil || secondAttribute == .notAnAttribute {
            return .invalidSecondAttribute(first: firstAttribute, second: secondAttribute)
        }
        guard RRLayoutConstraint.isLegalPairing(first: firstAttribute, second: secondAttribute) else {
            return .invalidPairing(first: firstAttribute, second: secondAttribute)
        }
        return nil
    }

    /// Whether two real attributes may be constrained to each other.
    class func isLegalPairing(first: RRLayoutAttribute, second: RRLayoutAttribute) -> Bool {
        guard first != .notAnAttribute, second != .notAnAttribute else {
            return false
        }
        // Sizes pair with sizes in any combination (width <-> height included:
        // that is the aspect-ratio constraint).
        if first.isSizeAttribute && second.isSizeAttribute {
            return true
        }
        if first.isSizeAttribute != second.isSizeAttribute {
            return false
        }
        // Both are location attributes: they must share an axis.
        guard let firstAxis = first.axis, let secondAxis = second.axis, firstAxis == secondAxis else {
            return false
        }
        if firstAxis == .horizontal {
            return RRLayoutConstraint.isLegalHorizontalPairing(first: first, second: second)
        }
        return RRLayoutConstraint.isLegalVerticalPairing(first: first, second: second)
    }

    private class func isLegalHorizontalPairing(first: RRLayoutAttribute,
                                                second: RRLayoutAttribute) -> Bool {
        // centerX pairs with every horizontal location attribute.
        if first == .centerX || second == .centerX {
            return true
        }
        let absolute: Set<RRLayoutAttribute> = [.left, .right]
        let directional: Set<RRLayoutAttribute> = [.leading, .trailing]
        if absolute.contains(first) && absolute.contains(second) {
            return true
        }
        if directional.contains(first) && directional.contains(second) {
            return true
        }
        // leading/trailing may not be paired with left/right.
        return false
    }

    private class func isLegalVerticalPairing(first: RRLayoutAttribute,
                                              second: RRLayoutAttribute) -> Bool {
        // firstBaseline (iOS 8+) is only legal against firstBaseline.
        if first == .firstBaseline || second == .firstBaseline {
            return first == second
        }
        // top, bottom, centerY and baseline (lastBaseline) pair among themselves.
        return true
    }

    // MARK: Configuration

    /// The first item of the constraint. Weak; `nil` once the item is deallocated.
    var firstItem: Any? {
        return _firstItem
    }

    /// The attribute of the first item.
    var firstAttribute: RRLayoutAttribute {
        return _firstAttribute
    }

    /// The relational operator.
    var relation: RRLayoutRelation {
        return _relation
    }

    /// The second item of the constraint. Weak; `nil` once the item is deallocated.
    var secondItem: Any? {
        return _secondItem
    }

    /// The attribute of the second item.
    var secondAttribute: RRLayoutAttribute {
        return _secondAttribute
    }

    /// The multiplier applied to the second item's attribute expression.
    var multiplier: CGFloat {
        return _multiplier
    }

    // MARK: Activation

    /// The legacy engine's activation flag. Defaults to `false`.
    ///
    /// This is the engine-facing activation API (`legacyActivate`/`legacyDeactivate`): it registers
    /// the constraint with the engine's active-constraint registry. The Apple-compatible public
    /// `isActive`/`activate(_:)`/`deactivate(_:)` backport lives in
    /// `UIKitCompatKit/NSLayoutConstraint.swift` and, below iOS 6, operates on this class.
    var legacyIsActive: Bool {
        get {
            return _isActive
        }
        set {
            if newValue == _isActive {
                return
            }
            _isActive = newValue
            LegacyLayoutMutation.bumpConstraints()
            if newValue {
                // Drop-in path: activating a constraint must be enough to start the engine on iOS 5.
                LegacyAutoLayout.ensureInstalled()
                LegacyActiveConstraintRegistry.shared.register(self)
            } else {
                LegacyActiveConstraintRegistry.shared.unregister(self)
            }
        }
    }

    /// Engine-facing activation (see `legacyIsActive`).
    class func legacyActivate(_ constraints: [RRLayoutConstraint]) {
        for constraint in constraints {
            constraint.legacyIsActive = true
        }
    }

    /// Engine-facing deactivation (see `legacyIsActive`).
    class func legacyDeactivate(_ constraints: [RRLayoutConstraint]) {
        for constraint in constraints {
            constraint.legacyIsActive = false
        }
    }

    // MARK: Debugging

    override var description: String {
        let relationText: String
        switch _relation {
        case .lessThanOrEqual: relationText = "<="
        case .equal: relationText = "=="
        case .greaterThanOrEqual: relationText = ">="
        }
        let firstText = RRLayoutConstraint.describeItem(_firstItem, attribute: _firstAttribute)
        let secondText: String
        if let secondItem = _secondItem {
            secondText = RRLayoutConstraint.describeItem(secondItem, attribute: _secondAttribute)
        } else {
            secondText = "nil"
        }
        var text = "<RRLayoutConstraint \(firstText) \(relationText) \(_multiplier) * \(secondText) + \(constant)"
        if priority != RRLayoutPriorityValue.required {
            text += " @\(priority)"
        }
        if let identifier = identifier {
            text += " '\(identifier)'"
        }
        if _isActive {
            text += " active"
        }
        text += ">"
        return text
    }

    private static func describeItem(_ item: AnyObject?, attribute: RRLayoutAttribute) -> String {
        guard let item = item else {
            return "nil.\(attribute)"
        }
        return "\(type(of: item)).\(attribute)"
    }
}

// MARK: - Active constraint registry

/// Registry of constraints whose `isActive` flag is `true`.
///
/// The engine unions these with the constraints owned by the items of the subtree
/// being solved (de-duplicated by object identity). Items are not retained, so a
/// deallocated item turns the constraint into a no-op at solve time.
internal final class LegacyActiveConstraintRegistry {

    internal static let shared = LegacyActiveConstraintRegistry()

    private final class Entry {
        weak var constraint: RRLayoutConstraint?
        /// Activation order, so lookups keep the deterministic order the engine's
        /// constraint collection relies on.
        let sequence: UInt64
        /// The items at registration. A constraint's items never change (they can only become nil), so these
        /// are the only index buckets the entry can be found through.
        let itemIdentifiers: [ObjectIdentifier]
        init(constraint: RRLayoutConstraint, sequence: UInt64, itemIdentifiers: [ObjectIdentifier]) {
            self.constraint = constraint
            self.sequence = sequence
            self.itemIdentifiers = itemIdentifiers
        }
    }

    private let lock = NSLock()
    /// ObjectIdentifier -> entry. O(1) register/unregister/contains; the previous
    /// array of weak entries made activation and teardown O(n^2) (linear scan +
    /// weak loads per constraint), which dominated the device churn profile.
    private var entries: [ObjectIdentifier: Entry] = [:]
    /// Item -> active constraints naming it as first or second item. Every layout pass used to snapshot and
    /// sort the whole app's active constraints to find the few that touch the subtree being solved
    /// (O(N log N) in the app's constraint count, per pass, per cell). A pass now visits only its own items'
    /// buckets. A bucket may hold a dead or reused-address entry; callers re-check the live items.
    private var byItem: [ObjectIdentifier: [ObjectIdentifier]] = [:]
    private var nextSequence: UInt64 = 0
    private var registrationCount = 0

    private init() {}

    /// True when no constraint was ever registered or all were unregistered (dead entries may remain until
    /// pruned). The engine only needs this to skip de-duplication on the common build path.
    internal var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.isEmpty
    }

    internal func register(_ constraint: RRLayoutConstraint) {
        lock.lock()
        defer { lock.unlock() }
        let identifier = ObjectIdentifier(constraint)
        if let existing = entries[identifier] {
            if existing.constraint === constraint { return }
            removeLocked(identifier)              // a dead constraint whose address was reused
        }
        // Reclaim dead slots occasionally instead of on every registration.
        registrationCount += 1
        if registrationCount % 64 == 0 {
            pruneLocked()
        }
        var items: [ObjectIdentifier] = []
        if let first = constraint.firstItem as AnyObject? { items.append(ObjectIdentifier(first)) }
        if let second = constraint.secondItem as AnyObject?, !items.contains(ObjectIdentifier(second)) {
            items.append(ObjectIdentifier(second))
        }
        entries[identifier] = Entry(constraint: constraint, sequence: nextSequence, itemIdentifiers: items)
        for item in items { byItem[item, default: []].append(identifier) }
        nextSequence += 1
    }

    internal func unregister(_ constraint: RRLayoutConstraint) {
        lock.lock()
        defer { lock.unlock() }
        removeLocked(ObjectIdentifier(constraint))
    }

    /// Live activated constraints that name one of `items` as an item, in activation order. Same set and
    /// order as filtering a sorted snapshot of every active constraint by "references one of `items`",
    /// provided the caller applies its own live-item check (an entry is found through the identifiers its
    /// items had at registration).
    internal func activeConstraints(touching items: Set<ObjectIdentifier>) -> [RRLayoutConstraint] {
        lock.lock()
        defer { lock.unlock() }
        if entries.isEmpty { return [] }
        var found: [(UInt64, RRLayoutConstraint)] = []
        var seen = Set<ObjectIdentifier>()
        var dead: [ObjectIdentifier] = []
        // Visit whichever side is smaller: the subtree's items, or the items that have active constraints.
        if items.count <= byItem.count {
            for item in items {
                guard let bucket = byItem[item] else { continue }
                for identifier in bucket where seen.insert(identifier).inserted {
                    guard let entry = entries[identifier] else { continue }
                    if let constraint = entry.constraint { found.append((entry.sequence, constraint)) } else { dead.append(identifier) }
                }
            }
        } else {
            for (item, bucket) in byItem where items.contains(item) {
                for identifier in bucket where seen.insert(identifier).inserted {
                    guard let entry = entries[identifier] else { continue }
                    if let constraint = entry.constraint { found.append((entry.sequence, constraint)) } else { dead.append(identifier) }
                }
            }
        }
        for identifier in dead { removeLocked(identifier) }
        if found.count > 1 { found.sort { $0.0 < $1.0 } }
        return found.map { $0.1 }
    }

    /// A snapshot of all live activated constraints, in activation order (tests and diagnostics).
    internal func activeConstraints() -> [RRLayoutConstraint] {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
        return entries.values.compactMap { entry in entry.constraint.map { (entry.sequence, $0) } }
            .sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    private func removeLocked(_ identifier: ObjectIdentifier) {
        guard let entry = entries.removeValue(forKey: identifier) else { return }
        for item in entry.itemIdentifiers {
            guard var bucket = byItem[item] else { continue }
            bucket.removeAll { $0 == identifier }
            byItem[item] = bucket.isEmpty ? nil : bucket
        }
    }

    private func pruneLocked() {
        var dead: [ObjectIdentifier] = []
        for (identifier, entry) in entries where entry.constraint == nil { dead.append(identifier) }
        for identifier in dead { removeLocked(identifier) }
    }
}
