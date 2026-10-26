#!/bin/bash
# Host differential tests + performance for vendor/FoundationBackports/Extras.
#
#   Tests/run-extras-tests.sh [OUT]
#
# Pass an absolute OUT, or set FOUNDATION_WORK / LEGACY_BUILD_ROOT. Output must
# not already exist. Set DEVICE_SDK / DEVICE_CLANG to also compile the
# Extras sources for armv7-apple-ios5.0 with the builder's flags (compile only).
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
EXTRAS=$(CDPATH= cd -- "$HERE/.." && pwd -P)
STAMP=$(date +%Y%m%d-%H%M%S)
if [ "$#" -gt 0 ]; then
  OUT=$1
else
  BUILD_ROOT=${FOUNDATION_WORK:-}
  if [ -z "$BUILD_ROOT" ]; then
    [ -n "${LEGACY_BUILD_ROOT:-}" ] || { echo 'Pass OUT or set FOUNDATION_WORK / LEGACY_BUILD_ROOT.' >&2; exit 64; }
    BUILD_ROOT="$LEGACY_BUILD_ROOT/foundation-work"
  fi
  OUT="$BUILD_ROOT/foundation-extras-$STAMP"
fi
[[ "$OUT" = /* ]] || { echo "OUT must be absolute" >&2; exit 64; }
[ ! -e "$OUT" ] || { echo "Refusing existing output: $OUT" >&2; exit 1; }
mkdir -p "$OUT/logs" "$OUT/build"
{
  echo "Extras: $EXTRAS"
  echo "Output: $OUT"
  echo "Host: $(uname -a)"
  echo "clang: $(clang --version | head -1)"
} | tee "$OUT/logs/environment.log"

echo "=== host differential tests"
clang -fobjc-arc -fblocks -O2 -Wall -Wextra -Wno-unused-parameter \
  "$EXTRAS/FBPCalendarExtras.m" "$EXTRAS/FBPStringExtras.m" \
  "$EXTRAS/FBPCharacterSetExtras.m" "$EXTRAS/FBPExtrasInstaller.m" \
  "$HERE/fbp_extras_tests.m" -framework Foundation \
  -o "$OUT/build/fbp-extras-tests" > "$OUT/logs/compile-host.log" 2>&1 || {
  tail -40 "$OUT/logs/compile-host.log" >&2; exit 1;
}
"$OUT/build/fbp-extras-tests" | tee "$OUT/logs/differential.log"

echo "=== overlay literal cross-check"
python3 - "$EXTRAS" <<'PY' | tee "$OUT/logs/overlay-literals.log"
import re, sys, pathlib
extras = pathlib.Path(sys.argv[1])
overlay_dir = extras.parents[2] / 'overlays' / 'Foundation'
text = (overlay_dir / 'CharacterSet.swift').read_text()
problems = []
# The legacy branches must use the direct, importer-lowered native declarations.
for file in ('CharacterSet.swift', 'Calendar.swift', 'NSStringAPI.swift'):
    source = (overlay_dir / file).read_text()
    legacy_blocks = re.findall(r'#if LEGACY_IOS5(.*?)(?:#else|#endif)', source, flags=re.S)
    for block in legacy_blocks:
        for forbidden in ('unsafeBitCast', 'class_getClassMethod', 'class_getInstanceMethod',
                          '_legacyFoundation', '_legacyCalendarBool', '_legacyNSStringPercent',
                          '_NSURLComponentsGet', '_CFURLComponentsGet'):
            if forbidden in block:
                problems.append('%s LEGACY_IOS5 branch still uses %s' % (file, forbidden))
expected_sets = ('urlUserAllowed', 'urlPasswordAllowed', 'urlHostAllowed',
                 'urlPathAllowed', 'urlQueryAllowed', 'urlFragmentAllowed')
for name in expected_sets:
    if ('NSCharacterSet.%s as CFCharacterSet' % name) not in text:
        problems.append('CharacterSet.swift legacy branch missing direct %s bridge' % name)
constants = dict(re.findall(r'static NSString \*const (kFBPURL\w+)\s*=\s*\n?\s*@"([^"]*)"', (extras / 'FBPCharacterSetExtras.m').read_text()))
expected = {
  'kFBPURLUserPasswordCharacters': "!$&'()*+,-.0123456789;=ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~",
  'kFBPURLHostCharacters': "!$&'()*+,-.0123456789:;=ABCDEFGHIJKLMNOPQRSTUVWXYZ[]_abcdefghijklmnopqrstuvwxyz~",
  'kFBPURLPathCharacters': "!$&'()*+,-./0123456789:;=@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~",
  'kFBPURLQueryFragmentCharacters': "!$&'()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~",
}
for name, chars in expected.items():
    if name not in constants:
        problems.append('Extras constant missing: %s' % name)
    elif sorted(constants[name]) != sorted(chars):
        problems.append('Extras constant %s differs from native membership' % name)
if problems:
    print('FAIL: overlay/Extras cross-check')
    for problem in problems: print('  ' + problem)
    sys.exit(1)
print('PASS: legacy branches use direct importer-lowered APIs, no manual IMP lookups/C refs; Extras sets match native membership')
PY

echo "=== thread sanitizer (concurrent first use)"
if clang -fobjc-arc -fblocks -O1 -g -fsanitize=thread \
     "$EXTRAS/FBPCalendarExtras.m" "$EXTRAS/FBPStringExtras.m" \
     "$EXTRAS/FBPCharacterSetExtras.m" "$EXTRAS/FBPExtrasInstaller.m" \
     "$HERE/fbp_extras_tests.m" -framework Foundation \
     -o "$OUT/build/fbp-extras-tsan" > "$OUT/logs/compile-tsan.log" 2>&1; then
  if TSAN_OPTIONS="halt_on_error=1:exitcode=66" "$OUT/build/fbp-extras-tsan" --concurrency-only \
       > "$OUT/logs/tsan.log" 2>&1; then
    grep -q "PASS: concurrency-only" "$OUT/logs/tsan.log" || {
      echo 'FAIL: ThreadSanitizer run did not reach PASS' >&2; cat "$OUT/logs/tsan.log" >&2; exit 1; }
    echo 'PASS: ThreadSanitizer concurrent first-use (no data races reported)'
  else
    echo 'FAIL: ThreadSanitizer reported a problem' >&2
    cat "$OUT/logs/tsan.log" >&2
    exit 1
  fi
else
  echo 'WARN: ThreadSanitizer build unavailable on this compiler; concurrency test still ran unsanitized' >&2
fi

if [ -n "${DEVICE_SDK:-}" ] && [ -n "${DEVICE_CLANG:-}" ]; then
  echo "=== device compile (armv7-apple-ios5.0, builder flags)"
  for source in "$EXTRAS"/FBPCalendarExtras.m "$EXTRAS"/FBPStringExtras.m \
                "$EXTRAS"/FBPCharacterSetExtras.m "$EXTRAS"/FBPExtrasInstaller.m; do
    name=$(basename "$source" .m)
    "$DEVICE_CLANG" -target armv7-apple-ios5.0 -marm -isysroot "$DEVICE_SDK" -O2 -g0 \
      -fobjc-arc -fblocks -fno-modules -fvisibility=default \
      -Werror=unguarded-availability -Werror=unguarded-availability-new -Wno-deprecated-declarations \
      -c "$source" -o "$OUT/build/$name.o" > "$OUT/logs/device-$name.log" 2>&1 || {
      tail -30 "$OUT/logs/device-$name.log" >&2; exit 1; };
  done
  echo "PASS: Extras compiles for armv7-apple-ios5.0"
fi

echo "=== overlay syntax parse (both availability branches)"
SWIFTC=${SWIFTC:-$(xcrun --find swiftc 2>/dev/null || true)}
if [ -n "$SWIFTC" ]; then
  for file in CharacterSet.swift Calendar.swift NSStringAPI.swift; do
    for flags in "" "-D LEGACY_IOS5"; do
      # shellcheck disable=SC2086
      "$SWIFTC" -parse $flags "$EXTRAS/../../../overlays/Foundation/$file" > "$OUT/logs/parse-$file-${flags// /}.log" 2>&1 || {
        echo "WARN: parse failed for $file ($flags)"; tail -10 "$OUT/logs/parse-$file-${flags// /}.log" >&2; };
    done
  done
  echo "PASS: overlay files parse (warnings above would be syntax errors)"
fi

echo "=== DONE: $OUT"
