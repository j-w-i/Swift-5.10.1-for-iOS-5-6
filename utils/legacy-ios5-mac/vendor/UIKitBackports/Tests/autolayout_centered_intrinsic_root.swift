import UIKit

// Model the direct stack's public contract: intrinsic content with center
// anchors, no width/height equality, and children owned by direct layout.
@MainActor private final class CenteredIntrinsicProbe: UIView {
    var contentSize = CGSize(width: 166, height: 93)
    override var intrinsicContentSize: CGSize { contentSize }
    @objc(uic_usesDirectStackLayout) dynamic func usesDirectStackLayout() -> Bool { true }
}

@MainActor func centeredIntrinsicFrames(legacy: Bool) -> [CGRect] {
    let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let window = UIWindow(frame: root.frame)
    window.addSubview(root)
    defer { withExtendedLifetime(window) {} }
    let stack = CenteredIntrinsicProbe()
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    if legacy {
        for axis in [RRLayoutAttribute.centerX, .centerY] {
            root.legacyAddConstraint(RRLayoutConstraint(item: stack, attribute: axis, relatedBy: .equal,
                toItem: root, attribute: axis, multiplier: 1, constant: 0))
        }
        root.legacyLayoutIfNeeded()
    } else {
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
        root.setNeedsLayout(); root.layoutIfNeeded()
    }
    let initial = stack.frame
    stack.contentSize = CGSize(width: 207, height: 93)
    if legacy {
        // This synthetic override changed stored content outside the bridge;
        // mirror the generation bump performed by the iOS 5 public intrinsic
        // invalidation IMP. Native UIKit keeps its own invalidation below.
        LegacyLayoutMutation.bump()
        stack.legacySetNeedsUpdateConstraints()
        precondition(stack.legacyAutomaticLayoutRoot() === root, "centered intrinsic change must solve parent equations")
        stack.legacyPerformAutomaticLayoutIfNeeded()
    } else {
        stack.invalidateIntrinsicContentSize()
        root.layoutIfNeeded()
    }
    return [initial, stack.frame]
}

@MainActor func checkCenteredIntrinsicFrames(_ native: [CGRect], _ legacy: [CGRect]) -> Bool {
    print("centered intrinsic native: \(native)")
    print("centered intrinsic legacy: \(legacy)")
    guard native.count == 2, legacy.count == 2,
          abs(native[0].width - 166) < 0.01, abs(native[1].width - 207) < 0.01 else { return false }
    for (a, b) in zip(native, legacy) {
        // The legacy engine aligns to whole 1x pixels; native may use half-points.
        for (x, y) in zip([a.minX, a.minY, a.width, a.height], [b.minX, b.minY, b.width, b.height]) {
            if abs(x - y) > 0.5001 { return false }
        }
    }
    return true
}
