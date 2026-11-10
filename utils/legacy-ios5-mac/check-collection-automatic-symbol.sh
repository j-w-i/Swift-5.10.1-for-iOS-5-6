#!/bin/bash
# Usage: bash check-collection-automatic-symbol.sh FRONTEND RESOURCE_DIR SDK NEW_OUT
# Inspect emitted references, not just availability/typechecking. Native wins at iOS 10.
set -euo pipefail
FE=${1:?frontend}; RES=${2:?resource dir}; SDK=${3:?SDK}; OUT=${4:?new output}
[[ ! -e "$OUT" ]] || { echo 'Output already exists' >&2; exit 1; }
mkdir -p "$OUT"
printf 'import UIKit\npublic func automaticSize() -> CGSize { UICollectionViewFlowLayout.automaticSize }\n' > "$OUT/client.swift"
for MIN in 5.0 6.0 9.0 10.0; do
    "$FE" -frontend -c -parse-as-library -module-name AutomaticSymbolProbe -suppress-warnings -target "armv7-apple-ios$MIN" -sdk "$SDK" \
        -resource-dir "$RES" -enable-legacy-ios5-runtime \
        -module-cache-path "$OUT/cache-$MIN" "$OUT/client.swift" -o "$OUT/client-$MIN.o"
    xcrun nm -u "$OUT/client-$MIN.o" > "$OUT/refs-$MIN.txt"
    if [[ "$MIN" == 10.0 ]]; then
        grep -q '^_UICollectionViewFlowLayoutAutomaticSize$' "$OUT/refs-$MIN.txt"
        ! grep -q '^_SwiftLegacyUICollectionViewFlowLayoutAutomaticSize$' "$OUT/refs-$MIN.txt"
    else
        grep -q '^_SwiftLegacyUICollectionViewFlowLayoutAutomaticSize$' "$OUT/refs-$MIN.txt"
        ! grep -q '^_UICollectionViewFlowLayoutAutomaticSize$' "$OUT/refs-$MIN.txt"
    fi
    echo "PASS: iOS $MIN automaticSize references correct runtime symbol"
done
