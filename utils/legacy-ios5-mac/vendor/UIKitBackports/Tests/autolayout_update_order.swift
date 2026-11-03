import UIKit
import Foundation

@MainActor final class UpdateProbe: UIView {
    static var events: [String] = []
    var name = ""
    override class var requiresConstraintBasedLayout: Bool { true }
    override func updateConstraints() {
        Self.events.append(name)
        super.updateConstraints()
    }
}
@MainActor func observeUpdates() -> [[String]] {
    let p = UpdateProbe(), c = UpdateProbe()
    p.name = "P"; c.name = "C"
    p.translatesAutoresizingMaskIntoConstraints = false
    c.translatesAutoresizingMaskIntoConstraints = false
    p.addSubview(c)
    p.setNeedsUpdateConstraints(); c.setNeedsUpdateConstraints()
    UpdateProbe.events = []; p.updateConstraintsIfNeeded(); let first = UpdateProbe.events
    UpdateProbe.events = []; p.updateConstraintsIfNeeded(); let clean = UpdateProbe.events
    UpdateProbe.events = []; c.setNeedsUpdateConstraints(); p.updateConstraintsIfNeeded(); let dirty = UpdateProbe.events
    UpdateProbe.events = []; p.updateConstraints(); let direct = UpdateProbe.events
    return [first, clean, dirty, direct]
}
MainActor.assumeIsolated {
    let native = observeUpdates()
    LegacyAutoLayout.installForLegacyNames()
    let legacy = observeUpdates()
    print("update-order native: \(native)")
    print("update-order legacy: \(legacy)")
    precondition(native == [["C", "P"], [], ["C"], ["P"]], "native oracle changed")
    precondition(legacy == native, "constraint update callback parity")
    print("update-order: PASS")
}
