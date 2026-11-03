//
//  autolayout_churn.swift
//  Scroll-shaped churn: a screen of frame-based cell hosts, each with a constrained
//  subtree. Every step removes one cell, adds one cell and moves the others by changing
//  their frames (what UICollectionView does when scrolling). The persistent engine must
//  produce exactly the frames a fresh rebuild-per-pass engine produces, every step, and
//  should not rebuild the whole screen for each step.
//
import Foundation
import CoreGraphics
import Cassowary

struct ChurnLCG {
    var state: UInt64
    mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// A cell: frame-based host (translates=true like a UIKit-managed cell) with constrained children.
func makeCell(_ name: String, index: Int, parent: FakeItem, width: CGFloat = 226) -> FakeItem {
    let cell = FakeItem(name, frame: CGRect(x: 10, y: CGFloat(index) * 58, width: width, height: 50), parent: parent)
    cell.translates = true
    parent.children.append(cell)
    let avatar = FakeItem(name + ".avatar", frame: CGRect(x: 0, y: 0, width: 10, height: 10), parent: cell)
    let title = FakeItem(name + ".title", frame: CGRect(x: 0, y: 0, width: 10, height: 10), parent: cell)
    let subtitle = FakeItem(name + ".sub", frame: CGRect(x: 0, y: 0, width: 10, height: 10), parent: cell)
    for v in [avatar, title, subtitle] { v.translates = false; cell.children.append(v) }
    title.intrinsicSize = CGSize(width: 90 + CGFloat(index % 5) * 7, height: 18)
    avatar.constraints = [
        makeConstraint(avatar, .left, .equal, cell, .left, 8),
        makeConstraint(avatar, .centerY, .equal, cell, .centerY, 0),
        makeConstraint(avatar, .width, .equal, nil, .notAnAttribute, 36),
        makeConstraint(avatar, .height, .equal, nil, .notAnAttribute, 36),
    ]
    title.constraints = [
        makeConstraint(title, .left, .equal, avatar, .right, 8),
        makeConstraint(title, .top, .equal, cell, .top, 8),
        makeConstraint(title, .right, .lessThanOrEqual, cell, .right, -8),
    ]
    subtitle.constraints = [
        makeConstraint(subtitle, .left, .equal, title, .left, 0),
        makeConstraint(subtitle, .top, .equal, title, .bottom, 2),
        makeConstraint(subtitle, .width, .equal, nil, .notAnAttribute, 100, priority: 750),
        makeConstraint(subtitle, .height, .equal, nil, .notAnAttribute, 16),
    ]
    return cell
}

func buildScreen(cells: Int) -> (root: FakeItem, list: FakeItem, tree: Tree) {
    let root = FakeItem("root", frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let tree = Tree(root: root)
    let bar = FakeItem("bar", frame: CGRect(x: 10, y: 22, width: 300, height: 44), parent: root)
    bar.translates = false; root.children.append(bar)
    bar.constraints = [makeConstraint(bar, .left, .equal, root, .left, 10), makeConstraint(bar, .top, .equal, root, .top, 22),
                       makeConstraint(bar, .width, .equal, nil, .notAnAttribute, 300), makeConstraint(bar, .height, .equal, nil, .notAnAttribute, 44)]
    let list = FakeItem("list", frame: CGRect(x: 84, y: 74, width: 226, height: 342), parent: root)
    list.translates = true; root.children.append(list)
    for i in 0..<cells { _ = makeCell("c\(i)", index: i, parent: list) }
    return (root, list, tree)
}

func allItems(_ item: FakeItem) -> [FakeItem] { [item] + item.children.flatMap(allItems) }

func frames(_ root: FakeItem) -> [String: CGRect] {
    var r: [String: CGRect] = [:]
    for i in allItems(root) { r[i.label] = i.frame }
    return r
}

func churnMain() -> Int {
    let args = CommandLine.arguments.dropFirst().map { Int($0) ?? 0 }
    let steps = args.first ?? 40
    let cellCount = args.count > 1 ? args[1] : 7
    var mismatches = 0
    var persistentUS = 0.0, freshUS = 0.0
    for presolveMode in [false, true] {
        LegacyLayoutEngine.resetPersistentState(); LegacyLayoutStats.reset()
        var rng = ChurnLCG(state: 0x9E3779B97F4A7C15)
        let a = buildScreen(cells: cellCount)     // engine under test (persistent)
        let b = buildScreen(cells: cellCount)     // reference (fresh rebuild every pass)
        let persistent = LegacyLayoutEngine()
        let fresh = LegacyLayoutEngine(); fresh.usesPersistentSolver = false
        persistent.layout(a.root); fresh.layout(b.root)
        var next = cellCount
        persistentUS = 0; freshUS = 0
        for step in 0..<steps {
            // One draw per step, applied identically to both screens.
            let pick = rng.int(cellCount), delta = CGFloat(4 + rng.int(10)), doEdit = rng.int(3) == 0
            for list in [a.list, b.list] {
                let first = list.children.removeFirst(); first.parent = nil; LegacyLayoutMutation.bump()
                _ = makeCell("c\(next)", index: list.children.count, parent: list)
                for (i, c) in list.children.enumerated() { c.frame = CGRect(x: 10, y: CGFloat(i) * 58 - CGFloat(step % 7), width: 226, height: 50) }
                if doEdit { list.children[pick].children[1].constraints[1].constant = delta }
            }
            next += 1
            var t0 = DispatchTime.now().uptimeNanoseconds
            persistent.layout(a.root)
            persistentUS += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
            t0 = DispatchTime.now().uptimeNanoseconds
            fresh.layout(b.root)
            freshUS += Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
            let fa = frames(a.root), fb = frames(b.root)
            for (k, v) in fb { if let w = fa[k], abs(w.minX - v.minX) + abs(w.minY - v.minY) + abs(w.width - v.width) + abs(w.height - v.height) > 1e-6 {
                mismatches += 1; if mismatches <= 5 { print("MISMATCH step \(step) \(k): persistent=\(w) fresh=\(v)") } } }
        }
        let st = LegacyLayoutStats.snapshot
        print(String(format: "presolve=%@ steps=%d  persistent %.0f us/step  fresh-rebuild %.0f us/step  speedup %.1fx   rebuilds=%d solves=%d cached=%d",
                     presolveMode ? "on " : "off", steps, persistentUS / Double(steps), freshUS / Double(steps), freshUS / max(persistentUS, 1),
                     st.rebuilds, st.solves, st.cachedPasses))
    }
    print(mismatches == 0 ? "PASS: persistent engine frames identical to fresh rebuild on every churn step" : "FAIL: \(mismatches) frame mismatches")
    return mismatches == 0 ? 0 : 1
}
exit(Int32(churnMain()))
