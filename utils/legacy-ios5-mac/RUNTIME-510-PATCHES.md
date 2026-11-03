# Swift 5.10 runtime for iOS 5.0 — patch inventory

The legacy runtime is the stock Swift 5.10.1 standard library built by the 5.10 compiler for
`armv7-apple-ios5.0`, so compiler and runtime share one ABI generation. Everything is behind
one CMake switch, `-DSWIFT_ENABLE_LEGACY_IOS5_CLASS_MARKING=ON`, which defines
`SWIFT_LEGACY_IOS5_CLASS_MARKING` and `SWIFT_LEGACY_IOS5` for the runtime and adds the
compiler flag. Default builds are unchanged.

| File | Change | Why iOS 5 needs it |
|---|---|---|
| `CMakeLists.txt`, `stdlib/public/CMakeLists.txt` | option + defines | single switch for ABI + OS paths |
| `stdlib/public/core/CMakeLists.txt` | link Foundation, CoreFoundation | runtime reads the OS version via CF |
| `include/swift/Threading/Impl/Darwin.h` | `pthread_mutex_t` instead of `os_unfair_lock` | `os_unfair_lock` is iOS 10 |
| `stdlib/public/runtime/SwiftObject.mm` | skip `objc_readClassPair` | iOS 8; objc4 realizes lazily from the class_ro_t |
| `stdlib/public/runtime/ImageInspectionMachO.cpp` | `_dyld_register_func_for_add_image` | `objc_addLoadImageFunc` absent |
| `stdlib/public/runtime/EnvironmentVariables.cpp` | `_NSGetEnviron()` | libSystem does not export `environ` to dylibs |
| `stdlib/public/stubs/Availability.mm` | read `SystemVersion.plist` with CoreFoundation | `os_system_version_get_current_version` is iOS 12 |

Build requirements (not source patches): C/C++ with `-marm`; the iOS 5-era libc++ headers
(`-nostdinc++ -isystem …/libcxx/include`) so no `std::` symbol outside the iOS 5 libc++ is imported;
`SwiftOnoneSupport` shipped (it holds the generic prespecializations such as `Array<Any>` literals).

## Gates (all in `qualify-ios5.sh`, none optional)
`check-runtime-deployment.py` (floor 5.0) · `check-runtime-initializers.py` (dyld constructors only
register ObjC) · `check-macho-initializers.py` (ARM/Thumb of constructors) · `check-objc-method-states.py`
(ARM/Thumb of every Objective-C IMP) · `check-ios5-imports.py` (every strong import exists in the
library it is bound to on iOS 5.1.1, derived from Apple's own 9B206 image).

## Not shipped on iOS 5, deliberately
`os`, `simd`, `Accelerate`, `SceneKit`, `SpriteKit`, `ModelIO`, `GameplayKit` Swift overlays (need
os_log/SIMD facilities that do not exist there). Their modules are removed at assembly so no client
can reference an absent library.
