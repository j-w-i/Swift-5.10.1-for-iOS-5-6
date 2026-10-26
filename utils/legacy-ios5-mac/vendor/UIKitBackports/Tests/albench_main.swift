//
//  albench_main.swift
//  LegacyAutoLayout host benchmark
//
//  Synthetic constraint-heavy hierarchy, same shape as the previous benchmark:
//  each row is a child pinned left/right/top with its own height constraint.
//
//  Usage: albench MODE ROWS PASSES
//    rebuild     full rebuild on every layout pass (old behaviour)
//    persistent  persistent incremental solver (steady state should be cached)
//

import Foundation
import CoreGraphics

func buildTree(rows: Int) -> FakeItem {
    let root = FakeItem("root", frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    for index in 0..<rows {
        let child = FakeItem("row\(index)",
                             frame: CGRect(x: 0, y: CGFloat(index) * 20, width: 320, height: 20),
                             parent: root)
        root.children.append(child)
        child.constraints.append(makeConstraint(child, .left, .equal, root, .left, 8))
        child.constraints.append(makeConstraint(child, .right, .equal, root, .right, -8))
        child.constraints.append(makeConstraint(child, .top, .equal, root, .top, CGFloat(index) * 20))
        child.constraints.append(makeConstraint(child, .height, .equal, nil, .notAnAttribute, 20))
    }
    return root
}

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "persistent"
let rows = Int(arguments.count > 2 ? arguments[2] : "50") ?? 50
let passes = Int(arguments.count > 3 ? arguments[3] : "20") ?? 20

LegacyLayoutEngine.resetPersistentState()
LegacyLayoutStats.reset()

let root = buildTree(rows: rows)
let engine = LegacyLayoutEngine()
engine.usesPersistentSolver = (mode == "persistent")

var passTimes: [Double] = []
passTimes.reserveCapacity(passes)
for _ in 0..<passes {
    let start = DispatchTime.now().uptimeNanoseconds
    engine.layout(root)
    passTimes.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1000.0)
}
let total = passTimes.reduce(0, +)
let stats = LegacyLayoutStats.snapshot
let first = passTimes.first.map { String(format: "%.1f", $0) } ?? "-"
let steady = passTimes.count > 1
    ? String(format: "%.1f", passTimes.dropFirst().reduce(0, +) / Double(passTimes.count - 1))
    : "-"
print(String(format: "mode=%@ rows=%d constraints=%d passes=%d avg=%.1f us/pass first=%@ steady=%@",
             mode, rows, rows * 4, passes, total / Double(passes), first, steady))
print("counters: passes=\(stats.passes) solves=\(stats.solves) cached=\(stats.cachedPasses) " +
      "rebuilds=\(stats.rebuilds) installed=\(stats.constraintsInstalled) " +
      "removed=\(stats.constraintsRemoved) variables=\(stats.variables)")
exit(0)
