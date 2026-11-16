#!/bin/bash
# check-backports-multiarch.sh — the backported surface must resolve on the
# 64-bit slices at their iOS 7.0 floor, and stay unavailable past a family's
# implemented version.
#
# Usage: check-backports-multiarch.sh TOOLCHAIN SDK NEW_OUT
# Exit 0 only when every row matches the expectation table.
set -euo pipefail
[ "$#" -eq 3 ] || { echo "Usage: $0 TOOLCHAIN SDK NEW_OUT" >&2; exit 64; }
TC=$1; SDK=$2; OUT=$3
[ -x "$TC/usr/bin/swiftc" ] && [ -d "$SDK" ] || { echo 'Missing toolchain or SDK.' >&2; exit 1; }
[ ! -e "$OUT" ] || { echo "Refusing existing output: $OUT" >&2; exit 1; }
mkdir -p "$OUT/tmp"
RES="$TC/usr/lib/swift_ios5"
export TMPDIR="$OUT/tmp"

probe() { # ARCH VERSION NAME SOURCE
  local arch=$1 version=$2 name=$3 source=$4
  local f="$OUT/probe-$arch-$version-$name.swift"
  printf 'import UIKit\nfunc probe(_ v: UIView, _ w: UIView) {\n    %s\n}\n' "$source" > "$f"
  "$TC/usr/bin/swiftc" -sdk "$SDK" -resource-dir "$RES" \
    -enable-legacy-ios5-runtime -Xcc -I"$RES/legacy-overlay-shims" \
    -module-cache-path "$OUT/mc-$arch-$version" \
    -runtime-compatibility-version none \
    -disable-autolinking-runtime-compatibility-dynamic-replacements \
    -Xfrontend -disable-autolink-library -Xfrontend swiftFileProvider \
    -target "$arch-apple-ios$version" -parse-as-library -typecheck "$f" \
    > "$OUT/probe-$arch-$version-$name.log" 2>&1
}

# Row format: arch version name source expectation
#   ok  = must compile;  no = must fail because the family ceiling is lower.
ROWS=(
  'arm64|7.0|anchor|_ = v.leadingAnchor.constraint(equalTo: w.leadingAnchor)|ok'
  'arm64|8.0|anchor|_ = v.leadingAnchor.constraint(equalTo: w.leadingAnchor)|ok'
  'arm64|9.0|anchor|_ = v.leadingAnchor.constraint(equalTo: w.leadingAnchor)|ok'
  'arm64|7.0|activate|NSLayoutConstraint.activate([])|ok'
  'arm64|7.0|stack|_ = UIStackView()|ok'
  'arm64|7.0|guide|_ = UILayoutGuide()|ok'
  'arm64|7.0|refresh|_ = UIRefreshControl()|ok'
  'arm64|7.0|compositional|_ = UICollectionViewCompositionalLayout(sectionProvider: { _, _ in nil })|ok'
  'arm64|7.0|keyboard|_ = v.keyboardLayoutGuide|no'
  'arm64|9.0|keyboard|_ = v.keyboardLayoutGuide|no'
  'armv7s|7.0|anchor|_ = v.leadingAnchor.constraint(equalTo: w.leadingAnchor)|ok'
  'armv7s|7.0|stack|_ = UIStackView()|ok'
  'armv7s|7.0|keyboard|_ = v.keyboardLayoutGuide|no'
  'armv7|5.0|anchor|_ = v.leadingAnchor.constraint(equalTo: w.leadingAnchor)|ok'
  'armv7|6.0|stack|_ = UIStackView()|ok'
  'armv7|5.0|keyboard|_ = v.keyboardLayoutGuide|no'
)

fail=0
for row in "${ROWS[@]}"; do
  IFS="|" read -r arch version name source expectation <<< "$row"
  if probe "$arch" "$version" "$name" "$source"; then status=ok; else status=no; fi
  printf '%-8s %-5s %-14s expected=%-3s got=%-3s' "$arch" "$version" "$name" "$expectation" "$status"
  if [ "$status" = "$expectation" ]; then
    echo '  PASS'
  else
    echo '  FAIL'
    tr -d '\000' < "$OUT/probe-$arch-$version-$name.log" | grep -aE ':[0-9]+:[0-9]+: error:' | head -3 | sed 's/^/    /'
    fail=1
  fi
done

# A 64-bit target below iOS 7.0 has no hardware and must be refused, not silently accepted.
if probe arm64 6.0 lowfloor '_ = UIStackView()'; then
  echo 'FAIL: arm64-apple-ios6.0 was accepted; it must be refused.'; fail=1
else
  echo 'PASS: arm64 iOS 6.0 refused (no 64-bit hardware below iOS 7).'
fi

[ "$fail" -eq 0 ] && echo 'PASS: multiarch backport surface matches expectations.'
exit "$fail"
