# Swift 5.10.1 for iOS 5 + 6 — how the pieces fit

Three repos make up the whole project:

| Repo | What it is |
|---|---|
| **Swift-5.10.1-for-iOS-5-6** (this) | apple/swift `swift-5.10.1-RELEASE` + the iOS 5 ABI work. `patches/` holds the small changes to `llvm-project` (atomics gate) and `swift-driver`. `utils/legacy-ios5-mac/` holds the build pipeline. |
| **Swift-5.1.5-for-iOS-6** | The patched 5.1.5 fork. Built by this pipeline into the old runtime dylibs (`libswift*.dylib`, armv7) that iOS 5 and 6 builds ship in the app. The iOS 6 guide route must ship the build from this pipeline (compiler-rt `atomic.c` linked in, `-force_load libclang_rt.ios.a`), never the stock swift.org 5.1.5 dylibs, which import C11 atomics that iOS 6 lacks (`___atomic_store` -> dyld failure at launch). |
| **Legacy-Swift-Development-Kit** | The macOS app: installs the environment, picks the toolchain per project, builds unsigned IPAs. |

Compiler dependencies (llvm-project, cmark, swift-syntax, string-processing, swift-driver) are fetched from upstream at pinned refs by `fetch-deps.sh`. The MIT-licensed PSTCollectionView source runtime is vendored under `utils/legacy-ios5-mac/vendor/PSTCollectionView` so UIKit collection support builds from the clone without a package dependency.

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

## Toolchain-native collection views

The compiler automatically adapts UIKit collection declarations for iOS 5 device
targets. Public source spelling and the owning UIKit module stay unchanged;
applications and dependencies need no PST imports, bridging headers or collection
linker flags. The implementation is built from vendored source into the legacy
UIKit overlay. Compilation targeting iOS 6+ remains native UIKit. Selection is
compile-time: an iOS 5-targeted binary keeps the backport on newer systems.

See [collection integration and validation](utils/legacy-ios5-mac/COLLECTION-VIEW.md).
The updated compiler, source runtime and overlays were rebuilt and installed,
full static qualification passed, and an unchanged project archived successfully.
These are incremental source-build checks on the earlier fresh-clone build root,
not a new claim of full device execution or an empty-root build after this change.

Existing build roots use completion stamps: rerun `swift-510`, `overlays`,
`assemble` and `qualify-ios5` after updating to this change (clear those four
stage stamps only after verifying the build-root path). A fresh empty build root
needs no manual steps; `build-all.sh` builds and qualifies the integration.

## Distribution

Finished builds are published by [Legacy-Swift-Toolchain-Builds](https://github.com/j-w-i/Legacy-Swift-Toolchain-Builds)
as release assets (`swift-5.10.1-ios5.xctoolchain.tar.gz`,
`swift-5.1.5-ios6-runtime.xctoolchain.tar.gz`) together with a `release-manifest.json` the kit consumes. From a
finished build root:

```bash
cd Legacy-Swift-Toolchain-Builds
GITHUB_TOKEN=<repo-scoped token> tools/publish.sh --build-root "$LEGACY_BUILD_ROOT"
```

The script packages both toolchains, creates a draft release, uploads the assets and manifest, then publishes,
so the stable manifest URL
`https://github.com/j-w-i/Legacy-Swift-Toolchain-Builds/releases/latest/download/release-manifest.json` always
describes the newest build. A repository workflow re-hashes the released assets and re-attaches the manifest
whenever a release is published.

## Honest status
- Verified: a complete fresh-clone, empty-build-root run of `build-all.sh` (see below), including the 5.10.1 iOS stdlib
  built from source; the resulting toolchain passes every iOS 5 qualification check.
- Not source: the bootstrap compiler, Xcode and the pinned SDKs listed above (compiler bootstrap and platform SDKs).
- Not verified: device execution of any build (qualification is static; `deviceExecution` stays `pending`).

## Reproducibility proof (2026-10-26): fresh clone, empty build root
A fresh `git clone` of this repo into an empty directory, then `utils/legacy-ios5-mac/build-all.sh`, ran start to finish
with `EXIT=0` on an Apple Silicon Mac (macOS 27, 14 cores, Xcode 13.4.1 at a space-free path). 65 minutes wall clock,
stages and completion times:

```
tools 12:10:30   host-toolchain 12:10:46   fetch-510 12:12:18   llvm-510 12:13:15
swift-510 12:23:31   stdlib-510-ios 12:36:21   driver-510 12:48:01   baseline-510 12:49:07
fetch-515 12:49:08   compiler-515 12:49:46   crt-515 13:09:17   runtime-515 13:10:37
runtime-package-515 13:14:27   overlays 13:14:29   assemble 13:14:57   qualify-ios5 13:15:00
```

The only downloads were cmake, ninja and the swift.org bootstrap compiler (`swift-5.10.1.pkg`); the prebuilt
`swift-5.10.1-ios6.pkg` baseline is no longer fetched at all. Outputs:
- `out/swift-5.10.1-ios5.xctoolchain` - default resources are the source-built 5.10.1 iOS stdlib (14 fat dylibs,
  armv7+armv7s+arm64; 16 modules incl. `_Concurrency`), `usr/lib/swift_ios5` is the source-built 5.1.5 runtime plus
  the rebuilt legacy overlays (47 dylibs).
- `out/swift-5.1.5-ios6-runtime.xctoolchain[.tar.gz]` - 42 dylibs, `nm -u` shows zero `___atomic_*` imports.
- `out/ios5-qualification/qualification-evidence.json` - `staticBuild`, `abiClassMarking`, `ios5Archive`,
  `defaultIOS6Archive`, `imports` and `hostSignatures` all verified; `deviceExecution: pending`.
- The toolchain's default `libswiftCore.dylib` hash equals the merged source-built tree
  (`320d64f99a0de6acfedb52617ae133b064b7b68958a0644b03fb12388fdf4235`).

Qualification details: the iOS 5 executable has `LC_VERSION_MIN 5.0`, `LC_UNIXTHREAD` and no `LC_MAIN`; the default
resource tree builds a 7.0 armv7 executable with `LC_MAIN`; class marking PASS; the iOS 5 executable's Swift imports all
resolve against the source-built `swift_ios5` dylibs. A fresh clone of `Legacy-Swift-Development-Kit` builds with
`./build.sh --native` and its test suite passes.
- `package-runtime-515.sh`: packaged the from-source 5.1.5 runtime (42 dylibs); `nm -u` shows zero `___atomic_*`
  imports and `libswiftCore.dylib` defines `___atomic_store/load/compare_exchange` itself. It refuses the stock
  swift.org runtime (same check, reproduced: 3 imports reported).
Device execution: PENDING (not observed).

Known non-source inputs: the swift.org 5.10.1 bootstrap compiler (required because Swift is self-hosted), Xcode
13.4.1 and the pinned theos SDKs. The armv7/armv7s/arm64 Swift 5.10.1 standard library and modules are now built
from source by `build-ios-stdlib510.sh`, so no prebuilt Swift iOS stdlib package is used.
Paths containing spaces are rejected up front. An attached iOS device can make Xcode 13.4.1's xcodebuild hang
on this macOS; unplug it while building.
