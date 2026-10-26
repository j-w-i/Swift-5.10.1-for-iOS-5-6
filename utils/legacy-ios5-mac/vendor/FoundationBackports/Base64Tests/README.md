# Legacy Foundation Base64 differential tests

The runner compiles the **original** [overlay helper](../../../overlays/Foundation/LegacyBase64.swift)
with `-D LEGACY_IOS5` into a host/simulator executable. There is no copied or
substitute encoder/decoder. Before/after SHA-256 files prove the source stayed
unchanged during each run. Existing helper signatures remain unchanged.

## Reproduce from a clone

```
HOST_SDK=/absolute/MacOSX.sdk HOST_TARGET=x86_64-apple-macosx12.0 \
  bash run-base64-tests.sh /absolute/swiftc /absolute/fresh-output 50000
```

For an **already booted** simulator, supply its explicit identifier and simctl;
the script does not install runtimes, create devices or boot anything:

```
HOST_SDK=/absolute/iPhoneSimulator.sdk HOST_TARGET=arm64-apple-ios18.0-simulator \
SIMCTL=/absolute/simctl SIMULATOR_UDID=booted-device-uuid \
  bash run-base64-tests.sh /absolute/swiftc /absolute/fresh-output 50000
```

Actual compiler/version, exact shell-quoted compile/run commands, diagnostics,
source hashes, raw results, every mismatch and benchmark measurements are saved
in the fresh output directory. Raw differential exit status is **2 whenever any
mismatch exists**, including documented malformed-input/NSData differences.
Nothing is silently normalized or hidden. Infrastructure/policy failures are
nonzero as well; exact parity would return 0.

The separate qualification gate is:

```
python3 check-valid-contract.py /absolute/result-directory
```

That gate demands **zero valid Swift Data contract mismatches** and strict
padding-policy checks, while explicitly reporting the raw mismatch count.
It does not rewrite or discard the raw report.

## Coverage

* 1,030 byte vectors: lengths 0...256; exact 64/76-column boundaries; every
  individual byte; all 256 byte values; 500 seeded random vectors up to 4 KiB.
* All 16 combinations of line-length and CR/LF flags, including both line flags.
* Native Swift `Data.base64EncodedData` **and** `Data.base64EncodedString`, plus
  supplemental `NSData` encoding. String/Data are checked separately.
* Both decoding options against native Data-byte, Data-string and NSData-byte
  initializers; invalid UTF-8 is checked through the byte APIs.
* 9,331 exhaustive strings over `A Q / = ! newline` of lengths 0...5, explicit
  malformed padding/Unicode/junk cases, and 500 random binary decoder inputs.
* Independent helper round trips and 27 padding-policy/unused-bit checks.
* Repeated 1 KiB encode/decode benchmarks, warm-up and observable checksums.

## Contract and intentional malformed-input policy

Valid Swift Data is the oracle. Native Swift Data gives 64-column wrapping
precedence when **both** line flags are present; native NSData string encoding
instead prefers 76 on the tested systems. We match **Swift Data**, not both
incompatible oracles. Neither valid Data entry point emits a final line ending.
The upstream-derived helper now inserts separators only when more output follows.

Malformed input is explicitly bounded: padding is at most two `=` characters,
quartet counts must be correct, and valid data after padding is rejected.
Unknown bytes are skipped only with `ignoreUnknownCharacters`. Nonzero unused
padding bits are **accepted**, matching legitimate native decoder behaviour.
Native versions differ for RFC-invalid input, so permissive native bugs are not
reproduced: for example, modern NSData may decode `====` as a zero byte. These
differences remain in the raw mismatch report rather than being called parity.

No iOS 5 runtime/device qualification is claimed. A simulator running iOS 27 is
not evidence for historical iOS 7/18 semantics. Runtime availability is recorded
with each result; iOS 18.5 was not installed during this run.
