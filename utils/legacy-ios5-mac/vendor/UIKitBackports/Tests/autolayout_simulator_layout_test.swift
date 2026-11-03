//
//  autolayout_simulator_layout_test.swift
//  Regression test: the forced legacy bridge must actually *solve* a layout shaped
//  like a real login screen (constraints stored on the subviews that own them,
//  centre/width/height/top relations to the parent and to siblings).
//
//  The earlier hook test only counted constraints and checked frames were finite, so a
//  build whose engine never ran (every view left at the origin, as seen on a device)
//  still passed. This test asserts the solved frames.
//
import UIKit
import Foundation

@MainActor
func runLayoutTest() -> Bool {
    LegacyAutoLayout.installForLegacyNames()

    func make(_ root: UIView, count: Int) -> [UIView] {
        (0..<count).map { _ in
            let v = UIView(frame: .zero)
            v.legacyTranslatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            return v
        }
    }
    func rr(_ a: UIView, _ x: RRLayoutAttribute, _ b: UIView?, _ y: RRLayoutAttribute,
            _ m: CGFloat = 1, _ c: CGFloat = 0) -> RRLayoutConstraint {
        RRLayoutConstraint(item: a, attribute: x, relatedBy: .equal, toItem: b, attribute: y,
                           multiplier: m, constant: c)
    }
    func activate(_ c: RRLayoutConstraint, on v: UIView) { v.legacyAddConstraint(c) }

    var ok = true
    func check(_ name: String, _ cond: Bool) {
        print("layout: \(cond ? "ok  " : "FAIL") \(name)"); if !cond { ok = false }
    }

    // Scenario A: root laid out AFTER the subviews and constraints exist.
    let root = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let v = make(root, count: 4)   // label, field, field2, button
    let (label, email, password, button) = (v[0], v[1], v[2], v[3])
    label.frame = CGRect(x: 0, y: 0, width: 80, height: 20)      // intrinsic-ish
    activate(rr(label, .width, nil, .notAnAttribute, 1, 80), on: label)
    activate(rr(label, .height, nil, .notAnAttribute, 1, 20), on: label)
    activate(rr(label, .centerX, root, .centerX, 1, -40), on: label)
    activate(rr(label, .top, root, .top, 1, 30), on: label)
    activate(rr(email, .centerX, root, .centerX), on: email)
    activate(rr(email, .top, label, .bottom, 1, 20), on: email)
    activate(rr(email, .width, root, .width, 0.8), on: email)
    activate(rr(email, .height, nil, .notAnAttribute, 1, 40), on: email)
    activate(rr(password, .centerX, root, .centerX), on: password)
    activate(rr(password, .top, email, .bottom, 1, 20), on: password)
    activate(rr(password, .width, email, .width), on: password)
    activate(rr(password, .height, nil, .notAnAttribute, 1, 40), on: password)
    activate(rr(button, .centerX, root, .centerX), on: button)
    activate(rr(button, .top, password, .bottom, 1, 20), on: button)
    activate(rr(button, .width, email, .width), on: button)
    activate(rr(button, .height, nil, .notAnAttribute, 1, 40), on: button)
    print("layout: A isActive=\(LegacyAutoLayout.isActive) rootDirty=\(root.legacyConstraintsAreDirty)")
    root.layoutSubviews()
    print("layout: A label=\(label.frame) email=\(email.frame) password=\(password.frame) button=\(button.frame)")
    check("A label x/y", abs(label.frame.minX - 80) < 0.5 && abs(label.frame.minY - 30) < 0.5)
    check("A email width 256", abs(email.frame.width - 256) < 0.5)
    check("A email x=32 y=70", abs(email.frame.minX - 32) < 0.5 && abs(email.frame.minY - 70) < 0.5)
    check("A password y=130", abs(password.frame.minY - 130) < 0.5)
    check("A button y=190", abs(button.frame.minY - 190) < 0.5)

    // Scenario B: the root was already laid out once (UIKit does this before a
    // controller adds its subviews), THEN subviews + constraints are added.
    let root2 = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    root2.layoutSubviews()
    let w = make(root2, count: 2)
    activate(rr(w[0], .width, nil, .notAnAttribute, 1, 100), on: w[0])
    activate(rr(w[0], .height, nil, .notAnAttribute, 1, 40), on: w[0])
    activate(rr(w[0], .centerX, root2, .centerX), on: w[0])
    activate(rr(w[0], .top, root2, .top, 1, 50), on: w[0])
    activate(rr(w[1], .width, w[0], .width), on: w[1])
    activate(rr(w[1], .height, nil, .notAnAttribute, 1, 10), on: w[1])
    activate(rr(w[1], .leading, w[0], .leading), on: w[1])
    activate(rr(w[1], .top, w[0], .bottom, 1, 5), on: w[1])
    root2.layoutSubviews()
    print("layout: B a=\(w[0].frame) b=\(w[1].frame)")
    check("B a solved", abs(w[0].frame.minX - 110) < 0.5 && abs(w[0].frame.minY - 50) < 0.5
          && abs(w[0].frame.width - 100) < 0.5)
    check("B b below a", abs(w[1].frame.minY - 95) < 0.5 && abs(w[1].frame.width - 100) < 0.5)

    // Scenario C: hierarchy added to a root that is hosted in a window-less
    // superview which has laid out (nested container).
    let outer = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let inner = UIView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    inner.legacyTranslatesAutoresizingMaskIntoConstraints = false
    outer.addSubview(inner)
    let leaf = make(inner, count: 1)[0]
    activate(rr(leaf, .width, nil, .notAnAttribute, 1, 60), on: leaf)
    activate(rr(leaf, .height, nil, .notAnAttribute, 1, 60), on: leaf)
    activate(rr(leaf, .centerX, inner, .centerX), on: leaf)
    activate(rr(leaf, .centerY, inner, .centerY), on: leaf)
    activate(rr(inner, .width, nil, .notAnAttribute, 1, 200), on: inner)
    activate(rr(inner, .height, nil, .notAnAttribute, 1, 200), on: inner)
    activate(rr(inner, .leading, outer, .leading, 1, 10), on: inner)
    activate(rr(inner, .top, outer, .top, 1, 10), on: inner)
    outer.layoutSubviews(); inner.layoutSubviews()
    print("layout: C inner=\(inner.frame) leaf=\(leaf.frame)")
    check("C leaf centred in inner", abs(leaf.frame.minX - 70) < 0.5 && abs(leaf.frame.minY - 70) < 0.5)
    check("C inner placed", abs(inner.frame.minX - 10) < 0.5 && abs(inner.frame.minY - 10) < 0.5)

    // Scenario D: parent-only solve with a direct-layout leaf, followed by late input insertion.
    let chat = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let container = make(chat, count: 1)[0]
    let scroll = make(container, count: 1)[0]
    let content = make(scroll, count: 1)[0]
    func pin(_ child: UIView, _ parent: UIView, _ top: CGFloat = 0, _ side: CGFloat = 0) {
        for c in [rr(child, .leading, parent, .leading, 1, side),
                  rr(child, .trailing, parent, .trailing, 1, -side),
                  rr(child, .top, parent, .top, 1, top),
                  rr(child, .bottom, parent, .bottom, 1, -top)] { activate(c, on: parent) }
    }
    pin(container, chat, 20); pin(scroll, container); pin(content, scroll, 20, 10)
    chat.layoutSubviews(); container.layoutSubviews(); scroll.layoutSubviews()
    check("D initial parent frame", container.frame.size == CGSize(width: 320, height: 440))
    let input = make(container, count: 1)[0]
    activate(rr(input, .width, container, .width, 1, -20), on: container)
    activate(rr(input, .centerX, container, .centerX), on: container)
    activate(rr(input, .bottom, container, .bottom, 1, -20), on: container)
    activate(rr(input, .height, nil, .notAnAttribute, 1, 44), on: input)
    chat.layoutSubviews(); container.layoutSubviews(); scroll.layoutSubviews(); input.layoutSubviews()
    check("D input insertion preserves parent", container.frame.size == CGSize(width: 320, height: 440))
    check("D input fitting frame", input.frame.size == CGSize(width: 300, height: 44))

    print(ok ? "layout: PASS" : "layout: FAIL")
    return ok
}
MainActor.assumeIsolated { _ = runLayoutTest() }
