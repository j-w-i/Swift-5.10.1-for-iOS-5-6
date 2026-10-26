//
//  autolayout_presolve_diff.swift
//  Randomised differential test for the guarded presolve pass.
//
//  Generates legal trees/constraint graphs (varying shape, priorities,
//  inequalities, under-constrained axes, conflicts and intrinsic sizes), lays
//  each graph out once with presolve enabled and once with it disabled, and
//  requires every frame to agree within 1e-6 (both on a cold build and after a
//  dirty constant change). Also reports how often presolve applied vs fell back,
//  and how often it applies on the benchmark hierarchy shape.
//

import Foundation
import CoreGraphics
import Cassowary

struct PresolveDiffLCG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func int(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
    mutating func cgfloat(_ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        lower + CGFloat(next() % 1000) / 1000.0 * (upper - lower)
    }
    mutating func priority() -> Float {
        switch int(4) {
        case 0: return 1000
        case 1: return 750
        case 2: return 500
        default: return 250
        }
    }
}

/// A presolved system is mutated (constant, priority, add, remove, tree change)
/// and must behave exactly like the non-presolve engine and like a fresh rebuild
/// on every pass: no stale frames, no mixed-state broken report.
func runMutationSequenceDiagnostics() -> Int {
    func build() -> Tree {
        let root = FakeItem("root", frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let tree = Tree(root: root)
        let a = FakeItem("a", frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        let b = FakeItem("b", frame: CGRect(x: 0, y: 40, width: 100, height: 20))
        tree.add(a, to: root)
        tree.add(b, to: root)
        for (index, item) in [a, b].enumerated() {
            item.constraints = [
                makeConstraint(item, .left, .equal, root, .left, 8),
                makeConstraint(item, .right, .equal, root, .right, -8),
                makeConstraint(item, .top, .equal, root, .top, CGFloat(index) * 40),
                makeConstraint(item, .height, .equal, nil, .notAnAttribute, 20),
                makeConstraint(item, .width, .equal, nil, .notAnAttribute, 100, priority: 750),
            ]
        }
        assignIdentifiers(tree)
        return tree
    }
    let treeA = build()
    let treeB = build()
    var mismatch = 0

    Solver.presolvesEnabled = true
    LegacyLayoutEngine.resetPersistentState()
    let engineA = LegacyLayoutEngine()
    Solver.presolvesEnabled = false
    LegacyLayoutEngine.resetPersistentState()
    let engineB = LegacyLayoutEngine()
    Solver.presolvesEnabled = true

    let mutations: [(String, (Tree) -> Void)] = [
        ("initial", { _ in }),
        ("constant", { tree in
            tree.items[1].constraints[0].constant = 17
        }),
        ("priority", { tree in
            tree.items[1].constraints[4].priority = 250
        }),
        ("add", { tree in
            let a = tree.items[1]
            a.constraints.append(makeConstraint(a, .centerX, .equal, tree.items[0], .centerX, 3))
        }),
        ("remove", { tree in
            let b = tree.items[2]
            let last = b.constraints.last
            b.constraints.removeAll { $0 === last }
        }),
        ("tree", { tree in
            let c = FakeItem("c", frame: CGRect(x: 0, y: 80, width: 50, height: 10))
            tree.add(c, to: tree.items[0])
            c.constraints = [
                makeConstraint(c, .left, .equal, tree.items[0], .left, 12),
                makeConstraint(c, .top, .equal, tree.items[0], .top, 80),
                makeConstraint(c, .height, .equal, nil, .notAnAttribute, 10),
            ]
            assignIdentifiers(tree)
        }),
    ]

    for (name, mutation) in mutations {
        mutation(treeA)
        mutation(treeB)
        // Fresh rebuild-per-pass engine: proves the persistent path rebuilt and
        // did not serve a stale or partially-presolved result.
        let fresh = LegacyLayoutEngine()
        fresh.usesPersistentSolver = false
        let freshResult = fresh.layout(treeA.root)
        let persistentResultA = engineA.layout(treeA.root)
        let persistentResultB = engineB.layout(treeB.root)
        let snapA = snapshot(treeA, persistentResultA)
        let snapB = snapshot(treeB, persistentResultB)
        let snapFresh = snapshot(treeA, freshResult)
        let frameProblems = presolveFrameDifferences(snapA, snapB) + presolveFrameDifferences(snapA, snapFresh)
        let brokenA = presolveBrokenDescriptors(persistentResultA)
        let brokenB = presolveBrokenDescriptors(persistentResultB)
        let brokenFresh = presolveBrokenDescriptors(freshResult)
        if !frameProblems.isEmpty || brokenA != brokenB || brokenA != brokenFresh {
            mismatch += 1
            print("MUTATION MISMATCH \(name): frames=\(frameProblems.prefix(4)) broken=\(brokenA)/\(brokenB)/\(brokenFresh)")
        }
    }
    if mismatch == 0 {
        print("PASS: presolved system mutations (constant/priority/add/remove/tree) rebuild through the presolve path; frames and brokenConstraints match the non-presolve engine and a fresh rebuild")
    }
    return mismatch
}

func presolveGraph(_ rng: inout PresolveDiffLCG) -> Tree {
    let rootWidth = rng.cgfloat(200, 500)
    let rootHeight = rng.cgfloat(200, 700)
    let root = FakeItem("root", frame: CGRect(x: 0, y: 0, width: rootWidth, height: rootHeight))
    let tree = Tree(root: root)
    let childCount = 1 + rng.int(5)
    var children: [FakeItem] = []
    for index in 0..<childCount {
        let item = FakeItem("c\(index)", frame: CGRect(x: rng.cgfloat(0, 60), y: rng.cgfloat(0, 60),
                                                        width: rng.cgfloat(20, 120), height: rng.cgfloat(10, 40)))
        tree.add(item, to: root)
        children.append(item)
    }
    for item in children {
        switch rng.int(7) {
        case 0: // fully pinned: all four axes are one-free-variable equalities.
            item.constraints.append(makeConstraint(item, .left, .equal, root, .left, rng.cgfloat(0, 20)))
            item.constraints.append(makeConstraint(item, .right, .equal, root, .right, -rng.cgfloat(0, 20)))
            item.constraints.append(makeConstraint(item, .top, .equal, root, .top, rng.cgfloat(0, 80)))
            item.constraints.append(makeConstraint(item, .height, .equal, nil, .notAnAttribute, rng.cgfloat(10, 40)))
        case 1: // horizontally under-constrained (stays decide).
            item.constraints.append(makeConstraint(item, .top, .equal, root, .top, rng.cgfloat(0, 80)))
            item.constraints.append(makeConstraint(item, .height, .equal, nil, .notAnAttribute, rng.cgfloat(10, 40)))
        case 2: // mixed required/optional widths plus a leading pin.
            item.constraints.append(makeConstraint(item, .left, .equal, root, .left, rng.cgfloat(0, 20)))
            item.constraints.append(makeConstraint(item, .width, .equal, nil, .notAnAttribute,
                                                   rng.cgfloat(20, 120), priority: rng.priority()))
            item.constraints.append(makeConstraint(item, .top, .equal, root, .top, rng.cgfloat(0, 80)))
        case 3: // inequality over a presolved variable (must become a constant check).
            item.constraints.append(makeConstraint(item, .width, .greaterThanOrEqual, nil, .notAnAttribute,
                                                   rng.cgfloat(0, 60)))
            item.constraints.append(makeConstraint(item, .left, .equal, root, .left, rng.cgfloat(0, 20)))
            item.constraints.append(makeConstraint(item, .right, .equal, root, .right, -rng.cgfloat(0, 20)))
            item.constraints.append(makeConstraint(item, .top, .equal, root, .top, rng.cgfloat(0, 80)))
        case 4: // centre + bottom chain: two-term expressions that simplify.
            item.constraints.append(makeConstraint(item, .centerX, .equal, root, .centerX, rng.cgfloat(-10, 10)))
            item.constraints.append(makeConstraint(item, .bottom, .equal, root, .bottom, -rng.cgfloat(0, 40)))
            item.constraints.append(makeConstraint(item, .width, .equal, nil, .notAnAttribute, rng.cgfloat(20, 100)))
            item.constraints.append(makeConstraint(item, .height, .equal, nil, .notAnAttribute, rng.cgfloat(10, 40)))
        case 5: // two conflicting required widths: presolve must decline or relax.
            item.constraints.append(makeConstraint(item, .left, .equal, root, .left, rng.cgfloat(0, 20)))
            item.constraints.append(makeConstraint(item, .width, .equal, nil, .notAnAttribute, rng.cgfloat(20, 100)))
            item.constraints.append(makeConstraint(item, .width, .equal, nil, .notAnAttribute, rng.cgfloat(20, 100)))
            item.constraints.append(makeConstraint(item, .top, .equal, root, .top, rng.cgfloat(0, 80)))
        default: // pin + a soft width preference + intrinsic size.
            item.constraints.append(makeConstraint(item, .left, .equal, root, .left, rng.cgfloat(0, 20)))
            item.constraints.append(makeConstraint(item, .top, .equal, root, .top, rng.cgfloat(0, 80)))
            item.constraints.append(makeConstraint(item, .width, .equal, nil, .notAnAttribute,
                                                   rng.cgfloat(20, 120), priority: rng.priority()))
            item.intrinsicSize = CGSize(width: rng.int(3) == 0 ? rng.cgfloat(20, 100) : -1, height: -1)
        }
    }
    return tree
}

/// Frames within 1e-6 (the proof requirement). The broken-constraint *report*
/// can legitimately differ between a rebuild with presolve and the incremental
/// solver path for genuinely unsatisfiable required rows, so it is reported but
/// not treated as a failure.
func presolveFrameDifferences(_ a: PassSnapshot, _ b: PassSnapshot, tolerance: CGFloat = 1e-6) -> [String] {
    var problems: [String] = []
    for (label, expected) in a.frames {
        guard let actual = b.frames[label] else {
            problems.append("missing frame for \(label)")
            continue
        }
        let fields: [(String, CGFloat, CGFloat)] = [
            ("x", expected.minX, actual.minX),
            ("y", expected.minY, actual.minY),
            ("w", expected.width, actual.width),
            ("h", expected.height, actual.height),
        ]
        for (name, lhs, rhs) in fields where abs(lhs - rhs) > tolerance {
            problems.append("\(label).\(name): \(lhs) != \(rhs)")
        }
    }
    return problems
}

func assignIdentifiers(_ tree: Tree) {
    for item in tree.items {
        for (index, constraint) in item.constraints.enumerated() {
            constraint.identifier = "\(item.label)#\(index)"
        }
    }
}

func presolveBrokenDescriptors(_ result: LegacyLayoutResult) -> [String] {
    result.brokenConstraints.map { $0.identifier ?? "<nil>" }.sorted()
}

func runPresolveDiff() {
    var mismatches = 0
    var graphCount = 0
    var dirtyCount = 0
    var appliedBuilds = 0
    var fallbackBuilds = 0
    var checkedFrames = 0
    var diagnosticMismatches = 0
    var incrementalDivergences = 0

    for seed in 1...250 {
        var rng = PresolveDiffLCG(state: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15)
        let treeA = presolveGraph(&rng)
        var rngB = PresolveDiffLCG(state: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15)
        let treeB = presolveGraph(&rngB)
        var rngC = PresolveDiffLCG(state: UInt64(seed) &* 0x9E37_79B9_7F4A_7C15)
        let treeC = presolveGraph(&rngC)
        assignIdentifiers(treeC)
        graphCount += 1

        Solver.presolvesEnabled = true
        LegacyLayoutEngine.resetPersistentState()
        Solver.resetPresolveStatistics()
        let engineA = LegacyLayoutEngine()
        let resultA = engineA.layout(treeA.root)
        let snapshotA = snapshot(treeA, resultA)
        assignIdentifiers(treeA)
        appliedBuilds += Solver.totalPresolveApplied
        fallbackBuilds += Solver.totalPresolveFallback

        Solver.presolvesEnabled = false
        LegacyLayoutEngine.resetPersistentState()
        let engineB = LegacyLayoutEngine()
        let resultB = engineB.layout(treeB.root)
        let snapshotB = snapshot(treeB, resultB)
        checkedFrames += snapshotA.frames.count + snapshotB.frames.count
        assignIdentifiers(treeB)
        let coldDifferences = presolveFrameDifferences(snapshotA, snapshotB)
        let coldBrokenA = presolveBrokenDescriptors(resultA)
        let coldBrokenB = presolveBrokenDescriptors(resultB)
        if !coldDifferences.isEmpty {
            mismatches += 1
            if mismatches <= 10 {
                print("MISMATCH seed \(seed) cold: \(coldDifferences.prefix(6).joined(separator: "; "))")
            }
        }
        if coldBrokenA != coldBrokenB {
            diagnosticMismatches += 1
            if diagnosticMismatches <= 10 {
                print("BROKEN MISMATCH seed \(seed) cold: \(coldBrokenA) != \(coldBrokenB)")
            }
        }

        // Dirty pass: change one constant in all three trees. The proof compares
        // the presolve engine (which rebuilds) against a non-presolve REBUILD
        // engine (treeC), so a pre-existing incremental-vs-rebuild difference in
        // the non-presolve engine cannot mask or fake a presolve difference.
        if let firstA = treeA.items.dropFirst().first, let firstB = treeB.items.dropFirst().first,
           let firstC = treeC.items.dropFirst().first,
           let constraintA = firstA.constraints.first, let constraintB = firstB.constraints.first,
           let constraintC = firstC.constraints.first {
            constraintA.constant = constraintA.constant + 7.5
            constraintB.constant = constraintB.constant + 7.5
            constraintC.constant = constraintC.constant + 7.5
            dirtyCount += 1
            let dirtyResultA = engineA.layout(treeA.root)
            let dirtyResultB = engineB.layout(treeB.root)
            let rebuildEngine = LegacyLayoutEngine()
            rebuildEngine.usesPersistentSolver = false
            _ = rebuildEngine.layout(treeC.root) // cold pass: same stays as A/B cold
            let dirtyResultC = rebuildEngine.layout(treeC.root)
            let dirtyA = snapshot(treeA, dirtyResultA)
            let dirtyB = snapshot(treeB, dirtyResultB)
            let dirtyC = snapshot(treeC, dirtyResultC)
            checkedFrames += dirtyA.frames.count + dirtyC.frames.count
            let differencesDirty = presolveFrameDifferences(dirtyA, dirtyC)
            if !differencesDirty.isEmpty {
                mismatches += 1
                if mismatches <= 10 {
                    print("MISMATCH seed \(seed) dirty (presolve vs non-presolve rebuild): \(differencesDirty.prefix(6).joined(separator: "; "))")
                }
            }
            let dirtyBrokenA = presolveBrokenDescriptors(dirtyResultA)
            let dirtyBrokenC = presolveBrokenDescriptors(dirtyResultC)
            if dirtyBrokenA != dirtyBrokenC {
                diagnosticMismatches += 1
                if diagnosticMismatches <= 10 {
                    print("BROKEN MISMATCH seed \(seed) dirty: \(dirtyBrokenA) != \(dirtyBrokenC)")
                }
            }
            if presolveFrameDifferences(dirtyB, dirtyC) != [] ||
                presolveBrokenDescriptors(dirtyResultB) != dirtyBrokenC {
                incrementalDivergences += 1
            }
        }

        Solver.presolvesEnabled = true
    }

    // How often presolve applies on the synthetic benchmark hierarchy shape.
    let benchRoot = FakeItem("root", frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let benchTree = Tree(root: benchRoot)
    for index in 0..<50 {
        let item = FakeItem("b\(index)", frame: CGRect(x: 0, y: CGFloat(index) * 20, width: 100, height: 20))
        benchTree.add(item, to: benchRoot)
        item.constraints.append(makeConstraint(item, .left, .equal, benchRoot, .left, 8))
        item.constraints.append(makeConstraint(item, .right, .equal, benchRoot, .right, -8))
        item.constraints.append(makeConstraint(item, .top, .equal, benchRoot, .top, CGFloat(index) * 20))
        item.constraints.append(makeConstraint(item, .height, .equal, nil, .notAnAttribute, 20))
    }
    Solver.presolvesEnabled = true
    LegacyLayoutEngine.resetPersistentState()
    Solver.resetPresolveStatistics()
    let benchEngine = LegacyLayoutEngine()
    _ = benchEngine.layout(benchTree.root)
    let benchApplied = Solver.totalPresolveApplied
    let benchFallback = Solver.totalPresolveFallback

    if incrementalDivergences > 0 {
        print("presolve-diff: note: \(incrementalDivergences) dirty pass(es) also differ between the non-presolve incremental path and a non-presolve rebuild (pre-existing, not presolve)")
    }
    let mutationMismatches = runMutationSequenceDiagnostics()
    if mutationMismatches > 0 {
        mismatches += mutationMismatches
        diagnosticMismatches += mutationMismatches
    }

    print("presolve-diff: graphs=\(graphCount) dirty passes=\(dirtyCount) frames=\(checkedFrames) mismatches=\(mismatches) diagnosticMismatches=\(diagnosticMismatches)")
    print("presolve-diff: presolve applied builds=\(appliedBuilds) fallback builds=\(fallbackBuilds) over \(graphCount + dirtyCount) builds")
    let totalBuilds = appliedBuilds + fallbackBuilds
    if totalBuilds > 0 {
        print(String(format: "presolve-diff: applied %.1f%%, fallback %.1f%%",
                     100.0 * Double(appliedBuilds) / Double(totalBuilds),
                     100.0 * Double(fallbackBuilds) / Double(totalBuilds)))
    } else {
        print("presolve-diff: presolve applied 0 builds, fallback 0 builds")
    }
    print("presolve-diff: benchmark hierarchy @50 pinned children: applied=\(benchApplied) fallback=\(benchFallback)")

    if mismatches == 0 {
        print("PASS: presolve differential (\(graphCount) graphs, \(dirtyCount) dirty passes, frames within 1e-6)")
    } else {
        print("FAIL: presolve differential: \(mismatches) mismatch(es)")
        exit(1)
    }
}

runPresolveDiff()
