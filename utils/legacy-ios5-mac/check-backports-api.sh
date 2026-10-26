#!/bin/bash
# Verify toolchain-native UIKit backports: ordinary UIKit spelling at a legacy iOS 5
# deployment target, real version gating, and native behaviour for iOS 6+ targets.
# Usage: check-backports-api.sh TOOLCHAIN SDK NEW_OUTPUT
set -euo pipefail
TC=${1:?toolchain}; SDK=${2:?SDK}; OUT=${3:?new output directory}
[[ "$TC" = /* && "$SDK" = /* && "$OUT" = /* ]] || { echo 'Use absolute paths.' >&2; exit 64; }
[ ! -e "$OUT" ] || { echo "Refusing to overwrite $OUT" >&2; exit 1; }
RES="$TC/usr/lib/swift_ios5"
[ -x "$TC/usr/bin/swiftc" ] && [ -d "$SDK" ] && [ -d "$RES" ] || exit 1
mkdir -p "$OUT"
report_failure() {
  local status=$?
  /usr/bin/python3 - "$OUT" <<'PY'
from pathlib import Path
import sys
for path in sorted(Path(sys.argv[1]).glob('*/build.log')):
    print(str(path) + ':', file=sys.stderr)
    lines = path.read_bytes().replace(b'\0', b'').decode('utf-8', errors='replace').splitlines()
    print('\n'.join(lines[-25:]), file=sys.stderr)
PY
  exit "$status"
}
trap report_failure ERR
COMMON=(-sdk "$SDK" -resource-dir "$RES" -enable-legacy-ios5-runtime
  -Xcc -I"$RES/legacy-overlay-shims" -module-cache-path "$OUT/module-cache"
  -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements
  -Xfrontend -disable-autolink-library -Xfrontend swiftFileProvider)

# Valid at a legacy iOS 5 device target: every included family, ordinary spelling.
cat > "$OUT/BackportsClient.swift" <<'SWIFT'
import UIKit

public final class BackportsController: UIViewController {
    public override func viewDidLoad() {
        super.viewDidLoad()
        let child = UIView()
        view.addSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.heightAnchor.constraint(equalToConstant: 44)
        ])
        NSLayoutConstraint.deactivate(child.constraints)
        child.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let guide = UILayoutGuide()
        view.addLayoutGuide(guide)
        guide.leadingAnchor.constraint(equalTo: view.leadingAnchor).isActive = true
        let _: CGRect = guide.layoutFrame
        _ = view.layoutMarginsGuide

        let stack = UIStackView(arrangedSubviews: [child])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.spacing = 8

        view.addSubview(stack)

        let scroll = UIScrollView()
        scroll.refreshControl = UIRefreshControl()

        let layout = UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .absolute(44)))
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1), heightDimension: .absolute(44)),
                subitem: item, count: 1)
            return NSCollectionLayoutSection(group: group)
        }
        _ = UICollectionViewCompositionalLayoutConfiguration()
        _ = UICollectionView(frame: .zero, collectionViewLayout: layout)
    }
}
SWIFT
mkdir -p "$OUT/ios5.0"
"$TC/usr/bin/swiftc" "${COMMON[@]}" -target armv7-apple-ios5.0 -parse-as-library -typecheck \
  "$OUT/BackportsClient.swift" > "$OUT/ios5.0/build.log" 2>&1

# iOS 6 keeps native availability: Auto Layout exists, later families do not.
mkdir -p "$OUT/ios6.0"
cat > "$OUT/NativeAutoLayout.swift" <<'SWIFT'
import UIKit
func useAutoLayout(_ view: UIView, _ other: UIView) {
    let constraint = view.leadingAnchor.constraint(equalTo: other.leadingAnchor)
    constraint.isActive = true
}
SWIFT
"$TC/usr/bin/swiftc" "${COMMON[@]}" -target armv7-apple-ios6.0 -parse-as-library -typecheck \
  "$OUT/NativeAutoLayout.swift" > "$OUT/ios6.0/build.log" 2>&1
cat > "$OUT/LaterFamily.swift" <<'SWIFT'
import UIKit
func useLaterFamily() { _ = UIStackView() }
SWIFT
if "$TC/usr/bin/swiftc" "${COMMON[@]}" -target armv7-apple-ios6.0 -parse-as-library -typecheck \
     "$OUT/LaterFamily.swift" >> "$OUT/ios6.0/build.log" 2>&1; then
  echo 'FAIL: UIStackView must stay unavailable when compiling for iOS 6' >&2
  exit 1
fi

# A member introduced after the backported family floor stays unavailable at iOS 5.
mkdir -p "$OUT/ios5.0-negative"
cat > "$OUT/LaterMember.swift" <<'SWIFT'
import UIKit
func useLaterMember(_ stack: UIStackView, _ view: UIView) {
    stack.setCustomSpacing(8, after: view)
}
SWIFT
if "$TC/usr/bin/swiftc" "${COMMON[@]}" -target armv7-apple-ios5.0 -parse-as-library -typecheck \
     "$OUT/LaterMember.swift" > "$OUT/ios5.0-negative/build.log" 2>&1; then
  echo 'FAIL: UIStackView.setCustomSpacing(after:) (iOS 11) must stay unavailable at a backported iOS 5 floor' >&2
  exit 1
fi
# The user excluded visual effects: they must stay natively unavailable.
mkdir -p "$OUT/ios5.0-excluded"
cat > "$OUT/ExcludedFamily.swift" <<'SWIFT'
import UIKit
func useVisualEffect() { _ = UIVisualEffectView(effect: UIBlurEffect(style: .light)) }
SWIFT
if "$TC/usr/bin/swiftc" "${COMMON[@]}" -target armv7-apple-ios5.0 -parse-as-library -typecheck \
     "$OUT/ExcludedFamily.swift" > "$OUT/ios5.0-excluded/build.log" 2>&1; then
  echo 'FAIL: UIVisualEffectView must stay unavailable (excluded from the backport set)' >&2
  exit 1
fi
echo 'PASS: UIKit backports available at an iOS 5 target, version-gated for later targets and members'
