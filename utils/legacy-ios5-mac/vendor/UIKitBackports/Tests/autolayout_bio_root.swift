import UIKit
import Foundation

// Compile in the same staged module as LegacyAutoLayout; ObjC fixture is exported
// by a test-only wrapper around device-bridge/BioLayoutProbe.h (one graph oracle).
@_silgen_name("N2ExportBioRootProbe") private func exportBioRootProbe() -> UnsafeMutablePointer<CChar>

@_silgen_name("N2InstallBioProbeFactory") private func installBioProbeFactory()
@_cdecl("N2MakeBioProbeConstraint")
public func makeBioConstraint(_ first: UnsafeMutableRawPointer?, _ a: Int, _ relation: Int, _ second: UnsafeMutableRawPointer?, _ b: Int, _ multiplier: Double, _ constant: Double) -> UnsafeMutableRawPointer? {
    MainActor.assumeIsolated {
        let one = first.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
        let two = second.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }
        let model = RRLayoutConstraint(item: one, attribute: RRLayoutAttribute(rawValue: a)!, relatedBy: RRLayoutRelation(rawValue: relation)!, toItem: two, attribute: RRLayoutAttribute(rawValue: b)!, multiplier: multiplier, constant: constant)
        return Unmanaged.passRetained(model).toOpaque()
    }
}

@MainActor private func bioProbe() -> [String: Any] {
    let pointer = exportBioRootProbe()
    defer { free(pointer) }
    let data = String(cString: pointer).data(using: .utf8)!
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}
@MainActor private func validateBio(_ result: [String: Any], name: String) -> Bool {
    var ok = true
    let cases = result["cases"] as! [[String: Any]]
    precondition(cases.count == 2)
    for entry in cases {
        let delayed = entry["delayed"] as! Bool
        for phase in ["afterLocal", "afterRoot", "repeat"] {
            let snapshot = entry[phase] as! [String: Any]
            let frame = NSCoder.cgRect(for: snapshot["bioFrame"] as! String)
            let intrinsic = NSCoder.cgSize(for: snapshot["intrinsic"] as! String)
            if abs(frame.height - intrinsic.height) >= 0.6 {
                print("bio-root: FAIL \(name) delayed=\(delayed) \(phase): frame=\(frame) intrinsic=\(intrinsic)")
                ok = false
            }
        }
        let afterRoot = entry["afterRoot"] as! [String: Any]
        let repeated = entry["repeat"] as! [String: Any]
        precondition(afterRoot["bioFrame"] as! String == repeated["bioFrame"] as! String, "noop changed bio")
    }
    return ok
}
@MainActor private final class ExplicitIntrinsicProbe: UIView {
    var naturalHeight: CGFloat = 20
    override var intrinsicContentSize: CGSize { CGSize(width: 100, height: naturalHeight) }
}
@MainActor private func explicitInvalidationRegression() {
    let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 436))
    let child = ExplicitIntrinsicProbe()
    child.legacyTranslatesAutoresizingMaskIntoConstraints = false
    root.addSubview(child)
    for attribute in [RRLayoutAttribute.left, .top] {
        root.legacyAddConstraint(RRLayoutConstraint(item: child, attribute: attribute, relatedBy: .equal, toItem: root, attribute: attribute, multiplier: 1, constant: 10))
    }
    root.legacyLayoutIfNeeded()
    precondition(abs(child.frame.height - 20) < 0.1)
    let before = LegacyLayoutMutation.generation
    child.naturalHeight = 100
    child.invalidateIntrinsicContentSize()
    let after = LegacyLayoutMutation.generation
    precondition(after > before, "explicit invalidation did not advance mutation generation")
    child.layoutSubviews()
    precondition(abs(child.frame.height - 100) < 0.1, "custom override stale after explicit invalidation")
    print("explicit-invalidation: PASS height20->100 generation \(before)->\(after)")
}
MainActor.assumeIsolated {
    setbuf(stdout, nil)
    let nativeUpdates = observeUpdates()
    let native = bioProbe()
    print("BIO_NATIVE \(native)")
    let nativeOK = validateBio(native, name: "native")
    LegacyAutoLayout.installForLegacyNames()
    installBioProbeFactory()
    let legacy = bioProbe()
    print("BIO_BACKPORT \(legacy)")
    let legacyOK = validateBio(legacy, name: "backport")
    let legacyUpdates = observeUpdates()
    precondition(nativeUpdates == [["C", "P"], [], ["C"], ["P"]])
    precondition(nativeUpdates == legacyUpdates, "callback regression")
    let output: [String: Any] = ["native": native, "backport": legacy, "nativeUpdates": nativeUpdates, "legacyUpdates": legacyUpdates]
    let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    precondition(runLayoutTest(), "existing layout regression")
    print("callbacks: PASS")
    explicitInvalidationRegression()
    precondition(nativeOK && legacyOK, "bio-root regression; see phase failures above")
    print("bio-root: PASS (local delayed intrinsic, cold, noop, callbacks, existing layout)")
}
