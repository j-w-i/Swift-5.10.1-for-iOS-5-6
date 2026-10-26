# Swift 5.10.1 for iOS 5 + 6 — how the pieces fit

Three repos make up the whole project:

| Repo | What it is |
|---|---|
| **Swift-5.10.1-for-iOS-5-6** (this) | apple/swift `swift-5.10.1-RELEASE` + the iOS 5 ABI work. `patches/` holds the small changes to `llvm-project` (atomics gate) and `swift-driver`. `utils/legacy-ios5-mac/` holds the build pipeline. |
| **Swift-5.1.5-for-iOS-6** | The patched 5.1.5 fork. Built by this pipeline into the old runtime dylibs (`libswift*.dylib`, armv7) that iOS 5 and 6 builds ship in the app. The iOS 6 guide route must ship the build from this pipeline (compiler-rt `atomic.c` linked in, `-force_load libclang_rt.ios.a`), never the stock swift.org 5.1.5 dylibs, which import C11 atomics that iOS 6 lacks (`___atomic_store` -> dyld failure at launch). |
| **Legacy-Swift-Development-Kit** | The macOS app: installs the environment, picks the toolchain per project, builds unsigned IPAs. |

Everything else (llvm-project, cmark, swift-syntax, string-processing, swift-driver) is fetched from upstream at the `swift-5.10.1-RELEASE` tag by `fetch-deps.sh`; nothing is vendored.

## Requirements (macOS, Intel or Apple Silicon with Rosetta)
Xcode 13.4.1 (path in `XCODE_13_4_1_DEVELOPER_DIR`), a Swift 5.10.1 host toolchain (`SWIFT_5_10_1_HOST_TOOLCHAIN`), `cmake` >= 3.24, `ninja`, Python 3.8+, git. Nothing is read from `$HOME`; every path is an environment variable or argument.

## Pipeline
```bash
export LEGACY_BUILD_ROOT=/some/empty/dir
export XCODE_13_4_1_DEVELOPER_DIR=/path/to/Xcode-13.4.1.app/Contents/Developer
export SWIFT_5_10_1_HOST_TOOLCHAIN=/path/to/swift-5.10.1-RELEASE.xctoolchain
cd utils/legacy-ios5-mac
./fetch-deps.sh                 # 1. sources at pinned tags + patches (verified to apply cleanly)
./build-llvm510-mac.sh          # 2. clang/LLVM (hours)
./configure-swift510-mac.sh     # 3. swift-frontend + tools (hours)
# 4. swift-driver:  swift build -c debug  inside $LEGACY_BUILD_ROOT/src/swift-driver
# 5. prepare-legacy-resources.sh -> build-overlay-stage.sh -> build-atomic-backport.sh
#    -> link-overlay-stage.sh -> assemble-510-toolchain.sh  (see BOOTSTRAP.md for arguments)
# 6. build-ios-stdlib510.sh: Swift 5.10.1 iOS stdlib (armv7/armv7s/arm64) + armv7 compiler-rt
#    builtins compiled from source (no prebuilt iOS stdlib package)
# 7. stage-510-baseline.sh: compose the complete toolchain layout from the build products
# 8. check-class-marking.sh / check-driver-routing.sh, then qualify-ios5.sh (runs every iOS 5
#    qualification check, writes evidence and publishes the environment profile; the kit does this
#    automatically at Install Environment too)
```
`build-all.sh` wraps all of it, including the 5.1.5 compiler/runtime stages, `package-runtime-515.sh` (from-source 5.1.5
runtime for the iOS 6 guide route, refusing any runtime whose dylibs still import `___atomic_*`) and `qualify-ios5.sh`
(every iOS 5 qualification check plus the hash-bound `ios5-profile.json`). Set `LEGACY_ENVIRONMENT_ROOT` to an installed
kit environment and the final stage publishes the iOS 5 profile into it; otherwise it leaves the evidence in
`out/ios5-qualification` and the same one command publishes later:
`LEGACY_BUILD_ROOT=<root> utils/legacy-ios5-mac/qualify-ios5.sh --environment-root "<env>"`.
Inputs that are NOT source: the swift.org 5.10.1 bootstrap compiler (Swift is self-hosted), Xcode 13.4.1
(the SDKs, host clang and the `python3` the build uses), the pinned theos iPhoneOS13.7 SDK (the armv7-capable
platform SDK; only its libc++ headers are borrowed from Xcode), and `crt1.3.1.o` from an iPhoneOS 9.3 SDK
(theos/sdks). Every product the toolchain ships - the Swift frontend and driver, clang, compiler-rt builtins,
the iOS standard library and modules, the 5.1.5 runtime with its atomics, and the legacy overlays - is built
from these repos. No prebuilt Swift iOS standard library package is downloaded.

## Honest status
- Verified: `fetch-deps.sh` from an empty directory; both patches apply to fresh upstream tags; the already-built toolchain works with the app (combined iOS 5/6 builds).
- NOT verified: a from-scratch run of steps 2–6 on a clean machine (takes many hours). Steps 4–5 are still documented rather than wrapped in one `build-all.sh`; the old runtime inputs in step 5 are the least reproducible part.

## Reproducibility proof (2026-10-26)
From a fresh `git clone` of this repo into an empty directory, `utils/legacy-ios5-mac/build-all.sh` ran start to finish on
an Apple Silicon Mac (macOS 27, 14 cores, Xcode 13.4.1 at a space-free path) and produced `out/swift-5.10.1-ios5.xctoolchain`
(stages: tools, host-toolchain, baseline-toolchain, fetch-510, llvm-510, swift-510, driver-510, fetch-515, compiler-515, crt-515,
runtime-515, overlays, assemble). With that toolchain:
- `check-class-marking.sh`: PASS.
- sample app, iOS 5.0, armv7: ARCHIVE SUCCEEDED, LC_VERSION_MIN 5.0, LC_UNIXTHREAD, no LC_MAIN.
- sample app, iOS 7.0 floor, armv7+arm64 (guide route): ARCHIVE SUCCEEDED, LC_MAIN.
- `package-runtime-515.sh`: packaged the from-source 5.1.5 runtime (42 dylibs); `nm -u` shows zero `___atomic_*`
  imports and `libswiftCore.dylib` defines `___atomic_store/load/compare_exchange` itself. It refuses the stock
  swift.org runtime (same check, reproduced: 3 imports reported).
Device execution: PENDING (not observed).

Known non-source inputs: the swift.org 5.10.1 bootstrap compiler (required because Swift is self-hosted), Xcode
13.4.1 and the pinned theos SDKs. The armv7/armv7s/arm64 Swift 5.10.1 standard library and modules are now built
from source by `build-ios-stdlib510.sh`, so no prebuilt Swift iOS stdlib package is used.
Paths containing spaces are rejected up front. An attached iOS device can make Xcode 13.4.1's xcodebuild hang
on this macOS; unplug it while building.
