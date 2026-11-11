import Foundation
final class SwiftProtocolSource: NSObject, RouteTypedSource, RouteTypedFlowDelegate, RouteTypedPrefetch {
  func collectionView(_ cv: RouteTypedCollection, numberOfItemsInSection section: Int) -> Int { 0 }
  func collectionView(_ cv: RouteTypedCollection, cellForItemAt path: IndexPath) -> RouteTypedCell {
    fatalError("No collection or cells are allocated by this protocol-only test")
  }
  func collectionView(_ cv: RouteTypedCollection, prefetchItemsAt paths: [IndexPath]) {}
}
@_cdecl("routeSwiftProtocolObject")
public func routeSwiftProtocolObject() -> AnyObject { SwiftProtocolSource() }
@_cdecl("routeSwiftCheckProtocols")
public func routeSwiftCheckProtocols(_ object: AnyObject) -> Int32 {
  var mask: Int32 = 0
  if !(object is RouteTypedSource) { mask |= 1 }
  if !(object is RouteTypedDelegate) { mask |= 2 }
  if !(object is RouteTypedFlowDelegate) { mask |= 4 }
  if !(object is RouteTypedPrefetch) { mask |= 8 }
  return mask
}
