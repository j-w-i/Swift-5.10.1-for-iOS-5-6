import UIKit
import Foundation

@MainActor final class DirectUpdateProbe: UIView {
    static var events: [String] = []
    var name = ""
    override class var requiresConstraintBasedLayout: Bool { true }
    override func updateConstraints() {
        Self.events.append(name)
        super.updateConstraints()
    }
}

@MainActor func directUpdateTrace() -> [[String]] {
    let parent = DirectUpdateProbe(), child = DirectUpdateProbe()
    parent.name = "P"; child.name = "C"
    parent.translatesAutoresizingMaskIntoConstraints = false
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
    parent.setNeedsUpdateConstraints(); child.setNeedsUpdateConstraints()
    DirectUpdateProbe.events = []
    parent.updateConstraintsIfNeeded()
    let initial = DirectUpdateProbe.events
    parent.setNeedsUpdateConstraints()
    DirectUpdateProbe.events = []
    parent.updateConstraints()
    let direct = DirectUpdateProbe.events
    DirectUpdateProbe.events = []
    parent.updateConstraintsIfNeeded()
    let afterDirect = DirectUpdateProbe.events
    DirectUpdateProbe.events = []
    parent.updateConstraintsIfNeeded()
    let clean = DirectUpdateProbe.events
    child.setNeedsUpdateConstraints()
    DirectUpdateProbe.events = []
    parent.updateConstraintsIfNeeded()
    let childOnly = DirectUpdateProbe.events
    // A direct parent update must not consume pending descendant work.
    child.setNeedsUpdateConstraints()
    DirectUpdateProbe.events = []
    parent.updateConstraints()
    let parentWithDirtyChild = DirectUpdateProbe.events
    DirectUpdateProbe.events = []
    parent.updateConstraintsIfNeeded()
    return [initial, direct, afterDirect, clean, childOnly,
            parentWithDirtyChild, DirectUpdateProbe.events]
}

MainActor.assumeIsolated {
    let native = directUpdateTrace()
    LegacyAutoLayout.installForLegacyNames()
    let legacy = directUpdateTrace()
    print("direct-update native: \(native)")
    print("direct-update legacy: \(legacy)")
    fflush(stdout)
    precondition(native == [["C", "P"], ["P"], [], [], ["C"], ["P"], ["C"]], "native oracle changed")
    precondition(legacy == native, "direct update must consume pending callback")
    print("direct-update: PASS")
}
