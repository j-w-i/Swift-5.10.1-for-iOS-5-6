//
//  autolayout_simulator_perf.swift
//  Simulator timing/profiling fixture for the legacy path (force-installed).
//
//  Times the three phases the device stress app reports:
//    activate  : legacyIsActive = true (the body behind NSLayoutConstraint.isActive)
//    layout    : host.layoutIfNeeded() (engine pass through the injected hooks)
//    teardown  : deactivate + remove subviews
//  over N children x 4 constraints. Host-speed simulator, so absolute numbers are
//  not device numbers; the scaling is what exposes O(n^2).
//

import UIKit
import Foundation

@MainActor
func constraintOwner(_ constraint: RRLayoutConstraint) -> UIView? {
    guard let first = constraint.firstItem as? UIView else { return nil }
    guard let second = constraint.secondItem as? UIView else { return first }
    var ancestor: UIView? = first
    while let candidate = ancestor {
        var other: UIView? = second
        while let next = other {
            if next === candidate { return candidate }
            other = next.superview
        }
        ancestor = candidate.superview
    }
    return nil
}

@MainActor
func runPerf() -> [String] {
    var lines: [String] = []
    func emit(_ line: String) { lines.append(line); print(line) }

    // Warm up the bridge/class registration once.
    LegacyAutoLayout.installForLegacyNames()
    let audit = LegacyAutoLayout.auditInstalledBridge()
    emit("perf: installed=\(LegacyAutoLayout.isActive) auditIssues=\(audit.count)")

    // `clean`: translatesAutoresizingMaskIntoConstraints = false everywhere (the
    // normal constraint-based setup). `default`: UIKit's default true, which makes
    // the engine's required autoresizing pins conflict with the user constraints.
    let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "default"
    let clean = mode == "clean"
    let activationOnly = mode == "act"
    emit("perf: mode=\(mode)")
    let sizes = activationOnly ? [200] : [1, 5, 20, 50, 200]
    let cycles = activationOnly ? 200 : 20
    for children in sizes {
        var activateNs: UInt64 = 0
        var layoutNs: UInt64 = 0
        var teardownNs: UInt64 = 0
        var brokenTotal = 0
        var invalidationsTotal = 0
        let before = LegacyLayoutStats.snapshot
        for _ in 0..<cycles {
            LegacyLayoutEngine.resetPersistentState()
            let host = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            if clean { host.legacyTranslatesAutoresizingMaskIntoConstraints = false }
            var views: [UIView] = []
            for index in 0..<children {
                let view = UIView(frame: CGRect(x: 8, y: CGFloat(index) * 20, width: 300, height: 20))
                if clean { view.legacyTranslatesAutoresizingMaskIntoConstraints = false }
                host.addSubview(view)
                views.append(view)
            }
            var constraints: [RRLayoutConstraint] = []
            constraints.reserveCapacity(children * 4)
            for (index, view) in views.enumerated() {
                constraints.append(RRLayoutConstraint(item: view, attribute: .leading, relatedBy: .equal,
                                                      toItem: host, attribute: .leading, multiplier: 1, constant: 8))
                constraints.append(RRLayoutConstraint(item: view, attribute: .trailing, relatedBy: .equal,
                                                      toItem: host, attribute: .trailing, multiplier: 1, constant: -8))
                constraints.append(RRLayoutConstraint(item: view, attribute: .top, relatedBy: .equal,
                                                      toItem: host, attribute: .top, multiplier: 1, constant: CGFloat(index) * 20))
                constraints.append(RRLayoutConstraint(item: view, attribute: .height, relatedBy: .equal,
                                                      toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 20))
            }
            let invalidationsBefore = LegacyAutoLayoutRuntime.containerLayoutInvalidationCount
            let startActivate = DispatchTime.now().uptimeNanoseconds
            // Exactly what -[NSLayoutConstraint setActive:] does on iOS 5.
            for constraint in constraints {
                constraint.legacyIsActive = true
                constraintOwner(constraint)?.legacyAddConstraint(constraint)
            }
            let endActivate = DispatchTime.now().uptimeNanoseconds
            if activationOnly {
                // Profiling helper: keep the activation/deactivation path hot
                // without the engine pass.
                let endLayout = DispatchTime.now().uptimeNanoseconds
                let endTeardownPlaceholder = endLayout
                _ = endTeardownPlaceholder
                for constraint in constraints {
                    constraint.legacyIsActive = false
                    constraintOwner(constraint)?.legacyRemoveConstraint(constraint)
                }
                for view in views { view.removeFromSuperview() }
                let endTeardown = DispatchTime.now().uptimeNanoseconds
                activateNs += endActivate - startActivate
                layoutNs += endLayout - endActivate
                teardownNs += endTeardown - endLayout
                continue
            }
            host.setNeedsLayout()
            let engine = LegacyLayoutEngine(direction: LegacyAutoLayoutSemanticDirection.current)
            let applying = LegacyAutoLayoutRuntime.isApplyingLayoutFrames
            LegacyAutoLayoutRuntime.isApplyingLayoutFrames = true
            let layoutResult = engine.layout(host)
            LegacyAutoLayoutRuntime.isApplyingLayoutFrames = applying
            brokenTotal += layoutResult.brokenConstraints.count
            invalidationsTotal += LegacyAutoLayoutRuntime.containerLayoutInvalidationCount - invalidationsBefore
            let endLayout = DispatchTime.now().uptimeNanoseconds
            for constraint in constraints {
                constraint.legacyIsActive = false
                constraintOwner(constraint)?.legacyRemoveConstraint(constraint)
            }
            for view in views { view.removeFromSuperview() }
            let endTeardown = DispatchTime.now().uptimeNanoseconds
            activateNs += endActivate - startActivate
            layoutNs += endLayout - endActivate
            teardownNs += endTeardown - endLayout
        }
        let after = LegacyLayoutStats.snapshot
        let scale = 1.0 / Double(cycles) / 1000.0
        emit(String(format: "perf: children=%d constraints=%d activate=%.2f us layout=%.2f us teardown=%.2f us",
                    children, children * 4,
                    Double(activateNs) * scale, Double(layoutNs) * scale, Double(teardownNs) * scale))
        emit(String(format: "perf:   broken/cycle=%.1f containerInvalidations/cycle=%.1f",
                    Double(brokenTotal) / Double(cycles), Double(invalidationsTotal) / Double(cycles)))
        let cyclesD = Double(cycles)
        emit(String(format: "perf:   per-cycle solves=%.2f rebuilds=%.2f constraintsInstalled=%.1f variables=%.1f",
                    Double(after.solves - before.solves) / cyclesD,
                    Double(after.rebuilds - before.rebuilds) / cyclesD,
                    Double(after.constraintsInstalled - before.constraintsInstalled) / cyclesD,
                    Double(after.variables - before.variables) / cyclesD))
    }
    emit("perf: done")
    return lines
}

MainActor.assumeIsolated { _ = runPerf() }
