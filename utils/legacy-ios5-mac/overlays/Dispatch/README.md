# Dispatch overlay for iOS < 6 (legacy-ios5)

Sources are Apple's `swift-corelibs-libdispatch` Swift overlay (`src/swift/`, commit
68875cb3bacc1061716ed8c91a4e408fa015552e), **byte-for-byte unmodified**. `DispatchStubs.cc` is not
vendored (it only serves platforms without Objective-C interop).

Why: before iOS 6, libdispatch objects are plain C pointers (`OS_OBJECT_HAVE_OBJC_SUPPORT=0`), so Apple's
Darwin overlay (ARC-managed ObjC objects) cannot be built. corelibs' overlay wraps the C handles in Swift
classes and calls `dispatch_retain/release` itself, which is the model iOS 5 needs.

`CDispatch/` is the only addition: a module map and corelibs' own dispatch headers under the module name
`CDispatch`, which corelibs imports on every platform (not the SDK's headers: their
`DISPATCH_SWIFT3_OVERLAY` renames and ObjC-object typedefs would hide the raw C API this overlay wraps).

Selected only when `SWIFT_ENABLE_LEGACY_IOS5_CLASS_MARKING` and deployment < 6.0; every other configuration
builds Apple's Darwin overlay exactly as before.

Deliberate deviations from upstream bytes:
* `Dispatch.swift` does not `@_exported import Dispatch` (see comment there).
* `CDispatch/cdispatch/object.h` adds the SDK's `_dch` member to the legacy `dispatch_object_t` union. The
  Swift module `Dispatch` is treated as a Swift overlay of the SDK's Clang `Dispatch` module, so importing it
  also loads the SDK module; clang's module ODR check compares both union definitions. Every member is a
  pointer, so size, alignment and ABI are unchanged.
The shared shim header `stdlib/public/SwiftShims/DispatchOverlayShims.h` includes `<cdispatch/dispatch.h>` only when
`SWIFT_LEGACY_IOS5_CDISPATCH` is defined (set only for this overlay).
