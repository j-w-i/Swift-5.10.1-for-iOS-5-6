//
//  autolayout_cell_scroll_bench.swift
//  Legacy-engine cost of scrolling a list of Friends-style cells (Neocord2's FriendCell).
//
//  Each cell is frame-positioned by a collection view and contains, exactly as FriendCell constrains it:
//  a background pinned to the content view, a horizontal centre-aligned fill stack (OAStackView's
//  constraints written out: leading chain with 8pt spacing, top >= / bottom <= / centerY per arranged
//  view), a 40x40 avatar, a label, and a 12x12 presence dot pinned to the avatar's bottom-right corner.
//  The container is registered as `PSTCollectionView` so the engine treats it as the app's collection view.
//
//  Every frame scrolls 25pt (1500 pt/s at 60 Hz), recycles cells that left the top to the bottom with a new
//  name (the iOS 5 -setText: hook's invalidation), re-applies every visible cell's centre the way PST's
//  applyLayoutAttributes does, and runs layoutIfNeeded. Prints the time per frame and a checksum of every
//  solved frame: an optimisation must leave the checksum unchanged.
//
import UIKit
import Foundation

@MainActor
final class BenchCell {
    let cell = UIView()
    let content = UIView()
    let glass = UIView()
    let stack = UIView()
    let avatar = UIImageView()
    let label = UILabel()
    let presence = UIView()

    init(frame: CGRect) {
        cell.frame = frame
        content.frame = cell.bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cell.addSubview(content)
        for v in [glass, stack, presence] { content.addSubview(v); v.legacyTranslatesAutoresizingMaskIntoConstraints = false }
        for v in [avatar, label] { stack.addSubview(v as UIView); (v as UIView).legacyTranslatesAutoresizingMaskIntoConstraints = false }
        label.font = .systemFont(ofSize: 17)
        func k(_ a: UIView, _ x: RRLayoutAttribute, _ r: RRLayoutRelation, _ b: UIView?, _ y: RRLayoutAttribute,
               _ c: CGFloat, on owner: UIView) {
            let c = RRLayoutConstraint(item: a, attribute: x, relatedBy: r, toItem: b, attribute: y, multiplier: 1, constant: c)
            c.legacyIsActive = true
            owner.legacyAddConstraint(c)
        }
        // NSLayoutConstraint.activate installs on the nearest common ancestor.
        k(glass, .leading, .equal, content, .leading, 0, on: content)
        k(glass, .trailing, .equal, content, .trailing, 0, on: content)
        k(glass, .top, .equal, content, .top, 0, on: content)
        k(glass, .bottom, .equal, content, .bottom, 0, on: content)
        k(stack, .leading, .equal, content, .leading, 8, on: content)
        k(stack, .trailing, .equal, content, .trailing, -8, on: content)
        k(stack, .top, .equal, content, .top, 4, on: content)
        k(stack, .bottom, .equal, content, .bottom, -4, on: content)
        k(avatar, .width, .equal, nil, .notAnAttribute, 40, on: avatar)
        k(avatar, .height, .equal, nil, .notAnAttribute, 40, on: avatar)
        k(presence, .width, .equal, nil, .notAnAttribute, 12, on: presence)
        k(presence, .height, .equal, nil, .notAnAttribute, 12, on: presence)
        k(presence, .bottom, .equal, avatar, .bottom, 0, on: content)
        k(presence, .trailing, .equal, avatar, .trailing, 0, on: content)
        // OAStackView, horizontal, distribution fill, alignment center, spacing 8 (installed on the stack).
        k(avatar, .leading, .equal, stack, .leading, 0, on: stack)
        k(label, .leading, .equal, avatar, .trailing, 8, on: stack)
        k(stack, .trailing, .equal, label, .trailing, 0, on: stack)
        for v in [avatar as UIView, label as UIView] {
            k(v, .top, .greaterThanOrEqual, stack, .top, 0, on: stack)
            k(stack, .bottom, .greaterThanOrEqual, v, .bottom, 0, on: stack)
            k(v, .centerY, .equal, stack, .centerY, 0, on: stack)
        }
    }

    func configure(_ name: String) {
        label.text = name
        // What the iOS 5 -[UILabel setText:] hook does on a changed string (UICLabelSetText ->
        // rr_a_invalidateIntrinsicContentSize); modern UIKit has its own and the hook is not installed here.
        LegacyViewState.existing(of: label)?.systemIntrinsicCache = nil
        LegacyLayoutMutation.bump()
        label.legacySetNeedsUpdateConstraints()
    }
}

@MainActor
func runBench() {
    // Register the class name the engine recognises as a collection view before the engine first looks.
    if NSClassFromString("PSTCollectionView") == nil, let cls = objc_allocateClassPair(UIScrollView.self, "PSTCollectionView", 0) {
        objc_registerClassPair(cls)
    }
    LegacyAutoLayout.installForLegacyNames()
    let frames = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 600 : 600
    let names = ["alice", "Bob the Builder", "chris", "a much longer display name here", "dee", "Eve", "frank_99",
                 "Gwen Stacy", "hal", "Ingrid Bergman", "j", "Kim"]
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
    let scrollClass = NSClassFromString("PSTCollectionView") as! UIScrollView.Type
    let list = scrollClass.init(frame: CGRect(x: 10, y: 74, width: 300, height: 342))
    window.addSubview(list)
    window.isHidden = false
    let pitch: CGFloat = 60
    let pool = Int(ceil(342 / pitch)) + 2
    list.contentSize = CGSize(width: 300, height: pitch * CGFloat(frames) * 0.5 + 400)
    var cells: [(BenchCell, Int)] = []
    for i in 0..<pool {
        let c = BenchCell(frame: CGRect(x: 10, y: CGFloat(i) * pitch, width: 280, height: 50))
        list.addSubview(c.cell)
        c.configure(names[i % names.count])
        cells.append((c, i))
    }
    window.layoutIfNeeded()

    var offset: CGFloat = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<frames {
        offset += 25
        list.contentOffset = CGPoint(x: 0, y: offset)
        for index in cells.indices {
            var (c, row) = cells[index]
            if CGFloat(row) * pitch + 50 < offset {
                row += pool
                c.configure(names[row % names.count])
                cells[index] = (c, row)
            }
            // PST re-applies the layout attributes of every visible cell.
            c.cell.center = CGPoint(x: 10 + 140, y: CGFloat(row) * pitch + 25)
        }
        window.layoutIfNeeded()
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6

    var checksum: UInt64 = 1469598103934665603
    for (c, row) in cells.sorted(by: { $0.1 < $1.1 }) {
        for v in [c.cell, c.content, c.glass, c.stack, c.avatar, c.label, c.presence] {
            for x in [v.frame.minX, v.frame.minY, v.frame.width, v.frame.height] {
                checksum = (checksum ^ UInt64(bitPattern: Int64((x * 4).rounded()))) &* 1099511628211
            }
        }
        if row == cells.map({ $0.1 }).max() {
            print("cell-frames row=\(row) stack=\(c.stack.frame) avatar=\(c.avatar.frame) label=\(c.label.frame) presence=\(c.presence.frame)")
        }
    }
    print(String(format: "cell-scroll-bench: frames=%d total=%.1f ms per-frame=%.3f ms checksum=%016llx",
                 frames, elapsed, elapsed / Double(frames), checksum))
}

MainActor.assumeIsolated { runBench() }
