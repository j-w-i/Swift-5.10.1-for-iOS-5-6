import Foundation
import CoreGraphics

func expectSize(_ actual: CGSize, _ expected: CGSize, _ label: String) {
    precondition(abs(actual.width - expected.width) < 0.001 && abs(actual.height - expected.height) < 0.001,
                 "\(label): \(actual) != \(expected)")
}

let root = FakeItem("fitting root", frame: CGRect(x: 17, y: 29, width: 300, height: 400))
let child = FakeItem("label", frame: .zero, parent: root)
child.intrinsicSize = CGSize(width: 90, height: 21)
root.children = [child]
root.constraints = [
    makeConstraint(child, .left, .equal, root, .left, 8),
    makeConstraint(child, .right, .equal, root, .right, -8),
    makeConstraint(child, .top, .equal, root, .top, 4),
    makeConstraint(child, .bottom, .equal, root, .bottom, -6)
]

let original = root.frame
let fit = LegacyLayoutSolver(root: root, direction: .leftToRight)
fit.fittingProposal = (width: 240, height: nil)
let result = fit.solve(writingFrames: false)
expectSize(fit.fittedRootSize, CGSize(width: 240, height: 31), "fixed width, fitting height")
precondition(root.frame == original && child.frame == .zero, "measurement mutated live geometry")
expectSize(result.frames[ObjectIdentifier(root)]!.size, CGSize(width: 240, height: 31), "result root size")

let both = LegacyLayoutSolver(root: root, direction: .leftToRight)
both.fittingProposal = (width: nil, height: nil)
_ = both.solve(writingFrames: false)
expectSize(both.fittedRootSize, CGSize(width: 106, height: 31), "both fitting axes")

let ordinary = LegacyLayoutSolver(root: root, direction: .leftToRight)
let unchanged = ordinary.solve(writingFrames: false)
expectSize(unchanged.frames[ObjectIdentifier(root)]!.size, original.size, "ordinary root unchanged")
print("PASS: fitting size, edge insets, non-mutating measurement, ordinary layout unchanged")

let priorityRoot = FakeItem("priority root", frame: CGRect(x: 0, y: 0, width: 200, height: 200))
let priorityChild = FakeItem("priority child", frame: .zero, parent: priorityRoot)
priorityRoot.children = [priorityChild]
let defining = makeConstraint(priorityChild, .width, .equal, nil, .notAnAttribute, 80)
let preferred = makeConstraint(priorityChild, .width, .equal, nil, .notAnAttribute, 25, priority: 750)
priorityRoot.constraints = [defining, preferred]
let engine = LegacyLayoutEngine()
_ = engine.layout(priorityRoot)
defining.priority = 1
let incremental = engine.layout(priorityRoot)
let rebuilt = LegacyLayoutEngine().solve(priorityRoot)
let key = ObjectIdentifier(priorityChild)
precondition(abs(incremental.frames[key]!.width - 25) < 0.001, "required-to-optional retained stale substitution")
precondition(incremental.frames[key] == rebuilt.frames[key], "required-to-optional differs from fresh rebuild")
print("PASS: required-to-optional mutation invalidates folded presolve value")

// Chat-shaped hierarchy: a root-pinned container/scroll region and an independently measured stack leaf.
let chat = FakeItem("controller", frame: CGRect(x: 0, y: 0, width: 320, height: 480))
let container = FakeItem("container", frame: .zero, parent: chat)
let scroll = FakeItem("scroll", frame: .zero, parent: container)
let stack = FakeItem("independent stack", frame: .zero, parent: scroll)
chat.children = [container]; container.children = [scroll]; scroll.children = [stack]
func pin(_ child: FakeItem, _ parent: FakeItem, top: CGFloat = 0, inset: CGFloat = 0) -> [RRLayoutConstraint] {
    [makeConstraint(child, .left, .equal, parent, .left, inset),
     makeConstraint(child, .right, .equal, parent, .right, -inset),
     makeConstraint(child, .top, .equal, parent, .top, top),
     makeConstraint(child, .bottom, .equal, parent, .bottom, -top)]
}
chat.constraints = pin(container, chat, top: 20)
container.constraints = pin(scroll, container)
scroll.constraints = pin(stack, scroll, top: 20, inset: 10)
let chatEngine = LegacyLayoutEngine()
_ = chatEngine.layout(chat)
expectSize(container.frame.size, CGSize(width: 320, height: 440), "chat container initial")
expectSize(stack.frame.size, CGSize(width: 300, height: 400), "stack outer frame initial")
for height: CGFloat in [50, 1200, 0, 340] {
    stack.intrinsicSize = CGSize(width: -1, height: height)
    _ = chatEngine.layout(chat)
    expectSize(container.frame.size, CGSize(width: 320, height: 440), "fitting cannot shrink pinned parent")
    expectSize(stack.frame.size, CGSize(width: 300, height: 400), "required outer edges beat intrinsic")
}
// Installing input-like descendants must not collapse its previously laid out parent.
let input = FakeItem("input", frame: .zero, parent: container)
container.children.append(input)
container.constraints += [makeConstraint(input, .width, .equal, container, .width, -20),
                          makeConstraint(input, .centerX, .equal, container, .centerX, 0),
                          makeConstraint(input, .bottom, .equal, container, .bottom, -20)]
input.intrinsicSize = CGSize(width: -1, height: 44)
_ = chatEngine.layout(chat)
expectSize(container.frame.size, CGSize(width: 320, height: 440), "input insertion keeps parent frame")
expectSize(input.frame.size, CGSize(width: 300, height: 44), "input natural height")
print("PASS: pinned chat parent survives stack fitting changes and input insertion")
