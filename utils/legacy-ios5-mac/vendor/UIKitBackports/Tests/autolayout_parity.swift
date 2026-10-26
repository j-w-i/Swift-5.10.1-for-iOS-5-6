//
//  autolayout_parity.swift
//  LegacyAutoLayout host parity tests
//
//  For each scenario the persistent engine and a rebuild-per-pass engine lay out
//  two identical trees; frames and broken-constraint counts must agree after
//  every mutation. Scenarios cover the engine-level cases listed in task-7:
//  add/remove constraint, constant and priority changes, reparenting, view
//  removal, multiple roots, autoresizing translation and layout-guide
//  participation.
//

import Foundation
import CoreGraphics

func buildSimpleTree(_ tree: Tree) {
    let a = FakeItem("a", frame: CGRect(x: 0, y: 0, width: 100, height: 20))
    let b = FakeItem("b", frame: CGRect(x: 0, y: 40, width: 100, height: 20))
    tree.add(a, to: tree.root)
    tree.add(b, to: tree.root)
}

func addPin(_ tree: Tree, _ item: FakeItem, top: CGFloat) {
    item.constraints.append(makeConstraint(item, .left, .equal, tree.root, .left, 8))
    item.constraints.append(makeConstraint(item, .right, .equal, tree.root, .right, -8))
    item.constraints.append(makeConstraint(item, .top, .equal, tree.root, .top, top))
    item.constraints.append(makeConstraint(item, .height, .equal, nil, .notAnAttribute, 20))
}

func child(_ tree: Tree, _ label: String) -> FakeItem {
    tree.items.first { $0.label == label }!
}

func removeConstraint(_ item: FakeItem, _ constraint: RRLayoutConstraint) {
    item.constraints.removeAll { $0 === constraint }
}

func main() {
    // 1. Add and remove constraints (rows appear/disappear incrementally).
    do {
        LegacyLayoutEngine.resetPersistentState()
        _ = runParity("add-remove", build: buildSimpleTree, steps: [
            ("initial", nil),
            ("no change", nil),
            ("pin a", { tree in addPin(tree, child(tree, "a"), top: 0) }),
            ("pin b", { tree in addPin(tree, child(tree, "b"), top: 40) }),
            ("no change", nil),
            ("remove a height", { tree in
                let a = child(tree, "a")
                removeConstraint(a, a.constraints.last!)
            }),
            ("change a left constant", { tree in
                let a = child(tree, "a")
                a.constraints[0].constant = 24
            }),
        ])
    }

    // 2. Changing a priority (row replacement + strength change).
    do {
        LegacyLayoutEngine.resetPersistentState()
        _ = runParity("priority", build: { tree in
            buildSimpleTree(tree)
        }, steps: [
            ("initial", nil),
            ("pin a", { tree in addPin(tree, child(tree, "a"), top: 0) }),
            ("optional width a", { tree in
                let a = child(tree, "a")
                let width = makeConstraint(a, .width, .equal, nil, .notAnAttribute, 50, priority: 500)
                a.constraints.append(width)
            }),
            ("raise width priority", { tree in
                let a = child(tree, "a")
                a.constraints.last!.priority = 900
            }),
            ("no change", nil),
        ])
    }

    // 3. Constant changes on a fully determined layout.
    do {
        LegacyLayoutEngine.resetPersistentState()
        _ = runParity("constants", build: { tree in
            buildSimpleTree(tree)
            let a = child(tree, "a")
            addPin(tree, a, top: 0)
        }, steps: [
            ("initial", nil),
            ("move a down", { tree in
                let a = child(tree, "a")
                a.constraints[2].constant = 100
            }),
            ("move a left", { tree in
                let a = child(tree, "a")
                a.constraints[0].constant = 40
            }),
            ("no change", nil),
            ("no change", nil),
        ])
    }

    // 4. Reparenting a view (structural change -> rebuild, then incremental).
    do {
        LegacyLayoutEngine.resetPersistentState()
        _ = runParity("reparent", build: { tree in
            buildSimpleTree(tree)
            let a = child(tree, "a")
            let b = child(tree, "b")
            addPin(tree, a, top: 0)
            addPin(tree, b, top: 40)
            // A wrapper view holding b after the reparent.
            let wrapper = FakeItem("wrapper", frame: CGRect(x: 0, y: 200, width: 320, height: 100))
            tree.add(wrapper, to: tree.root)
            wrapper.constraints.append(makeConstraint(wrapper, .left, .equal, tree.root, .left, 0))
            wrapper.constraints.append(makeConstraint(wrapper, .top, .equal, tree.root, .top, 200))
            wrapper.constraints.append(makeConstraint(wrapper, .width, .equal, nil, .notAnAttribute, 320))
            wrapper.constraints.append(makeConstraint(wrapper, .height, .equal, nil, .notAnAttribute, 100))
        }, steps: [
            ("initial", nil),
            ("reparent b into wrapper", { tree in
                let b = child(tree, "b")
                let wrapper = tree.items.first { $0.label == "wrapper" }!
                tree.reparent(b, to: wrapper)
            }),
            ("no change", nil),
            ("reparent b back", { tree in
                let b = child(tree, "b")
                tree.reparent(b, to: tree.root)
            }),
            ("no change", nil),
        ])
    }

    // 5. Removing a view (structural change).
    do {
        LegacyLayoutEngine.resetPersistentState()
        _ = runParity("remove-view", build: { tree in
            buildSimpleTree(tree)
            addPin(tree, child(tree, "a"), top: 0)
            addPin(tree, child(tree, "b"), top: 40)
        }, steps: [
            ("initial", nil),
            ("remove b", { tree in tree.remove(child(tree, "b")) }),
            ("no change", nil),
        ])
    }

    // 6. Multiple roots share one engine but keep separate solvers.
    do {
        LegacyLayoutEngine.resetPersistentState()
        let engine = LegacyLayoutEngine()
        let other = LegacyLayoutEngine()
        other.usesPersistentSolver = false
        func makeRoot(_ label: String) -> Tree {
            let tree = Tree(root: FakeItem("root", frame: CGRect(x: 0, y: 0, width: 320, height: 480)))
            let item = FakeItem("item", frame: CGRect(x: 0, y: 0, width: 100, height: 20))
            tree.add(item, to: tree.root)
            addPin(tree, item, top: 0)
            return tree
        }
        let treeA = makeRoot("a")
        let treeB = makeRoot("b")
        let treeC = makeRoot("c")
        let treeD = makeRoot("d")
        var ok = true
        for pass in 0..<3 {
            if pass == 1 {
                treeA.items[1].constraints[0].constant = 12
                treeC.items[1].constraints[0].constant = 12
            }
            for (tree, reference) in [(treeA, treeC), (treeB, treeD)] {
                let a = engine.layout(tree.root)
                let b = other.layout(reference.root)
                for problem in differences(snapshot(tree, a), snapshot(reference, b)) {
                    harnessFailures += 1
                    ok = false
                    fputs("FAIL: multiple-roots pass \(pass): \(problem)\n", stderr)
                }
            }
        }
        check(ok, "multiple roots disagree")
        check(LegacyLayoutEngine.persistentSolverCount >= 2, "expected one persistent solver per root")
        print("parity multiple-roots: solvers=\(LegacyLayoutEngine.persistentSolverCount) " + (ok ? "OK" : "FAILED"))
    }

    // 7. Autoresizing translation with a root resize and steady state.
    do {
        LegacyLayoutEngine.resetPersistentState()
        func build(_ tree: Tree) {
            let view = FakeItem("view", frame: CGRect(x: 20, y: 30, width: 100, height: 50))
            view.translates = true
            view.autosizingRef = LegacyAutoresizingReference(
                frame: CGRect(x: 20, y: 30, width: 100, height: 50),
                superviewSize: CGSize(width: 320, height: 480))
            tree.add(view, to: tree.root)
        }
        _ = runParity("autoresizing", build: build, steps: [
            ("initial", nil),
            ("no change", nil),
            ("root resize", { tree in
                tree.root.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
            }),
            ("no change", nil),
        ])
    }

    // 8. Layout-guide participation: the guide is represented by a hidden proxy
    //    item in the tree, exactly like the UIKit bridge does.
    do {
        LegacyLayoutEngine.resetPersistentState()
        _ = runParity("layout-guide", build: { tree in
            let owner = FakeItem("owner", frame: CGRect(x: 0, y: 0, width: 300, height: 200))
            tree.add(owner, to: tree.root)
            owner.constraints.append(makeConstraint(owner, .left, .equal, tree.root, .left, 0))
            owner.constraints.append(makeConstraint(owner, .top, .equal, tree.root, .top, 0))
            owner.constraints.append(makeConstraint(owner, .width, .equal, nil, .notAnAttribute, 300))
            owner.constraints.append(makeConstraint(owner, .height, .equal, nil, .notAnAttribute, 200))
            // The guide's proxy view.
            let proxy = FakeItem("guide", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            tree.add(proxy, to: owner)
            proxy.constraints.append(makeConstraint(proxy, .left, .equal, owner, .left, 16))
            proxy.constraints.append(makeConstraint(proxy, .right, .equal, owner, .right, -16))
            proxy.constraints.append(makeConstraint(proxy, .top, .equal, owner, .top, 8))
            proxy.constraints.append(makeConstraint(proxy, .height, .equal, nil, .notAnAttribute, 44))
            // A view pinned to the guide.
            let content = FakeItem("content", frame: CGRect(x: 0, y: 0, width: 50, height: 20))
            tree.add(content, to: owner)
            content.constraints.append(makeConstraint(content, .left, .equal, proxy, .left, 0))
            content.constraints.append(makeConstraint(content, .top, .equal, proxy, .top, 0))
            content.constraints.append(makeConstraint(content, .width, .equal, proxy, .width, 0))
            content.constraints.append(makeConstraint(content, .height, .equal, proxy, .height, 0))
        }, steps: [
            ("initial", nil),
            ("no change", nil),
        ])
    }

    // 9. Intrinsic content size and hugging priority changes.
    do {
        LegacyLayoutEngine.resetPersistentState()
        func build(_ tree: Tree) {
            let label = FakeItem("label", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
            label.intrinsicSize = CGSize(width: 80, height: 20)
            tree.add(label, to: tree.root)
            label.constraints.append(makeConstraint(label, .centerX, .equal, tree.root, .centerX, 0))
            label.constraints.append(makeConstraint(label, .centerY, .equal, tree.root, .centerY, 0))
        }
        _ = runParity("intrinsic", build: build, steps: [
            ("initial", nil),
            ("grow intrinsic", { tree in
                let label = tree.items.first { $0.label == "label" }!
                label.intrinsicSize = CGSize(width: 120, height: 40)
            }),
            ("hug harder", { tree in
                let label = tree.items.first { $0.label == "label" }!
                label.huggingX = 700
            }),
            ("no change", nil),
        ])
    }

    // 10. Statistics contract: a first pass rebuilds, clean passes are cached.
    do {
        LegacyLayoutEngine.resetPersistentState()
        LegacyLayoutStats.reset()
        let engine = LegacyLayoutEngine()
        let tree = Tree(root: FakeItem("root", frame: CGRect(x: 0, y: 0, width: 320, height: 480)))
        let item = FakeItem("item", frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        tree.add(item, to: tree.root)
        addPin(tree, item, top: 0)
        _ = engine.layout(tree.root)
        let afterFirst = LegacyLayoutStats.snapshot
        _ = engine.layout(tree.root)
        _ = engine.layout(tree.root)
        let afterSteady = LegacyLayoutStats.snapshot
        checkEqual(afterFirst.rebuilds, 1, "first pass must rebuild")
        check(afterFirst.cachedPasses == 0, "first pass must not be cached")
        checkEqual(afterSteady.cachedPasses, 2, "clean passes must be served from the cached result")
        checkEqual(afterSteady.solves, 1, "clean passes must not touch the solver")
        print("stats contract: first(rebuilt=\(afterFirst.rebuilds), cached=\(afterFirst.cachedPasses)) " +
              "steady(cached=\(afterSteady.cachedPasses), solves=\(afterSteady.solves)) OK")
    }

    finishHarness()
}

main()
