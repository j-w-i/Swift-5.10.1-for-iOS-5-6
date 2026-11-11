#!/bin/bash
# Host test + benchmark harness for the legacy Auto Layout engine.
#
#   Tests/run-autolayout-tests.sh OUT [ROWS...]
#
# OUT must not exist. Builds the portable engine and Cassowary from this vendor
# tree, then:
#   1. runs the persistent-vs-rebuild parity suite (engine-level cases),
#   2. compiles the same golden scenario script against the engine from git HEAD
#      and against the current engine and compares the frames ("equal to the
#      previous rebuild-per-pass outcomes"),
#   3. runs the synthetic constraint-heavy benchmark in rebuild and persistent
#      modes for the requested row counts (default 5 50 200).
#
# Environment:
#   REPO       repository root (default: four levels up from the vendor tree)
#   PYTHON     python3 (default python3)
#   FRONTEND   optional patched swift-frontend for the armv7 overlay typecheck
#   SDK        required together with FRONTEND
#   STAGE      prepared stage (bootstrap) required together with FRONTEND
#   CLANG AR   clang/ar for the staging step (defaults: /usr/bin/clang, /usr/bin/ar)
#
# Step 4 (optional) cross-checks that the staged overlay sources still type-check
# for armv7-apple-ios5.0 with -marm, which is what the integrated build compiles.
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
VENDOR=$(CDPATH= cd -- "$HERE/.." && pwd -P)
REPO=${REPO:-$(CDPATH= cd -- "$VENDOR/../../../.." && pwd -P)}
# Golden reference: the last rebuild-per-pass engine (f27d2e0b). Frames from that
# implementation are the ground truth for behavioural parity; pin it explicitly so
# the reference does not move when newer engine commits land.
GOLDEN_REF=${GOLDEN_REF:-f27d2e0b}
PY=${PYTHON:-python3}
OUT=${1:?Usage: run-autolayout-tests.sh OUT [ROWS...]}
shift || true
ROWS=("$@")
[ "${#ROWS[@]}" -gt 0 ] || ROWS=(5 50 200)
[[ "$OUT" = /* ]] || { echo 'OUT must be an absolute path' >&2; exit 64; }
[ ! -e "$OUT" ] && [ ! -L "$OUT" ] || { echo "Refusing existing output: $OUT" >&2; exit 1; }
mkdir -p "$OUT/build/parity" "$OUT/build/bench" "$OUT/build/golden-current" \
         "$OUT/build/golden-baseline" "$OUT/build/cassowary"

ENGINE_SOURCES=(
  LegacyAutoLayout/LegacyLayoutEngine.swift
  LegacyAutoLayout/LegacyLayoutGeneration.swift
  LegacyAutoLayout/LegacyLayoutItem.swift
  LegacyAutoLayout/LegacyLayoutSolver.swift
  LegacyAutoLayout/LegacyLinearSolver.swift
  LegacyAutoLayout/LegacyLayoutStats.swift
  LegacyAutoLayout/RRLayoutAttribute.swift
  LegacyAutoLayout/RRLayoutConstraint.swift
  LegacyAutoLayout/RRLayoutPriority.swift
  LegacyAutoLayout/RRLayoutRelation.swift
)
BASELINE_SOURCES=(
  LegacyAutoLayout/LegacyLayoutEngine.swift
  LegacyAutoLayout/LegacyLayoutItem.swift
  LegacyAutoLayout/LegacyLayoutSolver.swift
  LegacyAutoLayout/RRLayoutAttribute.swift
  LegacyAutoLayout/RRLayoutConstraint.swift
  LegacyAutoLayout/RRLayoutPriority.swift
  LegacyAutoLayout/RRLayoutRelation.swift
)

STUBS="$OUT/build/stubs.swift"
cat > "$STUBS" <<'SWIFT'
import Foundation
enum LegacyAutoLayout {
    static func ensureInstalled() {}
    static var isActive: Bool { false }
}
func retainNativeAPIBootstrap() {}
SWIFT

ENGINE_PATHS=()
for rel in "${ENGINE_SOURCES[@]}"; do ENGINE_PATHS+=("$VENDOR/$rel"); done

echo "=== 0. hook dispatch audit (injected UIView hooks must not call sibling @objc hooks)"
"$PY" "$VENDOR/Tests/audit-hook-dispatch.py" "$VENDOR/LegacyAutoLayout/LegacyAutoLayoutSwizzling.swift"
# Regression check for the audit itself: the pre-fix reference must be rejected.
mkdir -p "$OUT/build/hook-audit"
git -C "$REPO" show "$GOLDEN_REF:utils/legacy-ios5-mac/vendor/UIKitBackports/LegacyAutoLayout/LegacyAutoLayoutSwizzling.swift" \
  > "$OUT/build/hook-audit/swizzling-reference.swift"
if "$PY" "$VENDOR/Tests/audit-hook-dispatch.py" "$OUT/build/hook-audit/swizzling-reference.swift" \
     > "$OUT/build/hook-audit/reference.log" 2>&1; then
  echo 'FAIL: hook dispatch audit did not detect the pre-fix sibling dispatch pattern' >&2
  exit 1
fi
echo 'PASS: hook dispatch audit detects the pre-fix crash pattern and accepts the current file'

CASS="$OUT/build/cassowary"
echo "=== building Cassowary + engine (current tree)"
# The C core is linked straight into the Cassowary library: the Swift facade calls it through @_silgen_name.
/usr/bin/clang -O2 -ffp-contract=off -c "$VENDOR/CassowaryC/CassowaryC.c" -o "$CASS/CassowaryC.o"
/usr/bin/xcrun swiftc -emit-module -emit-library -module-name Cassowary -O \
  "$VENDOR"/Cassowary/*.swift "$CASS/CassowaryC.o" \
  -o "$CASS/libCassowary.dylib" -emit-module-path "$CASS/Cassowary.swiftmodule"

build_host() { # dir extra-flags...
  local dir=$1; shift
  /usr/bin/xcrun swiftc -O "$@" -I "$CASS" -L "$CASS" -lCassowary \
    "$STUBS" "${ENGINE_PATHS[@]}" \
    "$VENDOR/Tests/AutoLayoutTestSupport.swift" \
    "$dir/main.swift" -o "$dir/program"
}

cp "$VENDOR/Tests/autolayout_parity.swift" "$OUT/build/parity/main.swift"
cp "$VENDOR/Tests/albench_main.swift" "$OUT/build/bench/main.swift"
build_host "$OUT/build/parity"
build_host "$OUT/build/bench"

echo "=== 1. engine parity suite"
"$OUT/build/parity/program" > "$OUT/parity.log" 2>&1
cat "$OUT/parity.log"

echo "=== 2. golden frames vs engine from git HEAD"
BASELINE_DIR="$OUT/baseline"
mkdir -p "$BASELINE_DIR"
for rel in "${BASELINE_SOURCES[@]}"; do
  mkdir -p "$BASELINE_DIR/$(dirname "$rel")"
  git -C "$REPO" show "$GOLDEN_REF:utils/legacy-ios5-mac/vendor/UIKitBackports/$rel" > "$BASELINE_DIR/$rel"
done
mkdir -p "$BASELINE_DIR/Cassowary"
# The pinned reference predates the C core: take exactly the Cassowary files that existed at that ref.
for base in $(git -C "$REPO" ls-tree --name-only "$GOLDEN_REF" "utils/legacy-ios5-mac/vendor/UIKitBackports/Cassowary/" | xargs -n1 basename); do
  git -C "$REPO" show "$GOLDEN_REF:utils/legacy-ios5-mac/vendor/UIKitBackports/Cassowary/$base" \
    > "$BASELINE_DIR/Cassowary/$base"
done
/usr/bin/xcrun swiftc -emit-module -emit-library -module-name Cassowary -O \
  "$BASELINE_DIR"/Cassowary/*.swift \
  -o "$BASELINE_DIR/libCassowary.dylib" -emit-module-path "$BASELINE_DIR/Cassowary.swiftmodule"
BASELINE_ENGINE=()
for rel in "${BASELINE_SOURCES[@]}"; do BASELINE_ENGINE+=("$BASELINE_DIR/$rel"); done

cp "$VENDOR/Tests/autolayout_golden.swift" "$OUT/build/golden-current/main.swift"
cp "$VENDOR/Tests/autolayout_golden.swift" "$OUT/build/golden-baseline/main.swift"
/usr/bin/xcrun swiftc -O -DNEW_ENGINE -I "$CASS" -L "$CASS" -lCassowary \
  "$STUBS" "${ENGINE_PATHS[@]}" "$OUT/build/golden-current/main.swift" \
  -o "$OUT/build/golden-current/program"
/usr/bin/xcrun swiftc -O -I "$BASELINE_DIR" -L "$BASELINE_DIR" -lCassowary \
  "$STUBS" "${BASELINE_ENGINE[@]}" "$OUT/build/golden-baseline/main.swift" \
  -o "$OUT/build/golden-baseline/program"
"$OUT/build/golden-baseline/program" > "$OUT/golden-baseline.txt"
"$OUT/build/golden-current/program" > "$OUT/golden-current.txt"
"$PY" - "$OUT/golden-baseline.txt" "$OUT/golden-current.txt" <<'PY'
import sys
baseline, current = sys.argv[1], sys.argv[2]
def parse(path):
    data = {}
    for line in open(path):
        name, step, label, x, y, w, h = line.strip().split('|')
        data[(name, step, label)] = (float(x), float(y), float(w), float(h))
    return data
old, new = parse(baseline), parse(current)
if old.keys() != new.keys():
    raise SystemExit('golden: scenario/step set differs: %s' % (sorted(old.keys() ^ new.keys())[:5],))
problems = []
for key in old:
    for axis, (lhs, rhs) in enumerate(zip(old[key], new[key])):
        if abs(lhs - rhs) > 1e-6:
            problems.append('%s axis %d: %r != %r' % (key, axis, lhs, rhs))
if problems:
    raise SystemExit('golden: %d frame differences:\n%s' % (len(problems), '\n'.join(problems[:20])))
print('PASS: %d golden frames match the previous rebuild-per-pass engine' % len(old))
PY

echo "=== 2b. presolve differential (presolve on vs disabled, frames within 1e-6)"
mkdir -p "$OUT/build/presolve-diff"
cp "$VENDOR/Tests/autolayout_presolve_diff.swift" "$OUT/build/presolve-diff/main.swift"
build_host "$OUT/build/presolve-diff"
"$OUT/build/presolve-diff/program" > "$OUT/presolve-diff.log" 2>&1
cat "$OUT/presolve-diff.log"

echo "=== 2c. broken/relaxed-constraint diagnostics (presolve vs presolve-off vs f27d2e0b)"
mkdir -p "$OUT/build/broken-diag-current" "$OUT/build/broken-diag-baseline"
cp "$VENDOR/Tests/autolayout_broken_diag.swift" "$OUT/build/broken-diag-current/main.swift"
cp "$VENDOR/Tests/autolayout_broken_diag.swift" "$OUT/build/broken-diag-baseline/main.swift"
/usr/bin/xcrun swiftc -O -DNEW_ENGINE -I "$CASS" -L "$CASS" -lCassowary \
  "$STUBS" "${ENGINE_PATHS[@]}" "$OUT/build/broken-diag-current/main.swift" \
  -o "$OUT/build/broken-diag-current/program"
/usr/bin/xcrun swiftc -O -I "$BASELINE_DIR" -L "$BASELINE_DIR" -lCassowary \
  "$STUBS" "${BASELINE_ENGINE[@]}" "$OUT/build/broken-diag-baseline/main.swift" \
  -o "$OUT/build/broken-diag-baseline/program"
"$OUT/build/broken-diag-current/program" > "$OUT/broken-diag-current.txt"
"$OUT/build/broken-diag-baseline/program" > "$OUT/broken-diag-baseline.txt"
"$PY" - "$OUT/broken-diag-current.txt" "$OUT/broken-diag-baseline.txt" <<'PYDIAG'
import sys
def read(path, mode_filter=None):
    data = {}
    for line in open(path):
        name, step, mode, count, ids = line.strip().split('|')
        if mode_filter is not None and mode != mode_filter:
            continue
        data[(name, step)] = (int(count), ids)
    return data
current_path, baseline_path = sys.argv[1], sys.argv[2]
on = read(current_path, 'on')
off = read(current_path, 'off')
baseline = read(baseline_path)
if on.keys() != off.keys():
    raise SystemExit('broken-diag: presolve on/off scenario sets differ: %s' % (sorted(on.keys() ^ off.keys())[:5],))
if baseline.keys() != on.keys():
    raise SystemExit('broken-diag: baseline/current scenario sets differ: %s' % (sorted(baseline.keys() ^ on.keys())[:5],))
problems = []
for key in on:
    if on[key] != off[key]:
        problems.append('%s: presolve-on %r != presolve-off %r' % (key, on[key], off[key]))
    if on[key] != baseline[key]:
        problems.append('%s: presolve %r != f27d2e0b %r' % (key, on[key], baseline[key]))
if problems:
    raise SystemExit('broken-diag: %d differences:\n%s' % (len(problems), '\n'.join(problems[:20])))
broken_total = sum(v[0] for v in on.values())
print('PASS: %d conflict scenarios (%d broken/relaxed constraints) report identically with presolve on, presolve off and the f27d2e0b reference' % (len(on), broken_total))
PYDIAG

echo "=== 3. benchmark"
LEGACY_AUTOLAYOUT_STATS=1 "$OUT/build/bench/program" persistent 5 3 \
  > /dev/null 2> "$OUT/stats.log"
grep -qE "action=(cached|fast)" "$OUT/stats.log" || {
  echo 'FAIL: LEGACY_AUTOLAYOUT_STATS=1 did not report cached passes' >&2
  cat "$OUT/stats.log" >&2
  exit 1
}
echo "PASS: LEGACY_AUTOLAYOUT_STATS=1 per-pass counters:"; cat "$OUT/stats.log"
rm -f "$OUT/bench.log"
for rows in "${ROWS[@]}"; do
  "$OUT/build/bench/program" rebuild "$rows" 3 | tee -a "$OUT/bench.log"
  "$OUT/build/bench/program" persistent "$rows" 10 | tee -a "$OUT/bench.log"
done

if [ -n "${FRONTEND:-}" ]; then
  : "${SDK:?set SDK with FRONTEND}" "${STAGE:?set STAGE with FRONTEND}"
  echo "=== 4. armv7 overlay typecheck (-marm)"
  STAGED="$OUT/staged-backports"
  bash "$REPO/utils/legacy-ios5-mac/build-backports-runtime.sh" \
    "$SDK" "${CLANG:-/usr/bin/clang}" "${AR:-/usr/bin/ar}" "$STAGED" > "$OUT/staged-build.log" 2>&1
  { cat "$STAGE/probes/uikit510-sources.base.txt"; cat "$STAGED/swift-sources.txt"; } \
    | awk '!seen[$0]++' > "$OUT/uikit-sources.txt"
  "$FRONTEND" -typecheck -parse-as-library -module-name UIKit \
    -target armv7-apple-ios5.0 -sdk "$SDK" -resource-dir "$STAGE/probes/modules510" \
    -D LEGACY_IOS5 -I "$STAGE/probes/dispatch-shims" \
    -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements \
    -enable-library-evolution -enable-legacy-ios5-runtime \
    -Xcc -DOS_OBJECT_USE_OBJC=0 -Xcc -fmodules-cache-path="$STAGE/probes/cc-modcache" \
    -Xcc -marm -I "$STAGED/Swift" \
    -Xcc -fmodule-map-file="$STAGED/include/module.modulemap" -Xcc -I"$STAGED/include" \
    -disable-autolink-library swiftFileProvider @"$OUT/uikit-sources.txt" \
    > "$OUT/typecheck.log" 2>&1
  echo "PASS: overlay sources typecheck for armv7-apple-ios5.0 (ARM)"
fi

echo "=== DONE: results in $OUT"
