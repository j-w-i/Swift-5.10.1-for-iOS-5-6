//
//  AutoLayoutTestSupport.swift
//  LegacyAutoLayout host test harness
//
//  Shared fakes and comparison helpers for the engine parity tests and the
//  performance benchmark. Host-only: not compiled into the UIKit overlay (the
//  build script stages only Cassowary/, LegacyAutoLayout/ and Runtime/).
//

import Foundation
import CoreGraphics

/// A minimal `LegacyLayoutItem` tree for host tests.
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
    var firstBaselineOffset: CGFloat?
    var lastBaselineOffset: CGFloat?
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
    var layoutFirstBaselineOffsetFromTop: CGFloat? { firstBaselineOffset }
    var layoutLastBaselineOffsetFromBottom: CGFloat? { lastBaselineOffset }
}

/// Builds a constraint with the common multiplier-1 form.
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

/// A tree plus a stable item order for comparisons.
final class Tree {
    let root: FakeItem
    private(set) var items: [FakeItem] = []

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

/// Frames from one engine pass.
struct PassSnapshot {
    var frames: [String: CGRect]
    var brokenCount: Int
}

func snapshot(_ tree: Tree, _ result: LegacyLayoutResult) -> PassSnapshot {
    var frames: [String: CGRect] = [:]
    for item in tree.items {
        frames[item.label] = item.frame
    }
    return PassSnapshot(frames: frames, brokenCount: result.brokenConstraints.count)
}

/// Compares two snapshots with a small tolerance; returns a difference list.
func differences(_ a: PassSnapshot, _ b: PassSnapshot, tolerance: CGFloat = 1e-6) -> [String] {
    var problems: [String] = []
    if a.brokenCount != b.brokenCount {
        problems.append("broken constraint count \(a.brokenCount) != \(b.brokenCount)")
    }
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

var harnessFailures = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    guard !condition else { return }
    harnessFailures += 1
    fputs("FAIL: \(message())\n", stderr)
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: @autoclosure () -> String) {
    check(lhs == rhs, "\(message()): \(lhs) != \(rhs)")
}

/// Runs one scenario against the persistent engine and the rebuild engine and
/// compares frames after every step. `build` is called twice to produce two
/// identical trees; `steps` contains one mutation (or nil for "no change") per
/// layout pass, applied to both trees.
func runParity(_ name: String,
               build: (Tree) -> Void,
               steps: [(String, ((Tree) -> Void)?)]) -> Bool {
    let treeA = Tree(root: FakeItem("root", frame: CGRect(x: 0, y: 0, width: 320, height: 480)))
    let treeB = Tree(root: FakeItem("root", frame: CGRect(x: 0, y: 0, width: 320, height: 480)))
    build(treeA)
    build(treeB)
    let persistent = LegacyLayoutEngine()
    let rebuild = LegacyLayoutEngine()
    rebuild.usesPersistentSolver = false
    let failuresBefore = harnessFailures
    let startPass = LegacyLayoutStats.snapshot
    for (pass, step) in steps.enumerated() {
        step.1?(treeA)
        step.1?(treeB)
        let a = persistent.layout(treeA.root)
        let b = rebuild.layout(treeB.root)
        for problem in differences(snapshot(treeA, a), snapshot(treeB, b)) {
            harnessFailures += 1
            fputs("FAIL: \(name) pass \(pass + 1) (\(step.0)): \(problem)\n", stderr)
        }
    }
    let stats = LegacyLayoutStats.snapshot
    print("parity \(name): steps=\(steps.count) " +
          "rebuilds=\(stats.rebuilds - startPass.rebuilds) " +
          "solves=\(stats.solves - startPass.solves) " +
          "cached=\(stats.cachedPasses - startPass.cachedPasses) " +
          "constraints=\(stats.constraintsInstalled - startPass.constraintsInstalled) " +
          (harnessFailures == failuresBefore ? "OK" : "FAILED"))
    return harnessFailures == failuresBefore
}

func finishHarness() -> Never {
    if harnessFailures == 0 {
        print("PASS: all Auto Layout engine parity tests")
        exit(0)
    }
    print("FAIL: \(harnessFailures) parity failures")
    exit(1)
}
