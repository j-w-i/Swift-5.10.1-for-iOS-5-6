//
//  autolayout_native_parity.swift
//  Native-vs-backport parity on REAL UIKit controls.
//
//  The same constraint scenarios run twice on the iOS simulator: once with native UIKit
//  Auto Layout (`native`), once with the legacy engine force-installed (`legacy`). Every
//  solved frame is printed; the runner diffs the two outputs and fails on any difference.
//  This is what catches controls whose intrinsic size the engine does not know (UISwitch,
//  UITextField, UISlider...), which pure engine tests with synthetic views cannot.
//
import UIKit
import Foundation

let legacyMode = CommandLine.arguments.contains("legacy")

@MainActor
struct Scene {
    let root: UIView
    init(width: CGFloat = 320, height: CGFloat = 480) {
        root = UIView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        if legacyMode { _ = LegacyAutoLayout.installForLegacyNames() }
    }
    func add<T: UIView>(_ v: T, to parent: UIView? = nil) -> T {
        (parent ?? root).addSubview(v)
        if legacyMode { v.legacyTranslatesAutoresizingMaskIntoConstraints = false }
        else { v.translatesAutoresizingMaskIntoConstraints = false }
        return v
    }
    func pin(_ a: UIView, _ x: NSLayoutConstraint.Attribute, _ b: UIView?, _ y: NSLayoutConstraint.Attribute,
             _ m: CGFloat = 1, _ c: CGFloat = 0, _ r: NSLayoutConstraint.Relation = .equal, priority: Float = 1000) {
        if legacyMode {
            let k = RRLayoutConstraint(item: a, attribute: RRLayoutAttribute(rawValue: x.rawValue)!,
                                       relatedBy: RRLayoutRelation(rawValue: r.rawValue)!, toItem: b,
                                       attribute: RRLayoutAttribute(rawValue: y.rawValue)!, multiplier: m, constant: c)
            k.priority = RRLayoutPriority(priority)
            a.legacyAddConstraint(k)
        } else {
            let k = NSLayoutConstraint(item: a, attribute: x, relatedBy: r, toItem: b, attribute: y, multiplier: m, constant: c)
            k.priority = UILayoutPriority(priority)
            k.isActive = true
        }
    }
    func solve() {
        if legacyMode { root.layoutSubviews(); for v in allSubviews(root) { v.layoutSubviews() } }
        else { root.setNeedsLayout(); root.layoutIfNeeded() }
    }
    func allSubviews(_ v: UIView) -> [UIView] { v.subviews.flatMap { [$0] + allSubviews($0) } }
}

func report(_ scenario: String, _ views: [(String, UIView)]) {
    for (name, v) in views {
        let f = v.frame
        func r(_ x: CGFloat) -> String { let v = (x * 2).rounded() / 2; return String(format: "%.1f", v == 0 ? 0 : v) }
        print("\(scenario)\t\(name)\t\(r(f.minX)),\(r(f.minY)),\(r(f.width)),\(r(f.height))")
    }
}

@MainActor
func run() {
    // 1. The login screen, exactly as AuthenticationVC constrains it (real controls).
    do {
        let s = Scene()
        let label = s.add(UILabel()); label.text = "Use Token"
        let toggle = s.add(UISwitch())
        let email = s.add(UITextField()); email.borderStyle = .roundedRect; email.placeholder = "Email"
        let password = s.add(UITextField()); password.borderStyle = .roundedRect; password.placeholder = "Password"
        let login = s.add(UIButton(type: .system)); login.setTitle("Login", for: .normal)
        let status = s.add(UILabel()); status.numberOfLines = 0; status.textAlignment = .center
        s.pin(label, .centerX, s.root, .centerX, 1, -40); s.pin(label, .top, s.root, .top, 1, 30)
        s.pin(toggle, .centerY, label, .centerY); s.pin(toggle, .left, label, .right, 1, 10)
        for f in [email, password] {
            s.pin(f, .centerX, s.root, .centerX); s.pin(f, .width, s.root, .width, 0.7)
            s.pin(f, .height, nil, .notAnAttribute, 1, 40)
        }
        s.pin(email, .top, label, .bottom, 1, 20); s.pin(password, .top, email, .bottom, 1, 20)
        s.pin(login, .centerX, s.root, .centerX); s.pin(login, .top, password, .bottom, 1, 20)
        s.pin(login, .width, email, .width); s.pin(login, .height, nil, .notAnAttribute, 1, 40)
        s.pin(status, .centerX, s.root, .centerX); s.pin(status, .top, login, .bottom, 1, 20)
        s.pin(status, .width, s.root, .width, 0.7)
        s.solve()
        report("login", [("label", label), ("toggle", toggle), ("email", email), ("password", password),
                         ("login", login), ("status", status)])
    }
    // Container coordinate spaces: frame origin, bounds origin and a translated
    // root must not be conflated (navigation/scrolling system containers).
    for origin in [CGPoint(x: 0, y: 20), CGPoint(x: 13, y: -27)] {
        let s = Scene(width: 320, height: 460)
        s.root.frame.origin = CGPoint(x: 0, y: 20)
        s.root.bounds.origin = origin
        let bar = s.add(UIView())
        let box = s.add(UIView())
        let child = s.add(UIView(), to: box)
        s.pin(bar, .left, s.root, .left, 1, 10)
        s.pin(bar, .top, s.root, .top, 1, 22)
        s.pin(bar, .width, nil, .notAnAttribute, 1, 300)
        s.pin(bar, .height, nil, .notAnAttribute, 1, 44)
        s.pin(box, .left, s.root, .left, 1, 84)
        s.pin(box, .top, s.root, .top, 1, 74)
        s.pin(box, .width, nil, .notAnAttribute, 1, 226)
        s.pin(box, .height, nil, .notAnAttribute, 1, 320)
        s.pin(child, .left, box, .left, 1, 10)
        s.pin(child, .top, box, .top, 1, 12)
        s.pin(child, .width, nil, .notAnAttribute, 1, 80)
        s.pin(child, .height, nil, .notAnAttribute, 1, 20)
        s.solve()
        report("bounds\(Int(origin.x))", [("bar",bar),("box",box),("child",child)])
    }
    // Mixed UIKit-managed frames and constrained descendants. A navigation
    // controller repositions its wrapper/content after the first solve.
    do {
        let s = Scene()
        let wrapper = UIView(frame: CGRect(x: 0, y: 20, width: 320, height: 460))
        s.root.addSubview(wrapper)
        let content = UIView(frame: wrapper.bounds); wrapper.addSubview(content)
        let bar = s.add(UIView())
        let toolbar = s.add(UIView(), to: content)
        let container = s.add(UIView(), to: content)
        s.pin(bar,.left,s.root,.left,1,10); s.pin(bar,.top,s.root,.top,1,22)
        s.pin(bar,.width,nil,.notAnAttribute,1,300); s.pin(bar,.height,nil,.notAnAttribute,1,44)
        s.pin(toolbar,.left,content,.left,1,10); s.pin(toolbar,.bottom,content,.bottom,1,-10)
        s.pin(toolbar,.width,nil,.notAnAttribute,1,300); s.pin(toolbar,.height,nil,.notAnAttribute,1,44)
        s.pin(container,.left,content,.left); s.pin(container,.right,content,.right)
        s.pin(container,.top,content,.top,1,64); s.pin(container,.bottom,toolbar,.top)
        s.solve(); report("managed0",[("wrapper",wrapper),("content",content),("bar",bar),("toolbar",toolbar),("container",container)])
        wrapper.frame=CGRect(x:0,y:0,width:320,height:480);content.frame=wrapper.bounds
        s.solve(); report("managed1",[("wrapper",wrapper),("content",content),("bar",bar),("toolbar",toolbar),("container",container)])
        wrapper.bounds.size.height=440; content.bounds.size.height=440
        s.solve(); report("managedBounds",[("wrapper",wrapper),("content",content),("toolbar",toolbar),("container",container)])
    }
    // 2. Controls that size themselves (no size constraints at all): pinned by origin only.
    do {
        let s = Scene()
        let controls: [(String, UIView)] = [
            ("switch", UISwitch()), ("label", { let l = UILabel(); l.text = "Hello world"; return l }()),
            ("button", { let b = UIButton(type: .system); b.setTitle("Tap", for: .normal); return b }()),
            ("activity", UIActivityIndicatorView(style: .medium)), ("pagecontrol", { let p = UIPageControl(); p.numberOfPages = 5; return p }()),
            ("segmented", UISegmentedControl(items: ["A", "B", "C"])), ("stepper", UIStepper()),
            ("field", { let t = UITextField(); t.borderStyle = .roundedRect; t.text = "text"; return t }()),
            ("image", UIImageView(image: UIGraphicsImageRenderer(size: CGSize(width: 30, height: 20)).image { _ in })),
        ]
        var y: CGFloat = 10
        for (_, v) in controls {
            _ = s.add(v)
            s.pin(v, .left, s.root, .left, 1, 10); s.pin(v, .top, s.root, .top, 1, y); y += 50
        }
        s.solve(); report("intrinsic", controls)
    }
    // 3. Width-flexible controls: one intrinsic axis only (height), width from constraints.
    do {
        let s = Scene()
        let controls: [(String, UIView)] = [("slider", UISlider()), ("progress", UIProgressView()),
                                            ("toolbar", UIToolbar()), ("searchbar", UISearchBar())]
        var y: CGFloat = 10
        for (_, v) in controls {
            _ = s.add(v)
            s.pin(v, .left, s.root, .left, 1, 10); s.pin(v, .right, s.root, .right, 1, -10); s.pin(v, .top, s.root, .top, 1, y); y += 70
        }
        s.solve(); report("flex", controls)
    }
    // 4. Hugging / compression: a label between two fixed edges, and two labels sharing a row.
    do {
        let s = Scene()
        let a = s.add(UILabel()); a.text = "Short"
        let b = s.add(UILabel()); b.text = "A much longer label that must be compressed or stretched"
        s.pin(a, .left, s.root, .left, 1, 10); s.pin(a, .top, s.root, .top, 1, 10)
        s.pin(b, .left, a, .right, 1, 8); s.pin(b, .top, s.root, .top, 1, 10)
        s.pin(b, .right, s.root, .right, 1, -10)
        // Equal priorities make the winner solver-specific (an ambiguous layout), so the
        // test fixes the tie the way an app does: `a` is the one that must not shrink.
        if legacyMode { a.legacySetContentCompressionResistancePriority(RRLayoutPriority(760), for: .horizontal) }
        else { a.setContentCompressionResistancePriority(UILayoutPriority(760), for: .horizontal) }
        s.solve(); report("squeeze", [("a", a), ("b", b)])
    }
    // 5. Multiline label with preferredMaxLayoutWidth-less wrapping inside a fixed width.
    do {
        let s = Scene()
        let l = s.add(UILabel()); l.numberOfLines = 0
        l.text = "This is a longer piece of text that has to wrap onto several lines inside the box."
        // iOS 6 contract: a wrapping label needs preferredMaxLayoutWidth (iOS 8+ derives it).
        l.preferredMaxLayoutWidth = 200
        s.pin(l, .left, s.root, .left, 1, 20); s.pin(l, .top, s.root, .top, 1, 20); s.pin(l, .width, nil, .notAnAttribute, 1, 200)
        s.solve(); report("wrap", [("label", l)])
    }
    // 6. Nested container, centred child with aspect and priorities.
    do {
        let s = Scene()
        let box = s.add(UIView()); let child = s.add(UIView(), to: box)
        s.pin(box, .left, s.root, .left, 1, 20); s.pin(box, .right, s.root, .right, 1, -20)
        s.pin(box, .top, s.root, .top, 1, 40); s.pin(box, .height, nil, .notAnAttribute, 1, 200)
        s.pin(child, .centerX, box, .centerX); s.pin(child, .centerY, box, .centerY)
        s.pin(child, .width, box, .width, 0.5); s.pin(child, .height, child, .width, 0.5)
        s.pin(child, .width, nil, .notAnAttribute, 1, 400, .lessThanOrEqual, priority: 750)
        s.solve(); report("nested", [("box", box), ("child", child)])
    }
}
/// What a content setter does on each OS. iOS 6+ UIKit calls `invalidateIntrinsicContentSize`
/// inside the setter. iOS 5 UIKit has no such call, but its setters invalidate display
/// (`-setNeedsDisplay`), which the engine's hook turns into the same invalidation. The simulator's
/// modern UIKit does not message `-setNeedsDisplay` from `UILabel.text`, so the iOS 5 setter
/// behaviour is reproduced explicitly here.
@MainActor func syncContentChange(_ v: UIView) {
    if legacyMode { v.setNeedsDisplay() } else { v.invalidateIntrinsicContentSize() }
}

// 7. Dynamic change after the first layout (what Login does): text change -> relayout, then
// the layout must settle (no passes while nothing changes) and stay fast.
@MainActor
func dynamic() {
    let s = Scene()
    let status = s.add(UILabel()); status.numberOfLines = 0; status.textAlignment = .center
    let below = s.add(UIView())
    status.preferredMaxLayoutWidth = 200
    s.pin(status, .centerX, s.root, .centerX); s.pin(status, .top, s.root, .top, 1, 20)
    s.pin(status, .width, nil, .notAnAttribute, 1, 200)
    s.pin(below, .left, s.root, .left, 1, 20); s.pin(below, .top, status, .bottom, 1, 10)
    s.pin(below, .width, nil, .notAnAttribute, 1, 50); s.pin(below, .height, nil, .notAnAttribute, 1, 10)
    s.solve(); report("dynamic0", [("status", status), ("below", below)])
    status.text = "Logging in..."
    syncContentChange(status)
    s.solve(); report("dynamic1", [("status", status), ("below", below)])
    status.text = "Login failed: The operation couldn't be completed. (NSURLErrorDomain error -1200.)"
    syncContentChange(status)
    s.solve(); report("dynamic2", [("status", status), ("below", below)])
    // Settling: with nothing changed, repeated passes must be near-free and must not re-dirty.
    let start = CFAbsoluteTimeGetCurrent()
    for _ in 0..<2000 { s.solve() }
    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
    FileHandle.standardError.write("settle: 2000 idle passes in \(String(format: "%.1f", ms)) ms (\(legacyMode ? "legacy" : "native"))\n".data(using: .utf8)!)
    if legacyMode {
        let dirty = s.root.legacyConstraintsAreDirty || s.root.legacyNeedsLayoutPass
        print("settled\troot-dirty-after-idle-passes=\(dirty)")
    } else { print("settled\troot-dirty-after-idle-passes=false") }
}
@MainActor func textViewport() {
    let s = Scene()
    let text = s.add(UITextView())
    text.isEditable = false
    text.font = .systemFont(ofSize: 13)
    text.text = String(repeating: "A long log message should wrap within the text view rather than outside its visible viewport. ", count: 8)
    s.pin(text, .left, s.root, .left, 1, 20)
    s.pin(text, .top, s.root, .top, 1, 20)
    s.pin(text, .width, s.root, .width, 1, -40)
    s.pin(text, .height, nil, .notAnAttribute, 1, 260)
    for width: CGFloat in [320, 240, 400] {
        s.root.frame.size.width = width
        s.solve(); text.layoutIfNeeded()
        report("text-viewport-\(Int(width))", [("text", text)])
        func rounded(_ x: CGFloat) -> String { String(format: "%.1f", (x * 2).rounded() / 2) }
        print("text-content-\(Int(width))\t\(rounded(text.contentSize.width)),\(rounded(text.contentSize.height))")
        precondition(text.contentSize.width <= text.bounds.width + 1, "text content must wrap at the viewport width")
    }
}
@MainActor func nativeOwnedControls() {
    let factories: [(String, () -> UIView)] = [
        ("progress", { let v = UIProgressView(progressViewStyle: .default); v.progress = 0.25; return v }),
        ("slider", { let v = UISlider(); v.value = 0.25; return v }),
        ("button", { let v = UIButton(type: .system); v.setTitle("Control", for: .normal); return v }),
        ("field", { let v = UITextField(); v.borderStyle = .roundedRect; v.text = "Control"; return v }),
        ("label", { let v = UILabel(); v.text = "Control"; return v })
    ]
    for (name, factory) in factories {
        let s = Scene()
        let control = s.add(factory())
        s.pin(control, .left, s.root, .left, 1, 20)
        s.pin(control, .top, s.root, .top, 1, 20)
        s.pin(control, .width, s.root, .width, 1, -40)
        s.pin(control, .height, nil, .notAnAttribute, 1, 32)
        for width: CGFloat in [320, 240, 400] {
            s.root.frame.size.width = width
            s.solve(); control.layoutIfNeeded()
            func emit(_ view: UIView, _ path: String) {
                report("owned-\(name)-\(Int(width))", [(path, view)])
                for (index, child) in view.subviews.enumerated() { emit(child, path + "/" + String(index)) }
            }
            emit(control, "control")
        }
    }
}
@MainActor private final class GeometrySetterProbe: UIView {
    var frameWrites = 0, boundsWrites = 0, centerWrites = 0
    override var frame: CGRect { didSet { frameWrites += 1 } }
    override var bounds: CGRect { didSet { boundsWrites += 1 } }
    override var center: CGPoint { didSet { centerWrites += 1 } }
}
@MainActor func geometrySetterParity() {
    let s = Scene()
    let probe = s.add(GeometrySetterProbe())
    s.pin(probe, .left, s.root, .left, 1, 20)
    s.pin(probe, .top, s.root, .top, 1, 20)
    s.pin(probe, .width, nil, .notAnAttribute, 1, 100)
    s.pin(probe, .height, nil, .notAnAttribute, 1, 60)
    probe.frameWrites = 0; probe.boundsWrites = 0; probe.centerWrites = 0
    s.solve()
    report("geometry-setters", [("probe", probe)])
    print("geometry-setter-calls\t\(probe.frameWrites),\(probe.boundsWrites),\(probe.centerWrites)")
}
@MainActor func runNativeParitySuite() { run(); dynamic(); textViewport(); nativeOwnedControls(); geometrySetterParity() }
MainActor.assumeIsolated { runNativeParitySuite() }
