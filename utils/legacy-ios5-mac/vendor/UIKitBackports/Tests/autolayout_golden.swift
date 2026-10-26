//
//  autolayout_golden.swift
//  LegacyAutoLayout golden-frame harness
//
//  Runs a fixed scenario script and prints every item's frame after every pass.
//  The same file is compiled against the current engine and against the engine
//  from git HEAD; the runner compares the two outputs within a tolerance. This is
//  the "equal to the previous rebuild-per-pass outcomes" evidence.
//
//  Build with -DNEW_ENGINE for the current (persistent) engine; the HEAD build
//  omits the flag because the engine struct differs.
//

import Foundation
import CoreGraphics

final class FakeItem: LegacyLayoutItem {
    weak var parent: FakeItem?
    var children: [FakeItem] = []
    var frame: CGRect
    var constraints: [RRLayoutConstraint] = []
    var translates: Bool = false
    var autosizingRef: LegacyAutoresizingReference?
    var intrinsicSize = CGSize(width: -1, height: -1)
    var huggingX: Float = 250
    var huggingY: Float = 250
    var compressionX: Float = 750
    var compressionY: Float = 750
    let label: String

    init(_ label: String, frame: CGRect, parent: FakeItem? = nil) {
        self.label = label
        self.frame = frame
        self.parent = parent
    }

    var layoutSuperitem: LegacyLayoutItem? { parent }
    var layoutSubitems: [LegacyLayoutItem] { children }
    var layoutFrame: CGRect { frame }
    func layoutSetFrame(_ newFrame: CGRect) { frame = newFrame }
    var layoutConstraints: [RRLayoutConstraint] { constraints }
    var layoutTranslatesAutoresizingMaskIntoConstraints: Bool { translates }
    var layoutAutoresizingMask: RRAutoresizingMask { .none }
    var layoutAutoresizingReference: LegacyAutoresizingReference? { autosizingRef }
    func layoutUpdateAutoresizingReference(_ reference: LegacyAutoresizingReference) { autosizingRef = reference }
    var layoutIntrinsicContentSize: CGSize { intrinsicSize }
    func layoutContentHuggingPriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        axis == .horizontal ? huggingX : huggingY
    }
    func layoutContentCompressionResistancePriority(for axis: RRLayoutAxis) -> RRLayoutPriority {
        axis == .horizontal ? compressionX : compressionY
    }
}

final class Tree {
    let root: FakeItem
    var items: [FakeItem] = []

    init(root: FakeItem) {
        self.root = root
        self.items = [root]
    }

    @discardableResult
    func add(_ item: FakeItem, to parent: FakeItem) -> FakeItem {
        item.parent = parent
        parent.children.append(item)
        items.append(item)
        return item
    }

    func remove(_ item: FakeItem) {
        item.parent?.children.removeAll { $0 === item }
        item.parent = nil
        items.removeAll { $0 === item }
    }

    func reparent(_ item: FakeItem, to newParent: FakeItem) {
        item.parent?.children.removeAll { $0 === item }
        item.parent = newParent
        newParent.children.append(item)
    }
}

func makeConstraint(_ first: FakeItem,
                    _ attribute: RRLayoutAttribute,
                    _ relation: RRLayoutRelation = .equal,
                    _ second: FakeItem?,
                    _ secondAttribute: RRLayoutAttribute = .notAnAttribute,
                    _ constant: CGFloat,
                    multiplier: CGFloat = 1,
                    priority: Float = 1000) -> RRLayoutConstraint {
    let constraint = RRLayoutConstraint(item: first, attribute: attribute,
                                        relatedBy: relation, toItem: second,
                                        attribute: secondAttribute,
                                        multiplier: multiplier, constant: constant)
    constraint.priority = priority
    return constraint
}

func child(_ tree: Tree, _ label: String) -> FakeItem {
    tree.items.first { $0.label == label }!
}

func addPin(_ tree: Tree, _ item: FakeItem, top: CGFloat) {
    item.constraints.append(makeConstraint(item, .left, .equal, tree.root, .left, 8))
    item.constraints.append(makeConstraint(item, .right, .equal, tree.root, .right, -8))
    item.constraints.append(makeConstraint(item, .top, .equal, tree.root, .top, top))
    item.constraints.append(makeConstraint(item, .height, .equal, nil, .notAnAttribute, 20))
}

func printPass(_ name: String, _ step: Int, _ tree: Tree) {
    for item in tree.items {
        print(String(format: "%@|%d|%@|%.9f|%.9f|%.9f|%.9f",
                     name, step, item.label,
                     item.frame.minX, item.frame.minY,
                     item.frame.width, item.frame.height))
    }
}

func runScenario(_ name: String,
                 build: (Tree) -> Void,
                 steps: [((Tree) -> Void)?]) {
    let tree = Tree(root: FakeItem("root", frame: CGRect(x: 0, y: 0, width: 320, height: 480)))
    build(tree)
    #if NEW_ENGINE
    let engine = LegacyLayoutEngine()
    #else
    let engine = LegacyLayoutEngine()
    #endif
    for (step, mutation) in steps.enumerated() {
        mutation?(tree)
        _ = engine.layout(tree.root)
        printPass(name, step, tree)
    }
}

// MARK: - Scenarios (mirroring the parity suite)

runScenario("add-remove", build: { tree in
    let a = FakeItem("a", frame: CGRect(x: 0, y: 0, width: 100, height: 20))
    let b = FakeItem("b", frame: CGRect(x: 0, y: 40, width: 100, height: 20))
    tree.add(a, to: tree.root)
    tree.add(b, to: tree.root)
}, steps: [
    nil,
    { tree in addPin(tree, child(tree, "a"), top: 0) },
    { tree in addPin(tree, child(tree, "b"), top: 40) },
    nil,
    { tree in
        let a = child(tree, "a")
        let last = a.constraints.last
        a.constraints.removeAll { $0 === last }
    },
    { tree in child(tree, "a").constraints[0].constant = 24 },
])

runScenario("priority", build: { tree in
    let a = FakeItem("a", frame: CGRect(x: 0, y: 0, width: 100, height: 20))
    let b = FakeItem("b", frame: CGRect(x: 0, y: 40, width: 100, height: 20))
    tree.add(a, to: tree.root)
    tree.add(b, to: tree.root)
}, steps: [
    nil,
    { tree in addPin(tree, child(tree, "a"), top: 0) },
    { tree in
        let a = child(tree, "a")
        a.constraints.append(makeConstraint(a, .width, .equal, nil, .notAnAttribute, 50, priority: 500))
    },
    { tree in child(tree, "a").constraints.last!.priority = 900 },
    nil,
])

runScenario("reparent", build: { tree in
    let a = FakeItem("a", frame: CGRect(x: 0, y: 0, width: 100, height: 20))
    let b = FakeItem("b", frame: CGRect(x: 0, y: 40, width: 100, height: 20))
    tree.add(a, to: tree.root)
    tree.add(b, to: tree.root)
    addPin(tree, a, top: 0)
    addPin(tree, b, top: 40)
    let wrapper = FakeItem("wrapper", frame: CGRect(x: 0, y: 200, width: 320, height: 100))
    tree.add(wrapper, to: tree.root)
    wrapper.constraints.append(makeConstraint(wrapper, .left, .equal, tree.root, .left, 0))
    wrapper.constraints.append(makeConstraint(wrapper, .top, .equal, tree.root, .top, 200))
    wrapper.constraints.append(makeConstraint(wrapper, .width, .equal, nil, .notAnAttribute, 320))
    wrapper.constraints.append(makeConstraint(wrapper, .height, .equal, nil, .notAnAttribute, 100))
}, steps: [
    nil,
    { tree in tree.reparent(child(tree, "b"), to: child(tree, "wrapper")) },
    nil,
    { tree in tree.reparent(child(tree, "b"), to: tree.root) },
])

runScenario("remove-view", build: { tree in
    let a = FakeItem("a", frame: CGRect(x: 0, y: 0, width: 100, height: 20))
    let b = FakeItem("b", frame: CGRect(x: 0, y: 40, width: 100, height: 20))
    tree.add(a, to: tree.root)
    tree.add(b, to: tree.root)
    addPin(tree, a, top: 0)
    addPin(tree, b, top: 40)
}, steps: [
    nil,
    { tree in tree.remove(child(tree, "b")) },
    nil,
])

runScenario("autoresizing", build: { tree in
    let view = FakeItem("view", frame: CGRect(x: 20, y: 30, width: 100, height: 50))
    view.translates = true
    view.autosizingRef = LegacyAutoresizingReference(
        frame: CGRect(x: 20, y: 30, width: 100, height: 50),
        superviewSize: CGSize(width: 320, height: 480))
    tree.add(view, to: tree.root)
}, steps: [
    nil,
    nil,
    { tree in tree.root.frame = CGRect(x: 0, y: 0, width: 400, height: 600) },
    nil,
])

runScenario("intrinsic", build: { tree in
    let label = FakeItem("label", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    label.intrinsicSize = CGSize(width: 80, height: 20)
    tree.add(label, to: tree.root)
    label.constraints.append(makeConstraint(label, .centerX, .equal, tree.root, .centerX, 0))
    label.constraints.append(makeConstraint(label, .centerY, .equal, tree.root, .centerY, 0))
}, steps: [
    nil,
    { tree in child(tree, "label").intrinsicSize = CGSize(width: 120, height: 40) },
    { tree in child(tree, "label").huggingX = 700 },
    nil,
])

runScenario("guide", build: { tree in
    let owner = FakeItem("owner", frame: CGRect(x: 0, y: 0, width: 300, height: 200))
    tree.add(owner, to: tree.root)
    owner.constraints.append(makeConstraint(owner, .left, .equal, tree.root, .left, 0))
    owner.constraints.append(makeConstraint(owner, .top, .equal, tree.root, .top, 0))
    owner.constraints.append(makeConstraint(owner, .width, .equal, nil, .notAnAttribute, 300))
    owner.constraints.append(makeConstraint(owner, .height, .equal, nil, .notAnAttribute, 200))
    let proxy = FakeItem("guide", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    tree.add(proxy, to: owner)
    proxy.constraints.append(makeConstraint(proxy, .left, .equal, owner, .left, 16))
    proxy.constraints.append(makeConstraint(proxy, .right, .equal, owner, .right, -16))
    proxy.constraints.append(makeConstraint(proxy, .top, .equal, owner, .top, 8))
    proxy.constraints.append(makeConstraint(proxy, .height, .equal, nil, .notAnAttribute, 44))
    let content = FakeItem("content", frame: CGRect(x: 0, y: 0, width: 50, height: 20))
    tree.add(content, to: owner)
    content.constraints.append(makeConstraint(content, .left, .equal, proxy, .left, 0))
    content.constraints.append(makeConstraint(content, .top, .equal, proxy, .top, 0))
    content.constraints.append(makeConstraint(content, .width, .equal, proxy, .width, 0))
    content.constraints.append(makeConstraint(content, .height, .equal, proxy, .height, 0))
}, steps: [nil, nil])

exit(0)
