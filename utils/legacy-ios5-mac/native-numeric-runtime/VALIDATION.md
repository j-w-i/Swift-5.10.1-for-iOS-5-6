# Numeric backport validation — 2026-10-27

## Scope

Only this new source directory and the new sibling builder were added. Existing
SDK scripts, installed toolchain, profile, application/packages, canonical Swift
5.10 sources, and retained Swift 5.1 sources were not changed. All build/cache/
test artifacts are under
[/Users/jwalr/Developer/Neocord2-iOS5-Work/sdk-build/numeric](</Users/jwalr/Developer/Neocord2-iOS5-Work/sdk-build/numeric>).
No install, project build, device run, or commit occurred.

## ARM source build and linkage

Inputs:

- Swift compiler: installed `5.10.1-ios5.xctoolchain/usr/bin/swiftc`, reporting
  **Swift 5.10.1-dev**, LLVM `e98989b1092ff3a`, Swift `30d6dfb110151ac`.
- Swift resources: that toolchain's `usr/lib/swift_ios5`, not default resources.
- Apple clang 13.1.6 (`clang-1316.0.21.2.5`) and archive tool from Xcode 13.4.1.
- iPhoneOS15.5 SDK from Xcode 13.4.1; target `armv7-apple-ios5.0`.
- Selected old Core hash
  `9ed87575b19ce3441c74d8271f2b6a9f9e7c2ae844f9947fa6067191f638c4c1`.

The final source build is
[armv7/build-manifest.json](</Users/jwalr/Developer/Neocord2-iOS5-Work/sdk-build/numeric/armv7/build-manifest.json>).
It records exact tool/source/archive hashes. The archive's raw symbol audit
finds exactly two public native definitions, once each:

```
_$sSdySdSgSscfC
_$sSfySfSgSscfC
```

C helpers are private-external (hidden). Compiler-generated Swift details are
non-external or weak-private-external, not public helper exports. No relocation
hide directives or LC_LINKER_OPTION autoloads are present. Every undefined Swift
symbol resolves in selected Core; other undefined symbols are the private C
functions or the audited libSystem set (`strtod_l`, `strtof_l`, `strlen`, errno,
stack protector). There are no libc++ runtime imports. The symbol gate also
rejects integration with a Core already defining either native entry.

[Final link summary](</Users/jwalr/Developer/Neocord2-iOS5-Work/sdk-build/numeric/link/summary.txt>)
and its recorded commands prove:

1. The exact unchanged public `Double(String)` / `Float(String)` repro compiles
   at `-Onone` and `-O`, and links with the new archive and selected SDK Core
   using `-undefined,error`.
2. The optimized no-archive negative control fails for precisely the original
   two missing Substring initializer symbols and the same String specialization.
   The `-Onone` no-archive String caller succeeds using the old generic Core
   initializer; that result is expected and explicitly retained.
3. Genuine public Substring API calls, correctly availability-annotated iOS 14,
   compile/link at both levels. No fake availability or disabled checking.
4. An overlay-shaped source link force-loads the archive and exports exactly
   those two standard-library symbols, **without** an export filter. Neither
   private C/test helpers nor compatibility types appear in exported surface.
5. No Concurrency, StringProcessing, or Swift 5.6 compatibility library is
   autoloaded or linked. No native initializer remains undefined.

All successful old-Core links still emit its real **built-for-iOS-7.0** warning.
The source objects target iOS 5; the old Core remains untouched and is not
requalified by that fact. No full-runtime iOS 5 floor claim is made.

## Host semantic evidence

[Host summary](</Users/jwalr/Developer/Neocord2-iOS5-Work/sdk-build/numeric/host-02/summary.txt>):
**1,524 Float/Double paired rows match exact canonical Swift 5.10 source at
`-Onone`, and another 1,524 match at `-O`, bit-for-bit including NaNs.**
The 127 inputs run in three full/sliced storage variants and four available
locales. `fr_FR.UTF-8` and `de_DE.UTF-8` actually report comma decimal separators;
C-locale parsing remains unchanged. Directed canonical range/NUL/whitespace/
signed-zero/sNaN assertions and optimization consistency also pass.

The independent reference is extracted at test time from unmodified canonical
Swift 5.10.1 source, retaining the original C++ branches/signaling-NaN logic and
Swift initializer body. Only type expansion, private test naming, and scoped
pointer substitution are applied. See generated
[canonical reference hashes](</Users/jwalr/Developer/Neocord2-iOS5-Work/sdk-build/numeric/host-02/canonical/source-manifest.json>).
These are same-host source equivalence tests, **not iOS device execution**.

### Actual native host reference identity and disclosed drift

A second reference calls the host's real native `Double(Substring)` /
`Float(Substring)` initializers. It is **not** a pinned Swift 5.10 runtime:

- Compiler: the installed Swift **5.10.1-dev** noted above.
- Module/interface: Xcode 13.4.1 macOS SDK, whose Swift Core linkage stub records
  5.6.0. That link-time stub version is not the actually running runtime release.
- Execution: macOS **27.0**, build **26A428**, x86_64 (Rosetta), system
  `/usr/lib/swift/libswiftCore.dylib`.
- [Loaded-image record](</Users/jwalr/Developer/Neocord2-iOS5-Work/sdk-build/numeric/host-02/loaded-runtime-version.txt>):
  UUID **0DAE92D9-DEEE-353C-9B41-781EECACD199**; loaded dylib current version
  **0.0.0**. The exact Swift runtime release number is not exposed by that load
  command and is not guessed. The system Swift compiler separately reports 6.4;
  that is not asserted to be the loaded runtime's release identifier.
- Installed toolchain default macOS resource architecture directories are empty;
  the SDK supplies host module interfaces, while the system supplies the runtime.

The newer native host reference differs from canonical 5.10 in **144/1,524 rows
at each optimization level**: 12 input cases × three storage variants × four
locales. These are real differences, not hidden as NaN equality:

| Input class | Canonical-source backport | Current native host |
|---|---|---|
| `-0X1P-2` | -0.25 | nil |
| Two oversized NaN payload cases | libc payload bits | different payload masking |
| `nan(foo)`, `nan(1x)` | quiet NaN | nil |
| `-SnAn` | positive signaling NaN (canonical special-case quirk) | negative signaling NaN |
| `snan(42)` | nil | signaling NaN with payload |
| Five numeric/NaN prefixes ending in embedded NUL | accepted prefix | nil |

[All native differences](</Users/jwalr/Developer/Neocord2-iOS5-Work/sdk-build/numeric/host-02/differences-O.txt>)
retain full bit patterns and input spelling. The default strict differential
run correctly exits nonzero for newer-host drift. The reviewed run uses
`ALLOW_NATIVE_DIFFERENCES=1`; canonical-source mismatch would still fail.
No implementation behavior was changed to imitate the newer host.

## Limits and review boundary

- The two new Substring entries implement the canonical Swift 5.10 source
  algorithm using the target Apple's C-locale libc. They do not forward to the
  Swift 5.1 parser witness.
- Existing old generic/witness/parser symbols retain their existing behavior.
  The SDK's imported fallback still reaches old helpers; uniform canonical 5.10
  behavior through every old String/witness path is not claimed.
- SDK declaration availability remains unchanged. Integration/selection by SDK
  build/driver scripts is not implemented here; lead integrates after review.
- Float16 is not addressed (entire old-Core surface is absent); Float80 is not
  part of armv7's API.
- Actual iOS 5.x execution, old-libc numeric edge cases, iOS 6 device regression,
  and full-runtime deployment-floor qualification remain pending.
