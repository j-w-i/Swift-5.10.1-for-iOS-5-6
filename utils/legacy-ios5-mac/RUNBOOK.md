# End-to-end runbook: isolated Swift 5.10 iOS 5 toolchain

Every step is explicit, serial and non-destructive: no global `xcode-select`, no
installed-toolchain replacement, no `rm -rf` of build trees. Use `nice -n 15`.
Run from the build root that contains `src/`, `build/`, `logs/`, `out/`.

Set once per shell:

```bash
export DEVELOPER_DIR="$HOME/Applications/Xcode-13.4.1.app/Contents/Developer"  # side-by-side Xcode
B="$HOME/swift-5.10-ios5-build"
X="$DEVELOPER_DIR"
SDK="$X/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk"
HOST="$HOME/Library/Developer/Toolchains/swift-5.10.1-RELEASE.xctoolchain"
```

## 1. LLVM/Clang

```bash
bash build-llvm510-mac.sh          # incremental; -j4 for LLVM only
bash configure-swift510-mac.sh --configure-only   # after LLVM main targets
```

The configure step also builds the extra LLVM JIT/LTO archives that Clang's
executable does not, then stops.

## 2. Patched Swift frontend

```bash
bash configure-swift510-mac.sh     # builds missing LLVM archives, then swift-frontend
```

Re-run after any C++ frontend edit; ninja resumes incrementally. Do not clean.

## 3. ABI regressions (patched compiler required)

```bash
bash src/swift/utils/legacy-ios5-mac/check-class-marking.sh \
  "$B/build/swift/bin/swift-frontend" "$B/out/class-marking-check"
bash src/swift/utils/legacy-ios5-mac/check-driver-routing.sh \
  "$B/build/swift/bin/swift-frontend" "$SDK" "$B/out/driver-routing"
```

`check-class-marking.sh` needs the real `swift-frontend`. It compares stock,
`-enable-legacy-ios5-class-marking`, `-enable-legacy-ios5-runtime` and an explicit
disable, including the unnamed/byte-packed generic RO template.

## 4. Overlay resources and objects

```bash
bash src/swift/utils/legacy-ios5-mac/prepare-legacy-resources.sh \
  --swift510-resource "$HOST/usr/lib/swift" \
  --swift51-source "$HOME/swift-ios5-build/src/swift" \
  --output "$B/bootstrap-vN"            # NEW path each time

bash src/swift/utils/legacy-ios5-mac/build-overlay-stage.sh \
  "$B/bootstrap-vN" "$B/build/swift/bin/swift-frontend" "$SDK" --legacy-marking
```

`--legacy-marking` selects `-enable-legacy-ios5-runtime` and a real 5.0 target
instead of the stock-compiler probe target 7.0.

## 5. Link the seven overlays and native helpers from source

```bash
LLVM_CONFIG_INCLUDE_DIR="$HOME/swift-ios5-build/build/macos/llvm-macosx-x86_64/include" \
LINK_OUTPUT_NAME=linked510-min5 IOS_DEPLOYMENT_TARGET=5.0 \
bash src/swift/utils/legacy-ios5-mac/link-overlay-stage.sh \
  "$B/bootstrap-vN" "$SDK" "$HOME/swift-ios5-build/build/runtime-ios5" \
  "$HOME/swift-ios5-build/build/crt-armv7-ios50/libclang_rt.builtins_armv7_ios.a" \
  "$B/build/llvm/bin/clang" "$HOME/swift-ios5-build/src/llvm-project/libcxx/include"
```

Requires a patched Clang: stock Clang refuses >=12-byte atomics below iOS 7.
The generated `libLegacyRuntimeBackports.a` is linked lazily; only compiler-rt
builtins are force-loaded, matching the successful proofs.

## 6. Full-source smoke + audit

```bash
LINK_OUTPUT_NAME=linked510-min5 bash src/swift/utils/legacy-ios5-mac/build-apitest-stage.sh \
  "$B/bootstrap-vN" "$B/build/swift/bin/swift-frontend" "$SDK" \
  "$HOME/swift-ios5-build/build/runtime-ios5" \
  "$HOME/swift-ios5-build/sdks/theos-sdks/iPhoneOS9.3.sdk/usr/lib/crt1.3.1.o" \
  "$HOME/swift-ios5-build/build/crt-armv7-ios50/libclang_rt.builtins_armv7_ios.a" \
  "$B/build/llvm/bin/clang" "$HOME/swift-ios5-build/apitest.swift" --legacy
```

Then run the import screen over a bundle whose dylibs live in `Frameworks/`
(the executable's only rpath). Static PASS is screening: it does not prove
runtime behavior.

## 7. Assemble the isolated toolchain (never installs or selects)

```bash
LINK_OUTPUT_NAME=linked510-min5 bash src/swift/utils/legacy-ios5-mac/assemble-510-toolchain.sh \
  "$HOST" "$B/build/swift/bin/swift-frontend" \
  "$B/src/swift-driver/.build/x86_64-apple-macosx/release/swift-driver" \
  "$B/bootstrap-vN" "$HOME/swift-ios5-build/build/runtime-ios5" \
  "$B/bootstrap-vN/probes/linked510-min5/libLegacyRuntimeBackports.a" \
  "$HOME/swift-ios5-build/sdks/theos-sdks/iPhoneOS9.3.sdk/usr/lib/crt1.3.1.o" \
  "$B/out/swift-5.10.1-ios5-EXPERIMENTAL.xctoolchain"
```

Default resources stay the untouched baseline; iOS 5 resources live in the
separate `usr/lib/swift_ios5` slot.

## 8. Qualify iOS 5 (one command, no hand-written evidence)

```bash
LEGACY_BUILD_ROOT="$B" bash src/swift/utils/legacy-ios5-mac/qualify-ios5.sh \
  --environment-root "$HOME/Library/Application Support/Legacy Swift Development Kit/Environments/<env>"
```

It installs the assembled toolchain, runs all five checks (static build, ABI
class marking, iOS 5 link with LC_UNIXTHREAD, default iOS 6 resource tree, import
closure), writes hash-bound evidence under `<env>/Qualification/` and publishes
`<env>/ios5-profile.json` through `publish-ios5-profile.py`, which re-verifies
every hash and host signature. `build-all.sh` runs the same evidence step
(`qualify-ios5`) and publishes when `LEGACY_ENVIRONMENT_ROOT` is set; the kit runs
it automatically at Install Environment using its bundled copy. `pending` stays
`pending`; nothing claims device validation.

## 9. Device execution

Not performed anywhere in this repository. Only a real iOS 5 device run (or a
logged failure) upgrades the claim. Simulator, modern-OS and static screens do
not.
