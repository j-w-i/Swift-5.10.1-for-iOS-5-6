import UIKit
import ObjectiveC

/// Supplies only the iOS 6 controller callback missing from iOS 5. Modern
/// UIViewController implementations remain authoritative, including forced tests.
internal enum LegacyControllerConstraintUpdates {
    static let selector = NSSelectorFromString("updateViewConstraints")

    static func installIfAbsent() {
        guard class_getInstanceMethod(UIViewController.self, selector) == nil,
              let method = class_getInstanceMethod(LegacyControllerConstraintHooks.self,
                  #selector(LegacyControllerConstraintHooks.legacyUpdateViewConstraints)) else { return }
        class_addMethod(UIViewController.self, selector, method_getImplementation(method),
                        method_getTypeEncoding(method))
    }

    /// Only the loaded controller's own root gets controller callbacks. Merely
    /// having a controller farther up the responder chain does not establish
    /// ownership, and must not promote per-message/descendant update scopes.
    @MainActor
    static func owner(of view: UIView) -> UIViewController? {
        guard let controller = view.next as? UIViewController,
              controller.isViewLoaded, controller.view === view else { return nil }
        return controller
    }
}

@MainActor
private final class LegacyControllerConstraintHooks: NSObject {
    @objc dynamic func legacyUpdateViewConstraints() {
        // The IMP is installed on UIViewController, not this template class.
        let controller = Unmanaged<UIViewController>.fromOpaque(
            Unmanaged.passUnretained(self).toOpaque()).takeUnretainedValue()
        _ = controller.view.perform(NSSelectorFromString("updateConstraints"))
    }
}
