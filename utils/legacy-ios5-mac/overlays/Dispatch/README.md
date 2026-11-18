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
* `Wrapper.swift` adds internal `init(__raw:)` initializers to `DispatchGroup`, `DispatchSemaphore` and
  `DispatchIO`, and public `_convert<Class>ToRaw` / `_convertRawTo<Class>` functions at the end. The
  compiler calls these to bridge libdispatch handles in C and Objective-C signatures
  (`include/swift/ClangImporter/LegacyDispatchBridging.h`). On armv7s/arm64 their raw side is
  `AnyObject`: the SDK names the dispatch classes `DispatchQueue` and so on for Swift, so a signature
  naming corelibs' `OS_dispatch_queue` would not deserialize in clients.
* `_LegacyDispatchWrappers` (`Wrapper.swift`) keeps one live wrapper per handle; `DispatchQueue.main` and
  `global()` (`Queue.swift`) and the bridging functions go through it. `DispatchObject` is `Hashable` by
  identity, as stock Swift's NSObject-based dispatch objects are.
* `Private.swift` adds stock Swift's unavailable/renamed declarations for `dispatch_sync`,
  `dispatch_suspend`/`resume`/`activate`, `dispatch_set_target_queue`, `dispatch_group_create`/`enter`/
  `leave` and `dispatch_semaphore_create`; the overlay's own calls to those C functions are qualified
  `CDispatch.` so they never resolve to the stubs.
