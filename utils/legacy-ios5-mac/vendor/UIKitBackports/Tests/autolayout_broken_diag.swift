//
//  autolayout_broken_diag.swift
//  Broken/relaxed-constraint diagnostics, compiled against both the current
//  engine and the f27d2e0b reference (same dual-build pattern as
//  autolayout_golden.swift). Each scenario is an unsatisfiable / conflicting
//  required system; the output lists the broken-constraint count and the
//  identifiers of the constraints the engine reports as broken, so the runner
//  can require:
//    * current engine, presolve on  == current engine, presolve off
//    * current engine, presolve on  == f27d2e0b rebuild-per-pass engine
//
//  Build with -DNEW_ENGINE for the current engine; the reference build omits it.
//

import Foundation
import CoreGraphics
import Cassowary

final class DiagItem: LegacyLayoutItem {
    weak var parent: DiagItem?
    var children: [DiagItem] = []
    var frame: CGRect
    var constraints: [RRLayoutConstraint] = []
    let label: String
    init(_ label: String, frame: CGRect, parent: DiagItem? = nil) {
        self.label = label
        self.frame = frame
        self.parent = parent
    }
    var layoutSuperitem: LegacyLayoutItem? { parent }
    var layoutSubitems: [LegacyLayoutItem] { children }
    var layoutFrame: CGRect { frame }
    func layoutSetFrame(_ newFrame: CGRect) { frame = newFrame }
    var layoutConstraints: [RRLayoutConstraint] { constraints }
    var layoutTranslatesAutoresizingMaskIntoConstraints: Bool { false }
    var layoutAutoresizingMask: RRAutoresizingMask { .none }
    var layoutAutoresizingReference: LegacyAutoresizingReference? { nil }
    func layoutUpdateAutoresizingReference(_ reference: LegacyAutoresizingReference) {}
    var layoutIntrinsicContentSize: CGSize { CGSize(width: -1, height: -1) }
}

func diagConstraint(_ first: DiagItem, _ attribute: RRLayoutAttribute,
                    _ relation: RRLayoutRelation = .equal,
                    _ second: DiagItem?, _ secondAttribute: RRLayoutAttribute = .notAnAttribute,
                    _ constant: CGFloat, priority: Float = 1000,
                    identifier: String) -> RRLayoutConstraint {
    let constraint = RRLayoutConstraint(item: first, attribute: attribute,
                                        relatedBy: relation, toItem: second,
                                        attribute: secondAttribute, multiplier: 1, constant: constant)
    constraint.priority = priority
    constraint.identifier = identifier
    return constraint
}

struct DiagScenario {
    let name: String
    let constraints: (DiagItem, DiagItem) -> [RRLayoutConstraint]
}

let diagScenarios: [DiagScenario] = [
    DiagScenario(name: "conflicting-widths") { a, root in
        [diagConstraint(a, .left, .equal, root, .left, 8, identifier: "cw.left"),
         diagConstraint(a, .width, .equal, nil, .notAnAttribute, 100, identifier: "cw.width100"),
         diagConstraint(a, .width, .equal, nil, .notAnAttribute, 160, identifier: "cw.width160"),
         diagConstraint(a, .top, .equal, root, .top, 0, identifier: "cw.top")]
    },
    DiagScenario(name: "conflicting-edges") { a, root in
        [diagConstraint(a, .left, .equal, root, .left, 8, identifier: "ce.left8"),
         diagConstraint(a, .left, .equal, root, .left, 24, identifier: "ce.left24"),
         diagConstraint(a, .top, .equal, root, .top, 0, identifier: "ce.top"),
         diagConstraint(a, .height, .equal, nil, .notAnAttribute, 20, identifier: "ce.height")]
    },
    DiagScenario(name: "negative-width") { a, root in
        [diagConstraint(a, .width, .equal, nil, .notAnAttribute, -20, identifier: "nw.width"),
         diagConstraint(a, .left, .equal, root, .left, 0, identifier: "nw.left"),
         diagConstraint(a, .top, .equal, root, .top, 0, identifier: "nw.top")]
    },
    DiagScenario(name: "triangle-width") { a, root in
        [diagConstraint(a, .width, .equal, nil, .notAnAttribute, 100, identifier: "tw.width100"),
         diagConstraint(a, .left, .equal, root, .left, 0, identifier: "tw.left"),
         diagConstraint(a, .right, .equal, root, .right, 0, identifier: "tw.right"),
         diagConstraint(a, .top, .equal, root, .top, 0, identifier: "tw.top")]
    },
    DiagScenario(name: "three-heights") { a, root in
        [diagConstraint(a, .height, .equal, nil, .notAnAttribute, 20, identifier: "th.h20"),
         diagConstraint(a, .height, .equal, nil, .notAnAttribute, 24, identifier: "th.h24"),
         diagConstraint(a, .height, .equal, nil, .notAnAttribute, 28, identifier: "th.h28"),
         diagConstraint(a, .left, .equal, root, .left, 0, identifier: "th.left")]
    },
    DiagScenario(name: "inequality-conflict") { a, root in
        [diagConstraint(a, .width, .greaterThanOrEqual, nil, .notAnAttribute, 200, identifier: "ic.min200"),
         diagConstraint(a, .width, .lessThanOrEqual, nil, .notAnAttribute, 100, identifier: "ic.max100"),
         diagConstraint(a, .left, .equal, root, .left, 0, identifier: "ic.left")]
    },
    DiagScenario(name: "width-and-edges") { a, root in
        [diagConstraint(a, .width, .equal, nil, .notAnAttribute, 100, identifier: "we.width100"),
         diagConstraint(a, .left, .equal, root, .left, 8, identifier: "we.left"),
         diagConstraint(a, .right, .equal, root, .right, -8, identifier: "we.right"),
         diagConstraint(a, .top, .equal, root, .top, 0, identifier: "we.top"),
         diagConstraint(a, .bottom, .equal, root, .bottom, -8, identifier: "we.bottom"),
         diagConstraint(a, .height, .equal, nil, .notAnAttribute, 20, identifier: "we.height")]
    },
]

func runDiagScenario(_ scenario: DiagScenario, presolve: Bool) {
    #if NEW_ENGINE
    Solver.presolvesEnabled = presolve
    LegacyLayoutEngine.resetPersistentState()
    #endif
    let root = DiagItem("root", frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let a = DiagItem("a", frame: CGRect(x: 0, y: 0, width: 100, height: 20), parent: root)
    root.children = [a]
    a.constraints = scenario.constraints(a, root)
    let engine = LegacyLayoutEngine()
    let result = engine.layout(root)
    let mode = presolve ? "on" : "off"
    let identifiers = result.brokenConstraints.map { $0.identifier ?? "<nil>" }.sorted()
    print("\(scenario.name)|0|\(mode)|\(result.brokenConstraints.count)|\(identifiers.joined(separator: ","))")
    #if !NEW_ENGINE
    _ = mode
    #endif
}

for scenario in diagScenarios {
    runDiagScenario(scenario, presolve: true)
    #if NEW_ENGINE
    // Baseline (f27d2e0b) has no presolve switch: its output is the reference
    // "off" semantics, so the current engine also emits the presolve-off run.
    runDiagScenario(scenario, presolve: false)
    #endif
}
#if NEW_ENGINE
Solver.presolvesEnabled = true
#endif
