# Auto Layout engine test + benchmark harness

Host-side tests for the legacy Auto Layout engine (`LegacyAutoLayout/`). The
harness builds the portable engine sources (no UIKit) against the vendored
Cassowary module and runs three things:

1. **Parity suite** (`autolayout_parity.swift`): the persistent incremental
   engine vs a rebuild-per-pass engine on identical trees, comparing frames and
   broken-constraint counts after every mutation. Covers add/remove constraint,
   constant and priority changes, reparenting, view removal, multiple roots,
   autoresizing translation, layout-guide participation and intrinsic-size
   changes, plus the stats contract (first pass rebuilds, clean passes are
   cached).
2. **Golden frames** (`autolayout_golden.swift`): the same scenario script is
   compiled against the engine from `git HEAD` (previous rebuild-per-pass
   implementation) and against the current engine; every frame must agree within
   1e-6. This is the "no behaviour change" evidence.
3. **Benchmark** (`albench_main.swift`): a synthetic hierarchy of N rows (4
   constraints each) in `rebuild` mode (old behaviour) and `persistent` mode
   (incremental solver). Reports first-pass, steady-state and average µs, plus
   the engine counters.

## Running

```sh
vendor/UIKitBackports/Tests/run-autolayout-tests.sh /tmp/al-harness 5 50 200
```

Optional armv7 overlay check (what the integrated build compiles). Pass the
patched frontend, SDK and prepared stage:

```sh
FRONTEND=$BUILD_ROOT/build/swift/bin/swift-frontend \
SDK=$XCODE/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk \
STAGE=$BUILD_ROOT/bootstrap \
CLANG=$BUILD_ROOT/build/llvm/bin/clang AR=$XCODE_TOOLCHAIN/usr/bin/ar \
vendor/UIKitBackports/Tests/run-autolayout-tests.sh /tmp/al-harness
```

The output directory must not exist; all results (logs, golden frames, bench
output) are kept there. The harness never modifies the repository.

## No-change fast path

The engine keeps a process-wide mutation generation (`LegacyLayoutMutation`)
bumped by every constraint/property/tree mutation (constraint add/remove,
constant/priority, translates/intrinsic/priority/baseline changes, subview
insertion/removal, participating geometry changes). The persistent solver
records the generation it consumed; when the next pass sees the same value and
the same writing direction, it returns the cached result without walking the
item tree (~0.5 us even for 200 rows). Mutations that are not routed through the
bridge (test fakes must bump explicitly; `layoutSetFrame` and the engine's
internal autoresizing bookkeeping are suppressed) simply fall back to the
diff/solve path, never to a stale result.

The golden reference is pinned in the script (`GOLDEN_REF`, default `f27d2e0b`,
the last rebuild-per-pass engine) so the behavioural baseline does not move when
newer engine commits land.

## Counters

`LegacyLayoutStats` (internal) counts passes, solves, cached passes, rebuilds,
constraints installed/removed, tableau variables and µs per pass. Set
`LEGACY_AUTOLAYOUT_STATS=1` to print a line per pass to stderr; behaviour is
unchanged otherwise.

## Hook dispatch audit (injected UIView hooks)

The iOS 5 bridge installs its hooks as IMPs on `UIView`, so inside a hook `self`
is the receiving view (e.g. `OALayoutGuide`), not the hook class. A hook that
calls a sibling `@objc dynamic` hook on `self` sends a selector the view does not
implement and crashes with `doesNotRecognizeSelector:` — this was the iOS 5
UIStackView crash in `rr_a_addConstraints`. Hooks must call non-`@objc` helpers.

`Tests/audit-hook-dispatch.py` enforces this statically and is part of the harness
(step 0): it fails if any hook body calls a sibling hook selector or if a
`#selector` has no hook method, and it is regression-checked against the pre-fix
`f27d2e0b` file. `LegacyAutoLayout.auditInstalledBridge()` performs the runtime
counterpart after installation (injected selectors/IMPs, forwarded originals,
hook methods).

## Device/simulator fixtures

`Tests/LegacyStackViewSmoke.swift` is a runtime fixture (same pattern as
`utils/legacy-ios5-mac/GenericRuntimeSmoke.swift`: no XCTest, no entry point).
Compile it into the legacy-names app/backport module and call
`runLegacyStackViewSmoke()` after launch. It force-installs the bridge through
`LegacyAutoLayout.installForLegacyNames()`, builds a `UIStackView`, adds arranged
subviews, toggles hidden, inserts and removes, checks frames are finite, and
prints the installed-bridge audit. Only an actual iOS 5 device (or a legacy-name
simulator target built with the iOS 5 overlay) validates iOS 5.

## Simulator hook regression test (iOS 5 injected UIView hooks)

`Tests/run-simulator-hook-test.sh [DEVICE]` builds the staged
Cassowary/LegacyAutoLayout sources for the current Xcode's iPhoneSimulator SDK,
force-installs the legacy bridge (`LegacyAutoLayout.installForLegacyNames()`) and
drives the injected `addConstraints:`/`removeConstraints:` hooks with an
`OALayoutGuide`-shaped `UIView` subclass, then toggles hidden and inserts/removes
arranged subviews. It also asserts that a **normal** (non-forced) run is
unaffected: `installIfNeeded()` refuses to install and native constraints work.

The same test catches the pre-fix crash: stage a file whose plural hooks call the
sibling `@objc` `rr_a_addConstraint:` selector and the process terminates with
`-[UIView rr_a_addConstraint:]: unrecognized selector` (the device crash):

```sh
cp LegacyAutoLayout/LegacyAutoLayoutSwizzling.swift /tmp/regressed.swift
# reintroduce `rr_a_addConstraint(constraint)` in the addConstraints: loop,
# then:
SWIZZLING_OVERRIDE=/tmp/regressed.swift Tests/run-simulator-hook-test.sh
```

It runs on a modern simulator using the system toolchain because the legacy
device toolchain ships no simulator Swift stdlib; the fixture
`Tests/LegacyStackViewSmoke.swift` is the device counterpart for a legacy-name
app build.
