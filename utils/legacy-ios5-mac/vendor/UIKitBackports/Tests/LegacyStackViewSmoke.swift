//
//  LegacyStackViewSmoke.swift
//  Runtime fixture for the iOS 5 UIStackView crash (device / simulator).
//
//  This is the same pattern as utils/legacy-ios5-mac/GenericRuntimeSmoke.swift:
//  there is no XCTest, entry point or mock — compile this file into the backport
//  module (or an app that also compiles LegacyAutoLayout sources) and call
//  `runLegacyStackViewSmoke()` after launch. It must run with the legacy bridge
//  force-installed, i.e. through `LegacyAutoLayout.installForLegacyNames()`,
//  which is the path an iOS 5 name-shim binary takes.
//
//  Expected PASS lines:
//    stack-smoke: installed audit clean
//    stack-smoke: build ok constraints=<n> arranged=<n>
//    stack-smoke: hide ok visible=<n>
//    stack-smoke: insert ok arranged=<n>
//    stack-smoke: remove ok arranged=<n>
//    stack-smoke: frames finite
//

import Foundation
import UIKit

@MainActor
func runLegacyStackViewSmoke() -> [String] {
    var results: [String] = []

    // Force the legacy bridge even when the OS has Auto Layout: this is what the
    // iOS 5 name-shim path (and the simulator stress test) does.
    LegacyAutoLayout.installForLegacyNames()
    let audit = LegacyAutoLayout.auditInstalledBridge()
    if audit.isEmpty {
        results.append("stack-smoke: installed audit clean")
    } else {
        for issue in audit { results.append("stack-smoke: AUDIT ISSUE: \(issue)") }
    }

    let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let stack = UIStackView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
    stack.axis = .vertical
    container.addSubview(stack)
    for index in 0..<3 {
        let view = UIView(frame: CGRect(x: 0, y: CGFloat(index) * 40, width: 100, height: 30))
        stack.addArrangedSubview(view)
    }
    container.layoutIfNeeded()
    results.append("stack-smoke: build ok constraints=\(container.constraints.count) arranged=\(stack.arrangedSubviews.count)")

    // Toggling hidden must not add/remove constraints or raise.
    stack.arrangedSubviews[1].isHidden = true
    container.layoutIfNeeded()
    results.append("stack-smoke: hide ok visible=\(stack.arrangedSubviews.filter { !$0.isHidden }.count)")

    let inserted = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
    stack.insertArrangedSubview(inserted, at: 1)
    container.layoutIfNeeded()
    results.append("stack-smoke: insert ok arranged=\(stack.arrangedSubviews.count)")

    stack.removeArrangedSubview(inserted)
    inserted.removeFromSuperview()
    container.layoutIfNeeded()
    results.append("stack-smoke: remove ok arranged=\(stack.arrangedSubviews.count)")

    let finite = stack.arrangedSubviews.allSatisfy {
        $0.frame.minX.isFinite && $0.frame.minY.isFinite && $0.frame.width.isFinite && $0.frame.height.isFinite
    }
    results.append(finite ? "stack-smoke: frames finite" : "stack-smoke: FRAMES NOT FINITE")
    return results
}
