import UIKit
import Foundation

// Gating probe: exercises every backported path and prints which implementation served it.
// Output goes to the Documents dir (readable over AFC) and to stdout. Never crashes on a missing API.
var report: [String] = []
func rec(_ k: String, _ v: String) { report.append("\(k)=\(v)") }
func osMajor() -> Int { Int(UIDevice.current.systemVersion.split(separator: ".").first ?? "0") ?? 0 }

final class VC: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .white
    rec("os", UIDevice.current.systemVersion)
    rec("arch", MemoryLayout<Int>.size == 8 ? "arm64" : "32bit")

    // 1. anchors + activate (native on iOS 9/8+, shim below)
    let a = UIView(), b = UIView(); a.translatesAutoresizingMaskIntoConstraints = false; b.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(a); view.addSubview(b)
    NSLayoutConstraint.activate([
      a.topAnchor.constraint(equalTo: view.topAnchor, constant: 40), a.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
      a.widthAnchor.constraint(equalToConstant: 100), a.heightAnchor.constraint(equalToConstant: 50),
      b.topAnchor.constraint(equalTo: a.bottomAnchor, constant: 8), b.leftAnchor.constraint(equalTo: a.leftAnchor),
      b.widthAnchor.constraint(equalTo: a.widthAnchor, multiplier: 2), b.heightAnchor.constraint(equalTo: a.heightAnchor)
    ])
    view.layoutIfNeeded()
    rec("anchor.layout", "\(Int(a.frame.width))x\(Int(a.frame.height))@\(Int(a.frame.minY)) b=\(Int(b.frame.width))x\(Int(b.frame.height))@\(Int(b.frame.minY))")
    rec("anchor.expect", "100x50@40 b=200x50@98")

    // 2. isActive round trip
    let d = UIView(); d.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(d)
    NSLayoutConstraint.activate([d.topAnchor.constraint(equalTo: view.topAnchor, constant: 500), d.leadingAnchor.constraint(equalTo: view.leadingAnchor), d.heightAnchor.constraint(equalToConstant: 5)])
    let c = d.widthAnchor.constraint(equalToConstant: 120); c.isActive = true; view.layoutIfNeeded()
    let w1 = Int(d.frame.width); c.isActive = false; view.layoutIfNeeded(); rec("isActive.roundtrip", "\(w1)->\(Int(d.frame.width))"); rec("isActive.expect", "120->0")

    // 3. safe area guide constrains a view, and insets are real
    let s = UIView(); s.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(s)
    let g = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([ s.topAnchor.constraint(equalTo: g.topAnchor), s.leadingAnchor.constraint(equalTo: g.leadingAnchor),
      s.widthAnchor.constraint(equalToConstant: 30), s.heightAnchor.constraint(equalToConstant: 30) ])
    view.layoutIfNeeded()
    rec("safeArea.view.minY", "\(Int(s.frame.minY))")
    if #available(iOS 11.0, *) { rec("safeAreaInsets.top", "\(Int(view.safeAreaInsets.top))") } else { rec("safeAreaInsets.top", "n/a") }

    // 4. layout margins guide + layoutGuides
    let lg = UILayoutGuide(); view.addLayoutGuide(lg)
    let m = UIView(); m.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(m)
    NSLayoutConstraint.activate([ m.topAnchor.constraint(equalTo: lg.topAnchor), m.leadingAnchor.constraint(equalTo: lg.leadingAnchor),
      m.widthAnchor.constraint(equalToConstant: 10), m.heightAnchor.constraint(equalToConstant: 10),
      lg.topAnchor.constraint(equalTo: view.topAnchor, constant: 300), lg.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      lg.widthAnchor.constraint(equalToConstant: 10), lg.heightAnchor.constraint(equalToConstant: 10) ])
    view.layoutIfNeeded(); rec("layoutGuide.view", "\(Int(m.frame.minX)),\(Int(m.frame.minY))"); rec("layoutGuide.expect", "20,300")

    // 5. NSLayoutConstraint(item:) with a guide item (previously crashed on iOS 27)
    let n = UIView(); n.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(n)
    view.addConstraints([ NSLayoutConstraint(item: n, attribute: .top, relatedBy: .equal, toItem: view.safeAreaLayoutGuide, attribute: .top, multiplier: 1, constant: 5),
      NSLayoutConstraint(item: n, attribute: .centerX, relatedBy: .equal, toItem: view, attribute: .centerX, multiplier: 1, constant: 0),
      NSLayoutConstraint(item: n, attribute: .width, relatedBy: .equal, toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 20),
      NSLayoutConstraint(item: n, attribute: .height, relatedBy: .equal, toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 20) ])
    view.layoutIfNeeded(); rec("itemGuide.minY", "\(Int(n.frame.minY))")

    // 6. UIStackView
    let st = UIStackView(arrangedSubviews: [UIView(), UIView()]); st.axis = .vertical; st.distribution = .fillEqually; st.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(st)
    NSLayoutConstraint.activate([ st.topAnchor.constraint(equalTo: view.topAnchor, constant: 400), st.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      st.widthAnchor.constraint(equalToConstant: 60), st.heightAnchor.constraint(equalToConstant: 100) ])
    view.layoutIfNeeded(); rec("stackView.child", "\(Int(st.arrangedSubviews[0].frame.height))"); rec("stackView.expect", "50")

    // 7. refreshControl, scroll insets default
    let sv = UIScrollView(); let rc = UIRefreshControl(); sv.refreshControl = rc; rec("refreshControl", sv.refreshControl === rc ? "ok" : "lost")
    if #available(iOS 7.0, *) { rec("autoAdjustInsets", "\(self.automaticallyAdjustsScrollViewInsets)") } else { rec("autoAdjustInsets", "n/a") }

    // 8. bridging casts under threads (class-bit gate)
    let json = "{\"g\":[[{\"a\":\"1\"}],[{\"a\":\"2\"}]],\"s\":[\"x\"]}"
    let obj = try! JSONSerialization.jsonObject(with: json.data(using: .utf8)!, options: []) as! [String: Any]
    let one: Any = (obj["g"] as! [Any])[0]
    let grp = DispatchGroup()
    for _ in 0..<6 { grp.enter(); DispatchQueue.global().async { for _ in 0..<1500 { autoreleasepool { precondition((one as? [[String: Any]])?.count == 1); precondition((obj["s"] as? [String])?.count == 1) } }; grp.leave() } }
    grp.wait(); rec("cast.stress", "ok")

    // 9. dispatch objects: create/release many (double-release gate)
    for _ in 0..<2000 { autoreleasepool { let q = DispatchQueue(label: "p"); let g2 = DispatchGroup(); g2.enter(); q.async { g2.leave() }; g2.wait(); let sem = DispatchSemaphore(value: 0); q.async { sem.signal() }; sem.wait() } }
    rec("dispatch.churn", "ok")

    // 10. tagged strings through the bridge (probe gate)
    var tagged = 0; for i in 0..<5000 { let ns = ("a\(i % 9)" as NSString); tagged += ns.length }; rec("string.bridge", "\(tagged)")

    // 11. string drawing + line breaks (UILabel size)
    let lbl = UILabel(); lbl.numberOfLines = 0; lbl.text = String(repeating: "hello world ", count: 8); let sz = lbl.sizeThatFits(CGSize(width: 100, height: 1000)); rec("label.size", "\(Int(sz.width))x\(Int(sz.height))")

    // 12. collection view flow layout
    let cv = UICollectionView(frame: CGRect(x: 0, y: 0, width: 100, height: 200), collectionViewLayout: UICollectionViewFlowLayout()); view.addSubview(cv); rec("collectionView", "ok")


    // --- implementation identity: which side served each API on this OS ---
    func hasClass(_ n: String) -> Bool { NSClassFromString(n) != nil }
    func responds(_ o: AnyObject, _ sel: String) -> Bool { o.responds(to: NSSelectorFromString(sel)) }
    let anchorObj: AnyObject = a.topAnchor as AnyObject
    rec("id.UIView.topAnchor.class", String(describing: type(of: anchorObj)))
    rec("id.native.NSLayoutAnchor.exists", "\(hasClass("NSLayoutAnchor"))")
    rec("id.native.UILayoutGuide.exists", "\(hasClass("UILayoutGuide"))")
    rec("id.native.NSLayoutConstraint.setActive", "\(responds(c as AnyObject, "setActive:"))")
    rec("id.native.UIView.safeAreaLayoutGuide", "\(responds(view, "safeAreaLayoutGuide"))")
    rec("id.native.UIView.safeAreaInsets", "\(responds(view, "safeAreaInsets"))")
    rec("id.native.UIStackView.exists", "\(hasClass("UIStackView"))")
    rec("id.native.UIRefreshControl.exists", "\(hasClass("UIRefreshControl"))")
    rec("id.UIStackView.class", String(describing: type(of: st)))
    rec("id.UILayoutGuide.class", String(describing: type(of: lg)))
    rec("id.constraint.class", String(describing: type(of: c)))
    let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    try? report.joined(separator: "\n").write(toFile: dir + "/probe.txt", atomically: true, encoding: .utf8)
    print("PROBE-BEGIN\n" + report.joined(separator: "\n") + "\nPROBE-END")
  }
}
@UIApplicationMain final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(_ a: UIApplication, didFinishLaunchingWithOptions o: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    window = UIWindow(frame: UIScreen.main.bounds); window?.rootViewController = VC(); window?.makeKeyAndVisible(); return true }
}
