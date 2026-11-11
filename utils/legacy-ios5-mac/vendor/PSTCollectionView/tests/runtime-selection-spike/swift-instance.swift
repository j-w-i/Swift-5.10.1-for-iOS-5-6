import Foundation
private var madeCount: Int32 = 0
private var reusedCount: Int32 = 0
private var layoutCount: Int32 = 0
private var corruptionCount: Int32 = 0
private let expectedSentinel: UInt64 = 0x1234abcd9876fedc
private protocol SwiftInstanceTag {}
@objc private protocol ObjCInstanceTag {}
@objc(RouteSwiftEngineCell)
final class RouteSwiftEngineCell: RouteTypedCell, SwiftInstanceTag, ObjCInstanceTag {
  var sentinel: UInt64 = 0x1234abcd9876fedc
  var state: String = "persistent Swift cell state"
  var values: [Int32] = [3, 5, 8, 13]
  var row: Int32 = -1
  let title: UILabel
  override init(frame: CGRect) {
    title = UILabel(frame: CGRect(x: 8, y: 0, width: 280, height: 40))
    super.init(frame: frame)
    madeCount += 1
    title.backgroundColor = UIColor.clear
    contentView.addSubview(title)
  }
  required init?(coder: NSCoder) { fatalError("Not used by this class-registration test") }
  override func prepareForReuse() {
    super.prepareForReuse()
    reusedCount += 1
    if sentinel != expectedSentinel || state != "persistent Swift cell state" || values != [3, 5, 8, 13] {
      corruptionCount += 1
    }
    row = -1
    title.text = nil
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    layoutCount += 1
    title.frame = CGRect(x: 8, y: 0, width: 280, height: 40)
  }
}
@_cdecl("routeSwiftCellClass")
public func routeSwiftCellClass() -> AnyClass { RouteSwiftEngineCell.self }
@_cdecl("routeSwiftConfigureCell")
public func routeSwiftConfigureCell(_ object: AnyObject, _ row: Int32) {
  guard let cell = object as? RouteSwiftEngineCell else { corruptionCount += 1; return }
  cell.row = row
  cell.title.text = "Row \(row)"
}
@_cdecl("routeSwiftValidateCell")
public func routeSwiftValidateCell(_ object: AnyObject, _ row: Int32) -> Int32 {
  guard let cell = object as? RouteSwiftEngineCell else { return 1 }
  guard object is RouteTypedReusable else { return 2 }
  guard object is SwiftInstanceTag, object is ObjCInstanceTag else { return 3 }
  guard !(object is RouteTypedLayout) else { return 4 }
  guard cell.sentinel == expectedSentinel, cell.state == "persistent Swift cell state",
        cell.values == [3, 5, 8, 13] else { return 5 }
  guard cell.row == row, cell.title.text == "Row \(row)", cell.title.superview === cell.contentView else { return 6 }
  return corruptionCount == 0 ? 0 : 7
}
@_cdecl("routeSwiftMadeCount") public func routeSwiftMadeCount() -> Int32 { madeCount }
@_cdecl("routeSwiftReuseCount") public func routeSwiftReuseCount() -> Int32 { reusedCount }
@_cdecl("routeSwiftLayoutCount") public func routeSwiftLayoutCount() -> Int32 { layoutCount }
