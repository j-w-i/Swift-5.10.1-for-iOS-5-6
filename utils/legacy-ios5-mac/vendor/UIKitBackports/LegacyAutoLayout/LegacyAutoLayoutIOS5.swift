// Swift shims for the iOS 5 spellings of UIView's constraint API.
//
// The legacy importer hides UIKit's UIView constraint declarations from iOS 5
// compilations, so these shims are the only candidates there. They are obsoleted
// at iOS 9 where UIKit's own members take over.
//
// The public surface is ordinary UIKit: every constraint member is phrased in
// `NSLayoutConstraint`, and the engine's own constraint model
// (`RRLayoutConstraint`) stays a module-internal implementation detail. On iOS 5
// the runtime registers a class named `NSLayoutConstraint` (see
// NativeAPIBridge.swift) and installs UIKit-shaped methods on it, so the objects
// app code creates, adds and reads are real `NSLayoutConstraint` instances whose
// storage is the engine model. Swift resolves that class by name at first use
// (`objc_lookUpClass`), never through a static ObjC class symbol, which iOS 5
// dyld would have bound to nil before the runtime registered the class.
//
// IMPORTANT: name binding happens at compile time, but the binary can run on a
// newer OS. Every entry point therefore dispatches at *runtime*:
//
//   - iOS 5: the UIView method installed by the legacy bridge (installed on first
//     use, which also registers the NSLayoutConstraint class the OS lacks).
//   - iOS 6+: exactly UIKit's implementation, reached by selector because the
//     declarations are not visible to an iOS 5 compilation.
//
// Without that second branch an iOS 5-built binary running on iOS 6 would write
// only to legacy storage, so UIKit would keep translating autoresizing masks
// and the constraints would never become active.
//
// The shims are deliberately not `@MainActor`: they are ordinary synchronous
// UIKit calls and staying nonisolated lets a client compiled for a newer target
// use them from the same nonisolated contexts UIKit's own imported members allow.
#if canImport(UIKit)
import UIKit
import ObjectiveC

/// Implementation of an existing UIView method, or nil when this OS lacks it.
private func legacyShimImplementation(_ object: AnyObject, _ selector: String) -> IMP? {
    let name = NSSelectorFromString(selector)
    guard let method = class_getInstanceMethod(type(of: object), name) else { return nil }
    return method_getImplementation(method)
}

public extension UIView {

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var translatesAutoresizingMaskIntoConstraints: Bool {
        get {
            // Installs the legacy accessor below iOS 6; UIKit's own above.
            LegacyAutoLayout.ensureInstalled()
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            let selector = "translatesAutoresizingMaskIntoConstraints"
            // UIKit's documented default when nothing has been stored yet.
            guard let implementation = legacyShimImplementation(self, selector) else { return true }
            return unsafeBitCast(implementation, to: Getter.self)(self, NSSelectorFromString(selector))
        }
        set {
            LegacyAutoLayout.ensureInstalled()
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            let selector = "setTranslatesAutoresizingMaskIntoConstraints:"
            guard let implementation = legacyShimImplementation(self, selector) else { return }
            unsafeBitCast(implementation, to: Setter.self)(self, NSSelectorFromString(selector), newValue)
        }
    }

    /// The constraints installed on this view, with UIKit's spelling.
    ///
    /// On iOS 6+ this is UIKit's own `-[UIView constraints]`. On iOS 5 the bridge
    /// installs that selector and answers with the `NSLayoutConstraint` objects
    /// added to the view (the same objects the public add/remove API used), not
    /// with the engine's internal model.
    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    var constraints: [NSLayoutConstraint] {
        // Installs -[UIView constraints] and the NSLayoutConstraint class below
        // iOS 6; a strict no-op on iOS 6+ where UIKit owns both.
        LegacyAutoLayout.ensureInstalled()
        guard let value = perform(NSSelectorFromString("constraints"))?.takeUnretainedValue() else {
            return []
        }
        return (value as? [NSLayoutConstraint]) ?? []
    }

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    func addConstraint(_ constraint: NSLayoutConstraint) {
        // Installs -[UIView addConstraint:] below iOS 6; a no-op on iOS 6+.
        LegacyAutoLayout.ensureInstalled()
        _ = perform(NSSelectorFromString("addConstraint:"), with: constraint)
    }

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    func addConstraints(_ constraints: [NSLayoutConstraint]) {
        LegacyAutoLayout.ensureInstalled()
        for constraint in constraints {
            _ = perform(NSSelectorFromString("addConstraint:"), with: constraint)
        }
    }

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    func removeConstraint(_ constraint: NSLayoutConstraint) {
        // Installs -[UIView removeConstraint:] below iOS 6; a no-op on iOS 6+.
        LegacyAutoLayout.ensureInstalled()
        _ = perform(NSSelectorFromString("removeConstraint:"), with: constraint)
    }

    @available(iOS, introduced: 5.0, obsoleted: 9.0)
    @_disfavoredOverload
    func removeConstraints(_ constraints: [NSLayoutConstraint]) {
        LegacyAutoLayout.ensureInstalled()
        for constraint in constraints {
            _ = perform(NSSelectorFromString("removeConstraint:"), with: constraint)
        }
    }
}
#endif
