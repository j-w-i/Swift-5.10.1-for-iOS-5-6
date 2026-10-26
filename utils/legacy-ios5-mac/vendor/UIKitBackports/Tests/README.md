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
