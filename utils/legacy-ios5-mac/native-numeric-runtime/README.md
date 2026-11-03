# Native Float/Double numeric runtime backport

This is an **SDK-owned, additive source backport**, not an application helper or
`TimeInterval` rewrite. Nothing here installs or edits a toolchain, profile,
existing SDK build script, application, package, canonical stdlib, or old runtime.
Integration into the SDK's backports/overlay linkage is reserved for lead review.

## Shipping API and identity

Only the genuine modern standard-library initializers ship:

```swift
extension Double { public init?(_ text: Substring) }
extension Float { public init?(_ text: Substring) }
```

The compiler, not a hand-written ABI declaration, derives their native symbols:

```
_$sSdySdSgSscfC
_$sSfySfSgSscfC
```

[NativeNumeric.swift](<NativeNumeric.swift>) uses the source-supported
`@_originallyDefinedIn(module: "Swift", iOS 5.0)` mechanism with an iOS 5.0
implementation extension. Using relocation version **14.0 is not acceptable**:
that creates `$ld$hide$os5...` directives. The builder rejects any hide directive.
There is no `@_silgen_name`, guessed Swift calling convention, binary patch, or
runtime-floor relabeling.

No Swift module/interface is emitted or installed. Existing public SDK Swift
module declarations retain their genuine iOS 14 availability; this scope does
not alter global module availability. The private C header/Clang module are
build inputs only, imported implementation-only, never SDK public surface.
[NumericParsing.cpp](<NumericParsing.cpp>) defines hidden prefixed helpers. All
other Swift implementation details are local or weak-private-external; the raw
archive has exactly two non-private external definitions. A linked overlay
exports exactly those two symbols **without an export filter**.

## Source behavior, not old-witness forwarding

The Swift parsing bodies derive from canonical Swift 5.10.1
[FloatingPointParsing.swift.gyb:198–219](<../../../stdlib/public/core/FloatingPointParsing.swift.gyb#L198-L219>).
Changes are expanding Float/Double, private function/C names, a local result,
and using scoped `withUnsafeMutablePointer` instead of stdlib-internal
`_withUnprotectedUnsafeMutablePointer`. There is no different scanner.

The C++ implementation extracts the Apple C-locale path and signaling-NaN
special case from canonical
[Stubs.cpp:144–150](<../../../stdlib/public/stubs/Stubs.cpp#L144-L150>),
[280–293](<../../../stdlib/public/stubs/Stubs.cpp#L280-L293>), and
[386–449](<../../../stdlib/public/stubs/Stubs.cpp#L386-L449>).
Only private symbol naming, unused `huge` argument removal, and omission of
non-Apple/Float16/Float80 paths differ. Apple `strtod_l` / `strtof_l` receive a
null locale, meaning the C locale; plain locale-sensitive `strtod` is not used.
The original Apache 2.0 + Runtime Library Exception notice and full
[license](<LICENSE.txt>) are retained.

Important exact behaviors:

- Reject empty/initial NUL and leading ASCII tab, LF, VT, FF, CR, or space.
- Preserve libc overflow to infinity and underflow to signed zero. Do not add
  the old helper's ERANGE rejection.
- Validate `endPtr != nil && endPtr[0] == 0`, **not** consumed Swift string length.
  Consequently `"12\0junk"` accepts 12, exactly as the canonical 5.10 code does.
- Preserve canonical C++ signaling-NaN handling, including ignoring a leading
  minus sign in the exact `snan` special case and its original bit-pattern TODO.
  Do not substitute current-host Swift's changed NaN parser rules.

Existing Swift 5.1 generic `LosslessStringConvertible` witnesses and old C
parser helpers are untouched. Old-runtime generic/witness paths retain their
old-native semantics; imported/inlined SDK generic fallback still calls the
old C helpers. The modern nongeneric Substring entry has the canonical 5.10
source behavior. **This is not a uniform-5.10 String/witness behavior claim.**
On old iOS the existing availability branch can continue using its fallback;
this archive fixes the missing modern ABI branch's linkage without app changes.

Float16 is not repaired: the old Core lacks its entire implementation surface.
Float80 is not an armv7 API. Neither is part of the two-entry archive.

## Build (portable explicit inputs, no downloads)

The new sibling [builder](<../build-native-numeric-runtime.sh>) takes six
**absolute** paths, refusing an existing output directory:

```sh
bash utils/legacy-ios5-mac/build-native-numeric-runtime.sh \
  "$SDK" "$CLANG" "$AR" "$SWIFTC" "$RES" "$OUT"
```

`SDK` is an iPhoneOS SDK; `CLANG` / `AR` are compatible Apple tools; `SWIFTC`
is the installed legacy-enabled Swift 5.10 compiler; `RES` is its selected
`usr/lib/swift_ios5` resource directory, not the default runtime directory.
`OUT` is new. Python 3 and macOS `/usr/bin/nm` / `/usr/bin/otool` are also used.
No package manager, extra toolchain, large download, or network is required.

C++ uses `armv7-apple-ios5.0 -marm -O2 -g0 -ffile-prefix-map`, explicit libc++
**headers**, no exceptions/RTTI, and hidden visibility. It imports no libc++
runtime functions. Swift uses `-O`, the same target, `-file-prefix-map`,
`-enable-legacy-ios5-runtime -runtime-compatibility-version none` and private
Clang module input. Swift debug information is not enabled. Compiler temps and
module caches stay under `OUT`. Swift autolinking is disabled for this bounded
archive and link probe: Core is linked explicitly, and every actual symbol
import is checked. Unrelated Concurrency/StringProcessing/5.6 libraries are not
loaded merely because the modern SDK mentions their modules.

The output archive is `libswiftLegacyNativeNumeric.a`, plus command transcripts,
symbol/load-command audits, source/tool/Core hashes and build manifest, notices,
and the two-symbol export allowlist. Failed build directories are retained for
inspection; choose a new output path rather than overwriting or deleting them.

## Tests

- [test-link.sh](<tests/test-link.sh>): `SDK CLANG SWIFTC RES ARCHIVE_BUILD NEW_OUT`.
  Compiles the unchanged audit [String repro](<tests/OriginalCalls.swift>) and
  genuine [Substring calls](<tests/SubstringCalls.swift>) at `-Onone` and `-O`.
  Links with `-undefined,error` to selected old Core plus this archive and
  libSystem. Its optimized no-archive negative control must fail for both
  missing native entries. At `-Onone`, the String caller can link without this
  archive by calling the existing old generic entry; this is recorded, not
  misreported as a failing negative control. Explicit Substring declarations
  remain iOS 14 in the test, with no availability suppression.
- [audit-archive.py](<tests/audit-archive.py>): exact-once native definitions,
  absence in selected Core (duplicate guard), hidden C helpers, no hide or
  autolink directives, and no unexpected imports. Final overlay-shaped link
  also checks the unfiltered exported surface is exactly the two native entries.
- [test-host.sh](<tests/test-host.sh>): `MACOS_SDK CLANG SWIFTC NEW_OUT`.
  Default target `x86_64-apple-macosx11.0`; override `HOST_TARGET` if needed.
  The test-only compile flag selects internal wrappers, never shipping APIs.
  It compares bit patterns and nil at `-Onone` / `-O` against (1) independent
  [direct extraction](<tests/extract-canonical-reference.py>) from the unmodified
  canonical 5.10 Swift/C++ sources and (2) the native host Substring entry.
  `CANONICAL_SWIFT_ROOT` can select the canonical source root; by default it is
  this checkout. Extraction hashes are retained. `RuntimeVersion.c` records
  the actually loaded host Core image identity using public dyld/Mach-O APIs.
  The 127-input corpus covers finite/rounding, signed zero, over/underflow,
  subnormals, NaN/sNaN/payloads, infinity, hex, invalid input, ASCII/non-ASCII
  whitespace, embedded NUL, three storage/slice variants, and four locales
  (with unavailable locales explicitly skipped). Locale is restored.

Host native differences are deliberately an error by default. After reviewing
and disclosing newer-host drift, `ALLOW_NATIVE_DIFFERENCES=1` permits it; this
**never** bypasses canonical-source equivalence, directed assertions, or
optimization consistency. See [actual validation](<VALIDATION.md>).

## Integration boundary and limits

Lead should link the archive/objects into the existing SDK-owned backports or
overlay selection after review, keeping the existing public Swift declarations.
Do not require an application helper import, add test/private headers to the
SDK module surface, or install a separate public module. SDK driver/archive
selection is deliberately not edited here. Review duplicate guards and export
allowlisting against the final integrated SDK image before shipping.

The selected Core still advertises iOS **7.0**, despite the compiler target and
published profile calling the environment iOS 5. No load command is changed or
warning hidden. This archive is additive numeric pairing repair, not proof of a
fully iOS-5-compatible runtime. Real iOS 5.x execution and iOS 6 device regression
are pending; host libc results are not evidence of iOS 5 libc bit patterns.
No full Xcode project build, application rewrite, install, or commit is performed.
