import UIKit
import Foundation
import ObjectiveC

// Detached, loaded controller: no application, window, appearance, or run-loop work.
@MainActor private final class ControllerUpdateProbe: UIView {
    static var events: [String] = []
    var probeName = ""
    override class var requiresConstraintBasedLayout: Bool { true }
    override func updateConstraints() {
        Self.events.append(probeName)
        super.updateConstraints()
    }
}

@MainActor private final class ConstraintUpdateController: UIViewController {
    override func loadView() {
        let root = ControllerUpdateProbe()
        root.probeName = "R"
        root.translatesAutoresizingMaskIntoConstraints = false
        let child = ControllerUpdateProbe()
        child.probeName = "C"
        child.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(child)
        view = root
    }
    override func updateViewConstraints() {
        ControllerUpdateProbe.events.append("VC enter")
        super.updateViewConstraints()
        ControllerUpdateProbe.events.append("VC exit")
    }
}

@MainActor private func controllerUpdateTrace() -> [[String]] {
    let controller = ConstraintUpdateController()
    let root = controller.view!
    let child = root.subviews[0]
    precondition(controller.isViewLoaded && controller.viewIfLoaded === root)
    precondition(root.window == nil && root.superview == nil && controller.parent == nil)
    return withExtendedLifetime(controller) {
        var trace: [[String]] = []
        @MainActor func capture() {
            ControllerUpdateProbe.events = []
            root.updateConstraintsIfNeeded()
            trace.append(ControllerUpdateProbe.events)
        }
        root.setNeedsUpdateConstraints()
        child.setNeedsUpdateConstraints()
        capture() // initial
        capture() // clean
        child.setNeedsUpdateConstraints()
        capture() // child-only dirty
        root.setNeedsUpdateConstraints()
        capture() // root-only dirty
        return trace
    }
}

@MainActor private final class MisleadingResponderView: UIView {
    weak var advertisedController: UIViewController?
    override var next: UIResponder? { advertisedController }
}

@MainActor private final class LoadCountingController: UIViewController {
    var loadCount = 0
    override func loadView() { loadCount += 1; view = UIView() }
}

@MainActor private func checkControllerOwnership() -> Bool {
    var ok = true
    func check(_ name: String, _ value: Bool) {
        print("controller-owner \(value ? "PASS" : "FAIL") \(name)")
        ok = ok && value
    }
    let unloaded = LoadCountingController(), decoy = MisleadingResponderView()
    decoy.advertisedController = unloaded
    check("unloaded lookup does not load", LegacyControllerConstraintUpdates.owner(of: decoy) == nil && unloaded.loadCount == 0)
    _ = unloaded.view
    check("responder controller with different root excluded", LegacyControllerConstraintUpdates.owner(of: decoy) == nil)
    let controller = ConstraintUpdateController(), root = controller.view!
    check("exact loaded root owned", LegacyControllerConstraintUpdates.owner(of: root) === controller)
    check("ordinary descendant excluded", LegacyControllerConstraintUpdates.owner(of: root.subviews[0]) == nil)
    let replacement = ControllerUpdateProbe(); replacement.probeName = "replacement"
    controller.view = replacement
    check("old root no longer owned", LegacyControllerConstraintUpdates.owner(of: root) == nil)
    check("new root owned", LegacyControllerConstraintUpdates.owner(of: replacement) === controller)
    return ok
}

@MainActor private func runControllerUpdateDifferential() -> Bool {
    let phases = ["initial", "clean", "child-only dirty", "root-only dirty"]
    // Capture and print the actual native oracle before force-installing hooks.
    let native = controllerUpdateTrace()
    for (phase, events) in zip(phases, native) {
        print("controller-update native \(phase): \(events)")
    }
    fflush(stdout)
    let selector = NSSelectorFromString("updateViewConstraints")
    let nativeImplementation = method_getImplementation(class_getInstanceMethod(UIViewController.self, selector)!)
    LegacyAutoLayout.installForLegacyNames()
    let preserved = nativeImplementation == method_getImplementation(class_getInstanceMethod(UIViewController.self, selector)!)
    print("controller native base IMP preserved: \(preserved)")
    let ownershipOK = checkControllerOwnership()
    let legacy = controllerUpdateTrace()
    for (index, phase) in phases.enumerated() {
        print("controller-update forced \(phase): \(legacy[index])")
        print("controller-update \(legacy[index] == native[index] ? "PASS" : "FAIL") \(phase)")
    }
    let equal = legacy == native && preserved && ownershipOK
    print("controller-update differential: \(equal ? "PASS" : "FAIL")")
    fflush(stdout)
    return equal
}

MainActor.assumeIsolated {
    setbuf(stdout, nil)
    exit(runControllerUpdateDifferential() ? 0 : 1)
}
