import UIKit

@MainActor private final class IntrinsicFittingRoot: UIView {
    override var intrinsicContentSize: CGSize { CGSize(width: 71, height: 37) }
}
@MainActor func intrinsicRootFitting(legacy: Bool) -> CGSize {
    let view = IntrinsicFittingRoot()
    if legacy { return view.legacyStackFittingSize(CGSize(width: 280, height: -1)) }
    // Compare the private arranged-item fitter to the equivalent native stack
    // contract, not standalone UIView.systemLayoutSizeFitting (which can omit
    // the root's own intrinsic metric).
    let stack = UIStackView(arrangedSubviews: [view])
    stack.axis = .vertical
    return stack.systemLayoutSizeFitting(CGSize(width: 280, height: 0),
        withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
}
@MainActor func checkIntrinsicRootFitting(_ native: CGSize) -> Bool {
    let legacy = intrinsicRootFitting(legacy: true)
    print("intrinsic fitting root native=\(native) legacy=\(legacy)")
    return native == CGSize(width: 280, height: 37) && legacy == native
}
