import Foundation
protocol RouteSwiftTag {}
@objc protocol RouteObjCTag {}
class SwiftRouteCell: RouteTypedCell, RouteSwiftTag, RouteObjCTag {}
class SwiftRouteFlow: RouteTypedFlow {}
@_cdecl("runSwiftRouteProbe")
public func runSwiftRouteProbe() -> Int32 {
  _ = SwiftRouteCell.self
  _ = SwiftRouteFlow.self
  guard let lookedUpCell = NSClassFromString("SwiftRouteProbe.SwiftRouteCell"),
        let lookedUpFlow = NSClassFromString("SwiftRouteProbe.SwiftRouteFlow") else { return 9 }
  let cell: Any.Type = lookedUpCell
  let flow: Any.Type = lookedUpFlow
  guard cell is RouteTypedCell.Type else { return 1 }
  guard cell is RouteTypedReusable.Type else { return 2 }
  guard flow is RouteTypedFlow.Type else { return 3 }
  guard flow is RouteTypedLayout.Type else { return 4 }
  guard cell is RouteSwiftTag.Type else { return 10 }
  guard cell is RouteObjCTag.Type else { return 11 }
  guard !(flow is RouteTypedReusable.Type) else { return 5 }
  guard let objcCell = NSClassFromString("UICollectionViewCell"),
        let objcLayout = NSClassFromString("UICollectionViewLayout") else { return 6 }
  guard SwiftRouteCell.isSubclass(of: objcCell) else { return 7 }
  guard SwiftRouteFlow.isSubclass(of: objcLayout) else { return 8 }
  return 0
}
