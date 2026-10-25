# Dispatch overlay for iOS < 6 (legacy-ios5)

Sources are Apple's `swift-corelibs-libdispatch` Swift overlay (`src/swift/`, commit
68875cb3bacc1061716ed8c91a4e408fa015552e), **byte-for-byte unmodified**. `DispatchStubs.cc` is not
vendored (it only serves platforms without Objective-C interop).

Why: before iOS 6, libdispatch objects are plain C pointers (`OS_OBJECT_HAVE_OBJC_SUPPORT=0`), so Apple's
Darwin overlay (ARC-managed ObjC objects) cannot be built. corelibs' overlay wraps the C handles in Swift
classes and calls `dispatch_retain/release` itself, which is the model iOS 5 needs.

`CDispatch/` is the only addition: a module map exposing the SDK's dispatch headers under the module name
`CDispatch`, which corelibs imports on every platform.

Selected only when `SWIFT_ENABLE_LEGACY_IOS5_CLASS_MARKING` and deployment < 6.0; every other configuration
builds Apple's Darwin overlay exactly as before.

One deliberate deviation from upstream bytes: `Dispatch.swift` does not `@_exported import Dispatch` (see comment there).
The shared shim header `stdlib/public/SwiftShims/DispatchOverlayShims.h` includes `<cdispatch/dispatch.h>` only when
`SWIFT_LEGACY_IOS5_CDISPATCH` is defined (set only for this overlay).
