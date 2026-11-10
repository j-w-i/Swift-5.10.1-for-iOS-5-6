#!/bin/bash
# Usage: bash check-collection-affine-availability.sh FRONTEND RESOURCE_DIR SDK NEW_OUT
# Legacy mode lowers the iOS 7 property below 7; ordinary SDK restrictions remain.
set -euo pipefail
FE=${1:?frontend}; RES=${2:?resource dir}; SDK=${3:?SDK}; OUT=${4:?new output}
[[ ! -e "$OUT" ]] || { echo 'Output already exists' >&2; exit 1; }
mkdir -p "$OUT"
printf 'import UIKit\npublic func affine(_ attributes: UICollectionViewLayoutAttributes, _ value: CGAffineTransform) -> CGAffineTransform { attributes.transform = value; return attributes.transform }\n' > "$OUT/client.swift"
for MIN in 5.0 6.0 7.0; do
    "$FE" -frontend -c -parse-as-library -module-name AffineAvailabilityProbe -suppress-warnings -target "armv7-apple-ios$MIN" -sdk "$SDK" \
        -resource-dir "$RES" -enable-legacy-ios5-runtime -module-cache-path "$OUT/cache-$MIN" "$OUT/client.swift" -o "$OUT/client-$MIN.o"
    echo "PASS: legacy iOS $MIN affine getter/setter compile"
done
# Without backport mode, target 6 must retain the SDK's iOS 7 availability.
if "$FE" -frontend -typecheck -parse-as-library -module-name AffineAvailabilityProbe -target armv7-apple-ios6.0 -sdk "$SDK" \
    -resource-dir "$RES" -module-cache-path "$OUT/native-cache-6" "$OUT/client.swift" > "$OUT/native-6.txt" 2>&1; then
    echo 'FAIL: ordinary iOS 6 unexpectedly accepts iOS 7 affine property' >&2; exit 1
fi
if ! /usr/bin/grep -q 'only available in iOS 7' "$OUT/native-6.txt"; then
    echo 'FAIL: ordinary iOS 6 failed for an unrelated reason' >&2; exit 1
fi
"$FE" -frontend -typecheck -parse-as-library -module-name AffineAvailabilityProbe -target armv7-apple-ios7.0 -sdk "$SDK" \
    -resource-dir "$RES" -module-cache-path "$OUT/native-cache-7" "$OUT/client.swift"
echo 'PASS: ordinary iOS 6 rejects and iOS 7 accepts SDK property'
