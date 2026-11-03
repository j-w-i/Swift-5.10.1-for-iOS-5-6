import UIKit
import Foundation

@MainActor private func checkScrollRoot() -> Bool {
    var ok = true
    func check(_ name: String, _ value: Bool) { print("scroll-root: \(value ? "PASS" : "FAIL") \(name)"); ok = ok && value }
    func row(_ owner: UIView, _ a: UIView, _ x: RRLayoutAttribute, _ b: UIView?, _ y: RRLayoutAttribute, _ m: CGFloat = 1, _ c: CGFloat = 0, _ op: RRLayoutRelation = .equal) {
        owner.legacyAddConstraint(RRLayoutConstraint(item: a, attribute: x, relatedBy: op, toItem: b, attribute: y, multiplier: m, constant: c))
    }
    func pin(_ a: UIView, _ b: UIView, _ inset: CGFloat = 0) {
        for x in [RRLayoutAttribute.left, .right, .top, .bottom] { row(b,a,x,b,x,1,(x == .right || x == .bottom) ? -inset : inset) }
    }
    let root = UIView(frame: CGRect(x: 0,y: 0,width: 320,height: 436))
    let scroll = UIScrollView(), content = UIView(), bio = UIView(), bg = UIView()
    root.addSubview(scroll); scroll.addSubview(content); content.addSubview(bio); content.addSubview(bg)
    for v in [scroll,content,bio,bg] { v.legacyTranslatesAutoresizingMaskIntoConstraints = false }
    bio.legacyIntrinsicContentSize = CGSize(width: 215,height: 0)
    pin(scroll,root); pin(content,scroll); row(scroll,content,.width,scroll,.width)
    row(content,bio,.width,content,.width,0.8); row(content,bio,.top,content,.top,1,287)
    row(content,bio,.centerX,content,.centerX); row(content,bio,.bottom,content,.bottom)
    for x in [RRLayoutAttribute.left, .right, .top, .bottom] { row(content,bg,x,bio,x,1,(x == .right || x == .bottom) ? 10 : -10) }
    row(bg,bg,.height,nil,.notAnAttribute,1,44,.greaterThanOrEqual)
    root.legacyLayoutIfNeeded()
    check("empty height24",abs(bio.frame.height-24)<0.01)
    check("content promotes exactly scroll",content.legacyAutomaticLayoutRoot() === scroll)
    check("scroll itself stays scroll (no global climb)",scroll.legacyAutomaticLayoutRoot() === scroll)
    check("bio/message descendant stays self",bio.legacyAutomaticLayoutRoot() === bio)
    let before = LegacyLayoutMutation.generation
    bio.legacyIntrinsicContentSize = CGSize(width: 215,height: 100)
    content.legacyPerformAutomaticLayoutIfNeeded()
    check("mutation generation advanced",LegacyLayoutMutation.generation > before)
    check("local content height100",abs(bio.frame.height-100)<0.01)
    check("content grew387",abs(content.frame.height-387)<0.01)
    check("scroll content grew387",abs(scroll.contentSize.height-387)<0.01)
    let firstBio = bio.frame, firstContent = content.frame
    content.legacyPerformAutomaticLayoutIfNeeded()
    check("noop stable",bio.frame == firstBio && content.frame == firstContent)
    let cell = UIView(), label = UILabel(); content.addSubview(cell); cell.addSubview(label)
    cell.legacyTranslatesAutoresizingMaskIntoConstraints = false; label.legacyTranslatesAutoresizingMaskIntoConstraints = false
    check("message cell stays self",cell.legacyAutomaticLayoutRoot() === cell)
    check("nested label stays self",label.legacyAutomaticLayoutRoot() === label)
    let unbound = UIView(); scroll.addSubview(unbound); unbound.legacyTranslatesAutoresizingMaskIntoConstraints = false
    check("direct scroll child without bottom equation stays self",unbound.legacyAutomaticLayoutRoot() === unbound)
    let text = UITextView(), textContent = UIView(); text.addSubview(textContent); textContent.legacyTranslatesAutoresizingMaskIntoConstraints = false
    row(text,textContent,.bottom,text,.bottom)
    check("text view excluded",textContent.legacyAutomaticLayoutRoot() === textContent)
    let collection = UICollectionView(frame: .zero,collectionViewLayout: UICollectionViewFlowLayout()), collectionContent = UIView()
    collection.addSubview(collectionContent); collectionContent.legacyTranslatesAutoresizingMaskIntoConstraints = false
    row(collection,collectionContent,.bottom,collection,.bottom)
    check("collection excluded",collectionContent.legacyAutomaticLayoutRoot() === collectionContent)
    print("scroll-root frames empty24->\(bio.frame.height) content=\(content.frame) scrollContent=\(scroll.contentSize)")
    return ok
}
MainActor.assumeIsolated {
    setbuf(stdout,nil)
    let nativeUpdates = observeUpdates()
    LegacyAutoLayout.installForLegacyNames()
    let scrollOK = checkScrollRoot()
    let legacyUpdates = observeUpdates()
    precondition(nativeUpdates == [["C","P"],[],["C"],["P"]] && legacyUpdates == nativeUpdates,"callback parity")
    print("callbacks: PASS")
    precondition(runLayoutTest(),"existing layout regression")
    precondition(scrollOK,"narrow scroll root regression")
    print("scroll-content-root: PASS (synthetic intrinsic; no UILabel hybrid)")
}
