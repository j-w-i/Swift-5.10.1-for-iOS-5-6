// Chat hierarchy differential: the exact constraint shape Neocord2's chat screen builds
// (controller view > container > scroll view > vertical message chain), solved by (a) the legacy
// iOS 5 engine and (b) the simulator's native Auto Layout. Prints "frame <name> x y w h" lines.
import UIKit
import Foundation

final class IntrinsicView: UIView {
    var h: CGFloat = 40
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: h < 0 ? UIView.noIntrinsicMetric : h) }
}

@MainActor
func runChat(mode: String, messages: Int, variant: String) {
    let legacy = (mode == "legacy")
    if legacy { LegacyAutoLayout.installForLegacyNames() }
    let heights: [CGFloat] = variant == "tall" ? [300, 220, 18, 410, 64, 150, 33] : [50, 46, 12, 74, 30, 62, 24]
    func make(_ name: String) -> UIView { let v = IntrinsicView(frame: .zero); v.accessibilityIdentifier = name; return v }

    let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let container = make("container"), scroll = UIScrollView(frame: .zero), stack = make("stack")
    scroll.accessibilityIdentifier = "scroll"
    root.addSubview(container); container.addSubview(scroll); scroll.addSubview(stack)
    var kids: [IntrinsicView] = []
    for i in 0..<messages {
        let m = make("m\(i)") as! IntrinsicView; m.h = variant == "label" ? -1 : heights[i % heights.count]; stack.addSubview(m); kids.append(m)
        // The legacy engine reads the backport's own property, not a subclass override of the native getter.
        if legacy && m.h >= 0 { m.legacyIntrinsicContentSize = CGSize(width: -1, height: m.h) }
    }
    // "label" variant: each message holds a multiline label pinned to its edges; the label's height depends on width.
    var labels: [UILabel] = []
    if variant == "label" {
        let words = ["short", "a medium length message here", "a considerably longer message that will certainly need to wrap across several lines at this width", "ok"]
        for (i, m) in kids.enumerated() {
            let l = UILabel(frame: .zero); l.numberOfLines = 0; l.font = UIFont.systemFont(ofSize: 15)
            l.text = words[i % words.count]; l.accessibilityIdentifier = "l\(i)"
            if legacy { l.legacyTranslatesAutoresizingMaskIntoConstraints = false; l.preferredMaxLayoutWidth = 280 } else { l.translatesAutoresizingMaskIntoConstraints = false; l.preferredMaxLayoutWidth = 280 }
            m.addSubview(l); labels.append(l)
            if legacy { m.legacyIntrinsicContentSize = CGSize(width: -1, height: -1) }
        }
    }
    let all: [UIView] = [container, scroll, stack] + kids + labels
    func add(_ owner: UIView, _ a: UIView, _ x: NSLayoutConstraint.Attribute, _ b: UIView?, _ y: NSLayoutConstraint.Attribute, _ c: CGFloat) {
        if legacy {
            let rx = RRLayoutAttribute(rawValue: x.rawValue)!, ry = RRLayoutAttribute(rawValue: y.rawValue)!
            owner.legacyAddConstraint(RRLayoutConstraint(item: a, attribute: rx, relatedBy: .equal, toItem: b, attribute: ry, multiplier: 1, constant: c))
        } else {
            owner.addConstraint(NSLayoutConstraint(item: a, attribute: x, relatedBy: .equal, toItem: b, attribute: y, multiplier: 1, constant: c))
        }
    }
    for v in all { if legacy { v.legacyTranslatesAutoresizingMaskIntoConstraints = false } else { v.translatesAutoresizingMaskIntoConstraints = false } }
    func pin(_ child: UIView, _ parent: UIView, top: CGFloat, side: CGFloat, owner: UIView) {
        add(owner, child, .top, parent, .top, top); add(owner, child, .leading, parent, .leading, side)
        add(owner, child, .trailing, parent, .trailing, -side); add(owner, child, .bottom, parent, .bottom, -top)
    }
    // TextViewController.setupConstraints()
    pin(stack, scroll, top: 20, side: 10, owner: scroll); add(scroll, stack, .centerX, scroll, .centerX, 0)
    pin(scroll, container, top: 0, side: 0, owner: container)
    add(container, scroll, .centerX, container, .centerX, 0); add(container, scroll, .centerY, container, .centerY, 0)
    add(root, container, .top, root, .top, 20); add(root, container, .trailing, root, .trailing, 0)
    add(root, container, .leading, root, .leading, 0); add(root, container, .bottom, root, .bottom, 0)
    // OAStackView vertical fill, spacing 12: first.top = stack.top, next.top = prev.bottom + 12, last.bottom = stack.bottom
    for (i, m) in kids.enumerated() {
        add(stack, m, .leading, stack, .leading, 0); add(stack, m, .trailing, stack, .trailing, 0)
        if i == 0 { add(stack, m, .top, stack, .top, 0) } else { add(stack, m, .top, kids[i - 1], .bottom, 12) }
    }
    if let last = kids.last { add(stack, last, .bottom, stack, .bottom, 0) }

    if variant == "label" {
        for (i, m) in kids.enumerated() {
            let l = labels[i]
            add(m, l, .top, m, .top, 4); add(m, l, .leading, m, .leading, 8); add(m, l, .trailing, m, .trailing, -8); add(m, l, .bottom, m, .bottom, -4)
        }
    }
    if variant == "hidden" { for i in stride(from: 1, to: kids.count, by: 3) { kids[i].isHidden = true } }
    if variant == "pinned" && kids.count > 2 {
        // an optional (priority 750) preferred height on one message, below its intrinsic compression resistance
        if legacy { let c = RRLayoutConstraint(item: kids[2], attribute: .height, relatedBy: .equal, toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 90); c.priority = 500; stack.legacyAddConstraint(c) }
        else { let c = NSLayoutConstraint(item: kids[2], attribute: .height, relatedBy: .equal, toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 90); c.priority = UILayoutPriority(500); stack.addConstraint(c) }
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<3 { root.setNeedsLayout(); root.layoutIfNeeded(); for v in all { v.setNeedsLayout(); v.layoutIfNeeded() } }
    print("time_ms \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))")
    func f(_ v: UIView) -> String { let r = v.frame; return "\(r.minX) \(r.minY) \(r.width) \(r.height)" }
    print("frame container \(f(container))"); print("frame scroll \(f(scroll))"); print("frame stack \(f(stack))")
    for (i, m) in kids.enumerated() { print("frame m\(i) \(f(m))") }
    for (i, l) in labels.enumerated() { print("frame l\(i) \(f(l))") }
    print("contentSize \(scroll.contentSize.width) \(scroll.contentSize.height)")
}

final class ZeroIntrinsicView: UIView {
    override var intrinsicContentSize: CGSize { CGSize(width: 0, height: 0) }
}

final class InputLikeView: UIView {
    let tv = UITextView(frame: .zero)
    override var intrinsicContentSize: CGSize {
        let w = tv.bounds.width > 0 ? tv.bounds.width : 100
        let size = tv.sizeThatFits(CGSize(width: w, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: max(40, min(size.height, 400)))
    }
}

@MainActor
func runInput(mode: String, text: String, flags: String) {
    // InputView: self pinned bottom -20 / centerX / width = container.width - 20 inside a container;
    // textInputBackground pinned to self top/bottom with a >= 40 height; textView pinned to that background.
    let legacy = (mode == "legacy")
    if legacy { LegacyAutoLayout.installForLegacyNames() }
    let container = UIView(frame: CGRect(x: 0, y: 20, width: 320, height: 460))
    let input = InputLikeView(frame: .zero)
    let bg = UIView(frame: .zero), send = UIButton(type: .custom), attach = UIButton(type: .custom)
    container.addSubview(input); input.addSubview(bg); input.addSubview(send); input.addSubview(attach); bg.addSubview(input.tv)
    input.tv.text = text; input.tv.font = UIFont.systemFont(ofSize: 18); input.tv.isScrollEnabled = false
    func off(_ v: UIView) { if legacy { v.legacyTranslatesAutoresizingMaskIntoConstraints = false } else { v.translatesAutoresizingMaskIntoConstraints = false } }
    for v in [input, bg, send, attach, input.tv] as [UIView] { off(v) }
    enum R { case eq, ge }
    func add(_ owner: UIView, _ a: UIView, _ x: NSLayoutConstraint.Attribute, _ r: R, _ b: UIView?, _ y: NSLayoutConstraint.Attribute, _ c: CGFloat) {
        if legacy {
            owner.legacyAddConstraint(RRLayoutConstraint(item: a, attribute: RRLayoutAttribute(rawValue: x.rawValue)!, relatedBy: r == .eq ? .equal : .greaterThanOrEqual, toItem: b, attribute: RRLayoutAttribute(rawValue: y.rawValue)!, multiplier: 1, constant: c))
        } else {
            owner.addConstraint(NSLayoutConstraint(item: a, attribute: x, relatedBy: r == .eq ? .equal : .greaterThanOrEqual, toItem: b, attribute: y, multiplier: 1, constant: c))
        }
    }
    let n = NSLayoutConstraint.Attribute.notAnAttribute
    // setupInputView
    add(container, input, .bottom, .eq, container, .bottom, -20); add(container, input, .centerX, .eq, container, .centerX, 0); add(container, input, .width, .eq, container, .width, -20)
    // setupConstraints
    add(input, send, .centerY, .eq, input.tv, .centerY, 0); add(input, send, .trailing, .eq, input, .trailing, -6); add(input, send, .height, .eq, nil, n, 40); add(input, send, .width, .eq, nil, n, 40)
    add(input, attach, .leading, .eq, input, .leading, 6); add(input, attach, .centerY, .eq, input.tv, .centerY, 0); add(input, attach, .height, .eq, nil, n, 40); add(input, attach, .width, .eq, nil, n, 40)
    add(input, bg, .top, .eq, input, .top, 0); add(input, bg, .leading, .eq, attach, .trailing, 6); add(input, bg, .trailing, .eq, send, .leading, -6); add(input, bg, .bottom, .eq, input, .bottom, 0)
    add(input, bg, .height, .ge, nil, n, 40)
    add(bg, input.tv, .top, .eq, bg, .top, 0); add(bg, input.tv, .leading, .eq, bg, .leading, 0); add(bg, input.tv, .trailing, .eq, bg, .trailing, 0); add(bg, input.tv, .bottom, .eq, bg, .bottom, 0)
    // Intentionally NOT copying the override into legacyIntrinsicContentSize: the app only overrides the method.
    if flags.contains("bubble") {
        // BubbleActionView: pinned bottom to input.top - 6, centerX, width; height >= 1 with a child stack pinned to it.
        let bubble = UIView(frame: .zero), bstack: UIView = flags.contains("zeroStack") ? ZeroIntrinsicView(frame: .zero) : UIView(frame: .zero)
        container.addSubview(bubble); bubble.addSubview(bstack); off(bubble); off(bstack)
        if flags.contains("reqStack") {
            // NeoCord2 BubbleActionView: stack hugging + compression resistance .required on the vertical axis.
            if legacy { bstack.legacySetContentHuggingPriority(RRLayoutPriority(1000), for: .vertical); bstack.legacySetContentCompressionResistancePriority(RRLayoutPriority(1000), for: .vertical) }
            else { bstack.setContentHuggingPriority(.required, for: .vertical); bstack.setContentCompressionResistancePriority(.required, for: .vertical) }
        }
        add(container, bubble, .bottom, .eq, input, .top, -6); add(container, bubble, .centerX, .eq, container, .centerX, 0); add(container, bubble, .width, .eq, container, .width, -20)
        add(bubble, bstack, .top, .eq, bubble, .top, 0); add(bubble, bstack, .leading, .eq, bubble, .leading, 0); add(bubble, bstack, .trailing, .eq, bubble, .trailing, 0); add(bubble, bstack, .bottom, .eq, bubble, .bottom, 0)
        add(bubble, bubble, .height, .ge, nil, n, 1)
    }
    if flags.contains("scroll") {
        let sc = UIScrollView(frame: .zero); container.insertSubview(sc, at: 0); off(sc)
        add(container, sc, .top, .eq, container, .top, 0); add(container, sc, .leading, .eq, container, .leading, 0); add(container, sc, .trailing, .eq, container, .trailing, 0); add(container, sc, .bottom, .eq, container, .bottom, 0)
    }
    if flags.contains("bigFrame") { input.frame = CGRect(x: 10, y: 0, width: 300, height: 440); bg.frame = CGRect(x: 52, y: 0, width: 196, height: 440); input.tv.frame = CGRect(x: 0, y: 0, width: 196, height: 440) }
    if flags.contains("once") {
        // What the app does in setupInputView: add, activate constraints, then ONE view.layoutIfNeeded(), then read bounds.
        container.layoutIfNeeded()
        print("once input.bounds.height \(input.bounds.height) frame \(input.frame)")
        exit(0)
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<3 { container.setNeedsLayout(); container.layoutIfNeeded(); for v in [input, bg, input.tv] as [UIView] { v.layoutIfNeeded() } }
    func f(_ v: UIView) -> String { let r = v.frame; return "\(r.minX) \(r.minY) \(r.width) \(r.height)" }
    print("time_ms \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))")
    for v in container.subviews where v !== input { print("frame sub \(f(v)) \(type(of: v))") }
    print("frame input \(f(input))"); print("frame bg \(f(bg))"); print("frame tv \(f(input.tv))"); print("frame send \(f(send))"); print("frame attach \(f(attach))")
}

@MainActor
func runIncremental(mode: String, messages: Int) {
    // Mirrors addMessagesToStack: append one message to the live hierarchy, then layoutIfNeeded, repeatedly.
    let legacy = (mode == "legacy")
    if legacy { LegacyAutoLayout.installForLegacyNames() }
    let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let container = IntrinsicView(frame: .zero), scroll = UIScrollView(frame: .zero), stack = IntrinsicView(frame: .zero)
    container.h = -1; stack.h = -1
    root.addSubview(container); container.addSubview(scroll); scroll.addSubview(stack)
    func add(_ owner: UIView, _ a: UIView, _ x: NSLayoutConstraint.Attribute, _ b: UIView?, _ y: NSLayoutConstraint.Attribute, _ c: CGFloat) {
        if legacy { owner.legacyAddConstraint(RRLayoutConstraint(item: a, attribute: RRLayoutAttribute(rawValue: x.rawValue)!, relatedBy: .equal, toItem: b, attribute: RRLayoutAttribute(rawValue: y.rawValue)!, multiplier: 1, constant: c)) }
        else { owner.addConstraint(NSLayoutConstraint(item: a, attribute: x, relatedBy: .equal, toItem: b, attribute: y, multiplier: 1, constant: c)) }
    }
    for v in [container, scroll, stack] { if legacy { v.legacyTranslatesAutoresizingMaskIntoConstraints = false } else { v.translatesAutoresizingMaskIntoConstraints = false } }
    func pin(_ c: UIView, _ p: UIView, _ top: CGFloat, _ side: CGFloat) {
        add(p, c, .top, p, .top, top); add(p, c, .leading, p, .leading, side); add(p, c, .trailing, p, .trailing, -side); add(p, c, .bottom, p, .bottom, -top)
    }
    pin(stack, scroll, 20, 10); pin(scroll, container, 0, 0)
    add(root, container, .top, root, .top, 20); add(root, container, .leading, root, .leading, 0)
    add(root, container, .trailing, root, .trailing, 0); add(root, container, .bottom, root, .bottom, 0)
    root.layoutIfNeeded()
    var kids: [IntrinsicView] = []; var total = 0.0; var marks: [String] = []; var pinnedBottom: AnyObject? = nil
    for i in 0..<messages {
        let m = IntrinsicView(frame: .zero); m.h = [50, 46, 12, 74, 30][i % 5]; m.accessibilityIdentifier = "m\(i)"
        stack.addSubview(m)
        if legacy { m.legacyTranslatesAutoresizingMaskIntoConstraints = false; if getenv("REQ_HEIGHT") == nil { m.legacyIntrinsicContentSize = CGSize(width: -1, height: m.h) } } else { m.translatesAutoresizingMaskIntoConstraints = false }
        if getenv("REQ_HEIGHT") != nil { add(stack, m, .height, nil, .notAnAttribute, m.h) }
        // replace the old last->stack.bottom pin by chaining (OAStackView re-links the tail on every append)
        add(stack, m, .leading, stack, .leading, 0); add(stack, m, .trailing, stack, .trailing, 0)
        if let prev = kids.last { add(stack, m, .top, prev, .bottom, 12) } else { add(stack, m, .top, stack, .top, 0) }
        if getenv("PIN_BOTTOM") != nil {
            // OAStackView: remove the previous tail's bottom pin, pin the new tail to the stack's bottom.
            if let old = pinnedBottom {
                if legacy { stack.legacyRemoveConstraint(old as! RRLayoutConstraint) } else { stack.removeConstraint(old as! NSLayoutConstraint) }
            }
            if legacy { let k = RRLayoutConstraint(item: m, attribute: .bottom, relatedBy: .equal, toItem: stack, attribute: .bottom, multiplier: 1, constant: 0); stack.legacyAddConstraint(k); pinnedBottom = k }
            else { let k = NSLayoutConstraint(item: m, attribute: .bottom, relatedBy: .equal, toItem: stack, attribute: .bottom, multiplier: 1, constant: 0); stack.addConstraint(k); pinnedBottom = k }
        }
        kids.append(m)
        if getenv("BATCH") != nil { if i + 1 == messages { let t = CFAbsoluteTimeGetCurrent(); root.setNeedsLayout(); root.layoutIfNeeded(); scroll.layoutIfNeeded(); total += CFAbsoluteTimeGetCurrent() - t; marks.append("n=\(messages): batch layout \(Int(total * 1000)) ms") }; continue }
        let t = CFAbsoluteTimeGetCurrent()
        root.setNeedsLayout(); root.layoutIfNeeded(); scroll.layoutIfNeeded()
        total += CFAbsoluteTimeGetCurrent() - t
        if i + 1 == 10 || i + 1 == 25 || i + 1 == messages { marks.append("n=\(i + 1): cumulative \(Int(total * 1000)) ms") }
    }
    for l in marks { print("incr \(mode) \(l)") }
    if getenv("REMOVE_TAIL") != nil {
        // Chat behaviour on a refresh: drop the last k messages (view removed, its constraints go with it), re-layout each time.
        var rt = 0.0
        for _ in 0..<10 {
            guard let gone = kids.popLast() else { break }
            gone.removeFromSuperview()
            let t = CFAbsoluteTimeGetCurrent(); root.setNeedsLayout(); root.layoutIfNeeded(); scroll.layoutIfNeeded(); rt += CFAbsoluteTimeGetCurrent() - t
        }
        print("incr \(mode) remove-10-from-tail: \(Int(rt * 1000)) ms, lastFrame \(kids.last!.frame)")
    }
    print("incr \(mode) lastFrame \(kids.last!.frame)")
}

final class FixedIntrinsic: UIView {
    var size = CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    override var intrinsicContentSize: CGSize { size }
}

/// Differential scenarios: each builds the same small hierarchy under native UIKit or the legacy engine and prints
/// every frame; the caller diffs the two outputs.
@MainActor
func runDiff(mode: String) {
    let legacy = (mode == "legacy")
    if legacy { LegacyAutoLayout.installForLegacyNames() }
    func off(_ v: UIView) { if legacy { v.legacyTranslatesAutoresizingMaskIntoConstraints = false } else { v.translatesAutoresizingMaskIntoConstraints = false } }
    func add(_ owner: UIView, _ a: UIView, _ x: NSLayoutConstraint.Attribute, _ r: NSLayoutConstraint.Relation, _ b: UIView?, _ y: NSLayoutConstraint.Attribute, _ c: CGFloat, _ prio: Float = 1000) {
        let n = NSLayoutConstraint.Attribute.notAnAttribute
        if legacy {
            let k = RRLayoutConstraint(item: a, attribute: RRLayoutAttribute(rawValue: x.rawValue)!, relatedBy: r == .equal ? .equal : (r == .greaterThanOrEqual ? .greaterThanOrEqual : .lessThanOrEqual), toItem: b, attribute: RRLayoutAttribute(rawValue: (b == nil ? n : y).rawValue)!, multiplier: 1, constant: c)
            k.priority = prio; owner.legacyAddConstraint(k)
        } else {
            let k = NSLayoutConstraint(item: a, attribute: x, relatedBy: r, toItem: b, attribute: b == nil ? n : y, multiplier: 1, constant: c)
            k.priority = UILayoutPriority(prio); owner.addConstraint(k)
        }
    }
    func setIntrinsic(_ v: FixedIntrinsic, _ w: CGFloat, _ h: CGFloat) {
        v.size = CGSize(width: w, height: h)
        if legacy { v.legacyIntrinsicContentSize = v.size } else { v.invalidateIntrinsicContentSize() }
    }
    func f(_ v: UIView) -> String { let r = v.frame; return "\(r.minX) \(r.minY) \(r.width) \(r.height)" }
    func pass(_ root: UIView) { for _ in 0..<2 { root.setNeedsLayout(); root.layoutIfNeeded() } }
    let none = UIView.noIntrinsicMetric

    // 1. nonzero intrinsic size, centred, no other size constraints
    do {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480)); let v = FixedIntrinsic(frame: .zero); root.addSubview(v); off(v)
        setIntrinsic(v, 120, 44)
        add(root, v, .centerX, .equal, root, .centerX, 0); add(root, v, .centerY, .equal, root, .centerY, 0)
        pass(root); print("nonzero-centred \(f(v))")
        setIntrinsic(v, 80, 30); pass(root); print("nonzero-centred-invalidated \(f(v))")
    }
    // 2. one unspecified dimension (width none, height 50) pinned left/right
    do {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480)); let v = FixedIntrinsic(frame: .zero); root.addSubview(v); off(v)
        setIntrinsic(v, none, 50)
        add(root, v, .leading, .equal, root, .leading, 10); add(root, v, .trailing, .equal, root, .trailing, -10); add(root, v, .top, .equal, root, .top, 20)
        pass(root); print("one-dim \(f(v))")
    }
    // 3. height minimum constraint + hugging: view pinned top/bottom with intrinsic 20 and >= 100 height
    do {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480)); let v = FixedIntrinsic(frame: .zero); root.addSubview(v); off(v)
        setIntrinsic(v, 50, 20)
        add(root, v, .leading, .equal, root, .leading, 0); add(root, v, .top, .equal, root, .top, 0); add(root, v, .height, .greaterThanOrEqual, nil, .notAnAttribute, 100)
        pass(root); print("height-min \(f(v))")
    }
    // 4. bottom anchored, intrinsic height, pinned to bottom with -8
    do {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480)); let v = FixedIntrinsic(frame: .zero); root.addSubview(v); off(v)
        setIntrinsic(v, none, 40)
        add(root, v, .leading, .equal, root, .leading, 0); add(root, v, .trailing, .equal, root, .trailing, 0); add(root, v, .bottom, .equal, root, .bottom, -8)
        pass(root); print("bottom-anchored \(f(v))")
    }
    // 5. two views stretched: hugging priority decides which grows
    do {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let a = FixedIntrinsic(frame: .zero), b = FixedIntrinsic(frame: .zero); root.addSubview(a); root.addSubview(b); off(a); off(b)
        setIntrinsic(a, none, 40); setIntrinsic(b, none, 40)
        if legacy { a.legacySetContentHuggingPriority(RRLayoutPriority(750), for: .vertical); b.legacySetContentHuggingPriority(RRLayoutPriority(250), for: .vertical) }
        else { a.setContentHuggingPriority(UILayoutPriority(750), for: .vertical); b.setContentHuggingPriority(UILayoutPriority(250), for: .vertical) }
        add(root, a, .leading, .equal, root, .leading, 0); add(root, a, .trailing, .equal, root, .trailing, 0); add(root, a, .top, .equal, root, .top, 0)
        add(root, b, .leading, .equal, root, .leading, 0); add(root, b, .trailing, .equal, root, .trailing, 0); add(root, b, .top, .equal, a, .bottom, 0); add(root, b, .bottom, .equal, root, .bottom, 0)
        pass(root); print("hugging a \(f(a)) b \(f(b))")
    }
    // 6. compression resistance: content 300 tall in a 100 tall container
    do {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        let a = FixedIntrinsic(frame: .zero), b = FixedIntrinsic(frame: .zero); root.addSubview(a); root.addSubview(b); off(a); off(b)
        setIntrinsic(a, none, 80); setIntrinsic(b, none, 80)
        if legacy { a.legacySetContentCompressionResistancePriority(RRLayoutPriority(800), for: .vertical); b.legacySetContentCompressionResistancePriority(RRLayoutPriority(300), for: .vertical) }
        else { a.setContentCompressionResistancePriority(UILayoutPriority(800), for: .vertical); b.setContentCompressionResistancePriority(UILayoutPriority(300), for: .vertical) }
        add(root, a, .leading, .equal, root, .leading, 0); add(root, a, .trailing, .equal, root, .trailing, 0); add(root, a, .top, .equal, root, .top, 0)
        add(root, b, .leading, .equal, root, .leading, 0); add(root, b, .trailing, .equal, root, .trailing, 0); add(root, b, .top, .equal, a, .bottom, 0); add(root, b, .bottom, .equal, root, .bottom, 0)
        pass(root); print("compression a \(f(a)) b \(f(b))")
    }
    // 7. UILabel and UIButton intrinsic sizes
    do {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let l = UILabel(frame: .zero); l.text = "Hello world"; l.font = UIFont.systemFont(ofSize: 17)
        let bt = UIButton(type: .custom); bt.setTitle("Tap", for: .normal); bt.titleLabel?.font = UIFont.systemFont(ofSize: 17)
        root.addSubview(l); root.addSubview(bt); off(l); off(bt)
        add(root, l, .leading, .equal, root, .leading, 10); add(root, l, .top, .equal, root, .top, 10)
        add(root, bt, .leading, .equal, root, .leading, 10); add(root, bt, .top, .equal, l, .bottom, 10)
        pass(root); print("label \(f(l)) button \(f(bt))")
        l.text = "A considerably longer label text"; if getenv("POKE_LABEL") != nil { l.setNeedsDisplay() }; pass(root); print("label-changed \(f(l)) button \(f(bt))")
    }
    // 9. scroll view content size from a pinned content chain
    do {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let sc = UIScrollView(frame: .zero); root.addSubview(sc); off(sc)
        add(root, sc, .leading, .equal, root, .leading, 0); add(root, sc, .trailing, .equal, root, .trailing, 0)
        add(root, sc, .top, .equal, root, .top, 0); add(root, sc, .bottom, .equal, root, .bottom, 0)
        var prev: UIView? = nil; var kids: [FixedIntrinsic] = []
        for i in 0..<12 {
            let k = FixedIntrinsic(frame: .zero); sc.addSubview(k); off(k); setIntrinsic(k, none, CGFloat(20 + i * 5)); kids.append(k)
            add(sc, k, .leading, .equal, sc, .leading, 0); add(sc, k, .width, .equal, nil, .notAnAttribute, 320)
            if let p = prev { add(sc, k, .top, .equal, p, .bottom, 8) } else { add(sc, k, .top, .equal, sc, .top, 0) }
            prev = k
        }
        add(sc, prev!, .bottom, .equal, sc, .bottom, 0)
        pass(root); print("scroll-content \(sc.contentSize.width) \(sc.contentSize.height) last \(f(kids.last!))")
        setIntrinsic(kids[3], none, 200); pass(root); print("scroll-content-changed \(sc.contentSize.width) \(sc.contentSize.height) last \(f(kids.last!))")
    }
    // 10. wrapping multi-line label with preferredMaxLayoutWidth-style fixed width
    do {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let l = UILabel(frame: .zero); l.numberOfLines = 0; l.font = UIFont.systemFont(ofSize: 17)
        l.text = "A long message that must wrap across several lines when the label is only 200 points wide ok"
        root.addSubview(l); off(l)
        add(root, l, .leading, .equal, root, .leading, 10); add(root, l, .top, .equal, root, .top, 10); add(root, l, .width, .equal, nil, .notAnAttribute, 200)
        if legacy { l.preferredMaxLayoutWidth = 200 } else { l.preferredMaxLayoutWidth = 200 }
        pass(root); print("wrapping-label \(f(l))")
    }
    // 11. multi-line label pinned inside a fixed-width container, preferredMaxLayoutWidth NOT set
    do {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        let box = UIView(); let l = UILabel(frame: .zero); l.numberOfLines = 0; l.font = UIFont.systemFont(ofSize: 17)
        l.text = "A long message that must wrap across several lines when the box is only 200 points wide ok"
        root.addSubview(box); box.addSubview(l); off(box); off(l)
        add(root, box, .leading, .equal, root, .leading, 10); add(root, box, .top, .equal, root, .top, 10); add(root, box, .width, .equal, nil, .notAnAttribute, 200)
        add(box, l, .leading, .equal, box, .leading, 0); add(box, l, .trailing, .equal, box, .trailing, 0); add(box, l, .top, .equal, box, .top, 0); add(box, l, .bottom, .equal, box, .bottom, 0)
        pass(root); print("wrap-unset-pmlw box \(f(box)) label \(f(l))")
    }
    // 8. repeated layout passes stay stable
    do {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480)); let v = FixedIntrinsic(frame: .zero); root.addSubview(v); off(v)
        setIntrinsic(v, none, 60)
        add(root, v, .leading, .equal, root, .leading, 5); add(root, v, .trailing, .equal, root, .trailing, -5); add(root, v, .top, .equal, root, .top, 0)
        var seen = Set<String>(); for _ in 0..<5 { pass(root); seen.insert(f(v)) }
        print("repeated \(seen.sorted().joined(separator: " | "))")
    }
}


/// MessageView-shaped chat: every message is a container with avatar, name, edited, timestamp, content and a body label,
/// pinned exactly like NeoCord2's MessageView, appended to a stack with a layout after each message.
@MainActor
func runMessageShaped(mode: String, messages: Int) {
    let legacy = (mode == "legacy")
    if legacy { LegacyAutoLayout.installForLegacyNames() }
    func off(_ v: UIView) { if legacy { v.legacyTranslatesAutoresizingMaskIntoConstraints = false } else { v.translatesAutoresizingMaskIntoConstraints = false } }
    func pin(_ owner: UIView, _ a: UIView, _ x: NSLayoutConstraint.Attribute, _ b: UIView?, _ y: NSLayoutConstraint.Attribute, _ c: CGFloat) {
        let n = NSLayoutConstraint.Attribute.notAnAttribute
        if legacy {
            owner.legacyAddConstraint(RRLayoutConstraint(item: a, attribute: RRLayoutAttribute(rawValue: x.rawValue)!, relatedBy: .equal, toItem: b, attribute: RRLayoutAttribute(rawValue: (b == nil ? n : y).rawValue)!, multiplier: 1, constant: c))
        } else {
            owner.addConstraint(NSLayoutConstraint(item: a, attribute: x, relatedBy: .equal, toItem: b, attribute: b == nil ? n : y, multiplier: 1, constant: c))
        }
    }
    let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let container = UIView(), scroll = UIScrollView(), stack = UIView()
    root.addSubview(container); container.addSubview(scroll); scroll.addSubview(stack)
    for v in [container, scroll, stack] { off(v) }
    pin(root, container, .top, root, .top, 20); pin(root, container, .leading, root, .leading, 0); pin(root, container, .trailing, root, .trailing, 0); pin(root, container, .bottom, root, .bottom, 0)
    pin(container, scroll, .top, container, .top, 0); pin(container, scroll, .leading, container, .leading, 0); pin(container, scroll, .trailing, container, .trailing, 0); pin(container, scroll, .bottom, container, .bottom, 0)
    pin(scroll, stack, .top, scroll, .top, 20); pin(scroll, stack, .leading, scroll, .leading, 10); pin(scroll, stack, .bottom, scroll, .bottom, 0); pin(scroll, stack, .width, scroll, .width, -20)
    root.layoutIfNeeded()
    var prev: UIView? = nil; var total = 0.0; var worst = 0.0; var pinnedTail: AnyObject? = nil
    for i in 0..<messages {
        let msg = UIView(), bg = UIView(), av = UIView(), content = UIView()
        let name = UILabel(), ts = UILabel(), edited = UILabel(), body = UILabel()
        name.text = "Author"; ts.text = "Yesterday at 12:03 PM"; edited.text = ""; body.text = "message number \(i) with some body text"; body.numberOfLines = 0; if getenv("NO_PMLW") == nil { body.preferredMaxLayoutWidth = 240 }     // the app sets UIScreen.width - 80 on its message body
        for v in [msg, bg, av, content, name, ts, edited, body] as [UIView] { off(v) }
        stack.addSubview(msg)
        msg.addSubview(content); msg.addSubview(bg); msg.addSubview(name); msg.addSubview(ts); msg.addSubview(edited); msg.addSubview(av); content.addSubview(body)
        pin(msg, bg, .top, msg, .top, 0); pin(msg, bg, .leading, msg, .leading, 0); pin(msg, bg, .trailing, msg, .trailing, 0); pin(msg, bg, .bottom, msg, .bottom, 0)
        pin(msg, av, .width, nil, .notAnAttribute, 30); pin(msg, av, .height, nil, .notAnAttribute, 30); pin(msg, av, .top, bg, .top, 4); pin(msg, av, .leading, bg, .leading, 0)
        pin(msg, name, .top, bg, .top, 4); pin(msg, name, .leading, av, .trailing, 8)
        pin(msg, content, .top, name, .bottom, 2); pin(msg, content, .leading, name, .leading, 0); pin(msg, content, .trailing, bg, .trailing, -20); pin(msg, content, .bottom, bg, .bottom, -6)
        pin(msg, edited, .centerY, name, .centerY, 0); pin(msg, edited, .leading, name, .trailing, 4)
        pin(msg, ts, .centerY, name, .centerY, 0); pin(msg, ts, .leading, edited, .trailing, 4); pin(msg, ts, .trailing, content, .trailing, 0)
        pin(content, body, .top, content, .top, 0); pin(content, body, .leading, content, .leading, 0); pin(content, body, .trailing, content, .trailing, 0); pin(content, body, .bottom, content, .bottom, 0)
        pin(stack, msg, .leading, stack, .leading, 0); pin(stack, msg, .trailing, stack, .trailing, 0)
        if let p = prev { pin(stack, msg, .top, p, .bottom, 12) } else { pin(stack, msg, .top, stack, .top, 0) }
        // OAStackView: drop the previous tail's bottom pin, pin the new tail to the stack bottom.
        if let old = pinnedTail {
            if legacy { stack.legacyRemoveConstraint(old as! RRLayoutConstraint) } else { stack.removeConstraint(old as! NSLayoutConstraint) }
        }
        if legacy { let k = RRLayoutConstraint(item: msg, attribute: .bottom, relatedBy: .equal, toItem: stack, attribute: .bottom, multiplier: 1, constant: 0); stack.legacyAddConstraint(k); pinnedTail = k }
        else { let k = NSLayoutConstraint(item: msg, attribute: .bottom, relatedBy: .equal, toItem: stack, attribute: .bottom, multiplier: 1, constant: 0); stack.addConstraint(k); pinnedTail = k }
        prev = msg
        let t = CFAbsoluteTimeGetCurrent()
        root.setNeedsLayout(); root.layoutIfNeeded(); scroll.layoutIfNeeded()
        let dt = (CFAbsoluteTimeGetCurrent() - t) * 1000; total += dt; if dt > worst { worst = dt }
    }
    if messages == 1, let m = prev {
        func fr(_ v: UIView) -> String { let r = v.frame; return "\(r.minX) \(r.minY) \(r.width) \(r.height)" }
        print("msg1 \(mode) msg \(fr(m))")
        for (i, v) in m.subviews.enumerated() { print("msg1 \(mode) sub\(i) \(type(of: v)) \(fr(v))") }
        if let content = m.subviews.first, let body = content.subviews.first { print("msg1 \(mode) body \(fr(body)) intrinsic \((body as? UILabel)?.intrinsicContentSize ?? .zero)") }
    }
    if mode == "legacy", let p = UICLegacyLayoutDebugSummary() { for line in String(cString: p).split(separator: "\n") where line.hasPrefix("solver") || line.hasPrefix("passes") || line.hasPrefix("  ") || line.hasPrefix("rebuild") || line.hasPrefix("bails") { print("msgshaped \(line)") }; free(p) }
    print("msgshaped \(mode) n=\(messages): total \(Int(total)) ms worst pass \(Int(worst)) ms last \(prev!.frame)")
}

MainActor.assumeIsolated {
    if getenv("NO_PRESOLVE") != nil { Solver.presolvesEnabled = false }
    if CommandLine.arguments.dropFirst().first == "msg" { let a = Array(CommandLine.arguments.dropFirst()); runMessageShaped(mode: a[1], messages: Int(a[2]) ?? 20); exit(0) }
    if CommandLine.arguments.dropFirst().first == "diff" { runDiff(mode: CommandLine.arguments.dropFirst().dropFirst().first ?? "native"); exit(0) }
    if CommandLine.arguments.dropFirst().first == "input" { let a = Array(CommandLine.arguments.dropFirst()); runInput(mode: a[1], text: a.count > 2 ? a[2] : "", flags: a.count > 3 ? a[3] : ""); exit(0) }
    if CommandLine.arguments.dropFirst().first == "incr" { let a = Array(CommandLine.arguments.dropFirst()); runIncremental(mode: a[1], messages: Int(a[2]) ?? 50); exit(0) }
    let a = Array(CommandLine.arguments.dropFirst()); runChat(mode: a.first ?? "native", messages: Int(a.count > 1 ? a[1] : "5") ?? 5, variant: a.count > 2 ? a[2] : "plain") }
