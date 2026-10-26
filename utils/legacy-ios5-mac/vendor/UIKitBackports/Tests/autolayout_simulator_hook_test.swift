//
//  autolayout_simulator_hook_test.swift
//  Simulator regression test for the iOS 5 injected-hook crash.
//
//  Built by Tests/run-simulator-hook-test.sh together with the staged
//  LegacyAutoLayout/Cassowary sources, for an iOS simulator target. The bridge is
//  force-installed (the legacy-name path) and UIView's constraint API is driven
//  through the injected hooks with an OALayoutGuide-shaped receiver.
//
//  Before the fix, -[<UIView> addConstraints:] ran the injected hook as an IMP on
//  the view and called the sibling @objc hook `rr_a_addConstraint:` on `self`,
//  which UIView does not implement: doesNotRecognizeSelector: -> NSException ->
//  crash. This test fails if that can happen again.
//

import UIKit
import Foundation

final class OALayoutGuideLike: UIView {}

@MainActor
func runHookTest() -> [String] {
    var lines: [String] = []
    func emit(_ line: String) { lines.append(line); print(line) }

    // 1. A normal (non-legacy) run must be completely unaffected: the runtime gate
    // refuses to install on an OS with Auto Layout and native constraints work.
    let normalInstalled = LegacyAutoLayout.installIfNeeded()
    let normalActive = LegacyAutoLayout.isActive
    emit("sim: normal installIfNeeded=\(normalInstalled) active=\(normalActive)")
    let nativeView = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    let nativeConstraint = NSLayoutConstraint(item: nativeView, attribute: .width, relatedBy: .equal,
                                              toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 42)
    nativeView.addConstraints([nativeConstraint])
    let nativeCount = (nativeView.constraints as NSArray).count
    emit("sim: normal constraints ok count=\(nativeCount)")

    // 2. Force the legacy (iOS 5) bridge, exactly like a legacy-name binary.
    LegacyAutoLayout.installForLegacyNames()
    let audit = LegacyAutoLayout.auditInstalledBridge()
    emit("sim: installed=\(LegacyAutoLayout.isActive) auditIssues=\(audit.count)")
    for issue in audit { emit("sim: AUDIT: \(issue)") }

    let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let guide = OALayoutGuideLike(frame: CGRect(x: 0, y: 0, width: 50, height: 40))
    host.addSubview(guide)
    let other = UIView(frame: CGRect(x: 0, y: 60, width: 50, height: 40))
    host.addSubview(other)

    let width = RRLayoutConstraint(item: guide, attribute: .width, relatedBy: .equal,
                                   toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 120)
    let leading = RRLayoutConstraint(item: guide, attribute: .leading, relatedBy: .equal,
                                     toItem: host, attribute: .leading, multiplier: 1, constant: 12)
    let spacing = RRLayoutConstraint(item: other, attribute: .top, relatedBy: .equal,
                                     toItem: guide, attribute: .bottom, multiplier: 1, constant: 8)

    // This is the crashing entry point: UIView addConstraints: -> injected loop.
    host.perform(NSSelectorFromString("addConstraints:"), with: [width, leading, spacing])
    let owned = (host.perform(NSSelectorFromString("constraints"))?.takeUnretainedValue() as? NSArray)?.count ?? -1
    emit("sim: addConstraints ok count=\(owned)")
    host.perform(NSSelectorFromString("removeConstraints:"), with: [spacing])
    let afterRemove = (host.perform(NSSelectorFromString("constraints"))?.takeUnretainedValue() as? NSArray)?.count ?? -1
    emit("sim: removeConstraints ok count=\(afterRemove)")

    // Stack-shaped mutations (hidden / insert / remove arranged subviews).
    let stack = UIView(frame: CGRect(x: 0, y: 200, width: 320, height: 200))
    host.addSubview(stack)
    var arranged: [UIView] = []
    for index in 0..<3 {
        let view = UIView(frame: CGRect(x: 0, y: CGFloat(index) * 40, width: 100, height: 30))
        stack.addSubview(view)
        arranged.append(view)
    }
    arranged[1].isHidden = true
    emit("sim: hide ok visible=\(arranged.filter { !$0.isHidden }.count)")
    let inserted = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
    stack.addSubview(inserted)
    arranged.insert(inserted, at: 1)
    emit("sim: insert ok arranged=\(arranged.count)")
    arranged.removeAll { $0 === inserted }
    inserted.removeFromSuperview()
    emit("sim: remove ok arranged=\(arranged.count)")

    host.layoutIfNeeded()
    let finite = host.subviews.allSatisfy { $0.frame.minX.isFinite && $0.frame.minY.isFinite }
    emit(finite ? "sim: frames finite" : "sim: FRAMES NOT FINITE")

    let finalAudit = LegacyAutoLayout.auditInstalledBridge()
    emit("sim: finalAudit=\(finalAudit.count)")
    if normalInstalled || normalActive || nativeCount != 1 {
        emit("sim: normal-path check FAILED")
    }
    if audit.isEmpty && owned == 3 && afterRemove == 2 && finite && finalAudit.isEmpty {
        emit("sim: PASS")
    } else {
        emit("sim: FAIL")
    }
    return lines
}

MainActor.assumeIsolated { _ = runHookTest() }
