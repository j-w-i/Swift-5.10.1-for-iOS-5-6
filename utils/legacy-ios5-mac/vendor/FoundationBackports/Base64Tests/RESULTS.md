# Base64 validation results

## Corrected source

The original [overlay helper](../../../overlays/Foundation/LegacyBase64.swift),
not a test substitute, was compiled into every executable. Two bounded source
fixes were made after recording the original failures:

1. Defer CR/LF insertion until another encoded character follows, so a final
   64/76-column line has no trailing terminator.
2. Reject padding longer than two `=` characters while retaining quartet-count
   validation and accepting nonzero unused padding bits.

The existing helper signatures/ABI entry points and public Data signatures are
unchanged. No Data wrapper logic change was needed: native Swift Data string
and byte encoders both select 64-column wrapping if both line-length flags are
set. Supplemental native NSData string encoding instead chooses 76.

## Final counts, per platform

| Check | Result |
|---|---:|
| Full differential comparisons | 223,098 |
| Encoding cases / option combinations | 16,480 / 16 |
| Decoding cases | 52,726 |
| Byte vectors / seeded random vectors | 1,030 / 500 |
| Exhaustive malformed inputs | 9,331 |
| Valid Swift Data contract comparisons | **115,360; zero mismatches** |
| Independent helper round trips | **16,480; zero mismatches** |
| Strict padding / unused-bit checks | **27; all pass** |

Final platform evidence:

* Host report (`corrected-host-510/results.json` in the selected output root):
  Swift 5.10.1, explicit x86_64 macOS 12.0 target and MacOSX12.3 SDK,
  executed on macOS 27.0 build 26A428.
* iOS simulator report (`corrected-ios27/results.json` in the selected output root):
  Swift 6.4 in Swift-5 language mode, arm64 iOS simulator target, booted iPhone
  SE (3rd generation), iOS 27.0 build 24A434. iOS 18.5 was not installed.

Before/after SHA-256 comparisons passed for both runs. No installed toolchain
or shared overlay other than the specifically authorized helper was changed.

## Remaining raw differences (not suppressed)

The raw runner **returns 2**, not success:

| Raw difference | macOS host | iOS simulator |
|---|---:|---:|
| Supplemental NSData conflicting line flags | 2,872 | 2,872 |
| Malformed input: native Data byte decoder | 1,474 | 500 |
| Malformed input: native Data string decoder | 1,454 | 464 |
| Malformed input: supplemental NSData byte decoder | 1,474 | 1,474 |
| **Total raw mismatches** | **7,274** | **5,310** |

No remaining mismatch is valid Swift Data encoding or canonical decoding.
Native decoders differ on RFC-invalid input. For example, modern NSData may
turn padding-only `====` into a zero byte or accept excess padding; the helper
rejects it. Native iOS Data and native NSData do not even agree with each other
for all malformed inputs. These undocumented permissive behaviours are not
copied into the compatibility implementation. The full input/options/output
triples remain in each run's `mismatches.json`. These files are generated output,
not required source-checkout inputs; choose a disposable build root when rerunning.

The independent [valid-contract checker](check-valid-contract.py) reports raw
counts and then requires zero valid-contract mismatches plus all padding-policy
checks. Both final runs pass that gate.

## 1 KiB performance

50,000 iterations per operation, optimized builds, warmed paths, observable
checksums. These host/simulator timings are **not iOS 5 device performance**.

| Platform | Helper encode | Native encode | Helper decode | Native decode |
|---|---:|---:|---:|---:|
| macOS x86_64 host | 6.459 µs | 0.526 µs | 4.427 µs | 2.434 µs |
| arm64 iOS simulator | 3.252 µs | 0.395 µs | 2.832 µs | 0.376 µs |

No performance architecture rewrite was attempted; correctness and preservation
of the existing inlinable helper ABI took priority.

## Exact reproduction commands

Run from the compiler repository; choose fresh output directories on repeats:

```bash
HOST_SDK=/Users/jwalr/Applications/Xcode-13.4.1.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX12.3.sdk \
HOST_TARGET=x86_64-apple-macosx12.0 \
bash utils/legacy-ios5-mac/vendor/FoundationBackports/Base64Tests/run-base64-tests.sh \
  /Users/jwalr/legacy-fresh-proof/build-root/host/swift-5.10.1-RELEASE.xctoolchain/usr/bin/swiftc \
  "$PWD/foundation-work/base64/corrected-host-510" 50000

HOST_SDK=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.0.sdk \
HOST_TARGET=arm64-apple-ios18.0-simulator \
SIMCTL=/Applications/Xcode.app/Contents/Developer/usr/bin/simctl \
SIMULATOR_UDID=0827B93D-F8C3-49C4-9ACF-4A5064843B45 \
bash utils/legacy-ios5-mac/vendor/FoundationBackports/Base64Tests/run-base64-tests.sh \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc \
  "$PWD/foundation-work/base64/corrected-ios27" 50000

python3 utils/legacy-ios5-mac/vendor/FoundationBackports/Base64Tests/check-valid-contract.py \
  foundation-work/base64/corrected-host-510
python3 utils/legacy-ios5-mac/vendor/FoundationBackports/Base64Tests/check-valid-contract.py \
  foundation-work/base64/corrected-ios27
```

The two raw commands intentionally exit 2. Run them separately or explicitly
handle that exit status before invoking the distinct qualification gate.
Machine-exact compile/run command logs and compiler-version output are preserved
beside each report.
