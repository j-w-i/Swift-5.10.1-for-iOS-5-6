#!/bin/bash
# Check the installed, real-SDK Foundation backport API and exported runtime ABI.
# Usage: check-foundation-api.sh TOOLCHAIN SDK NEW_OUTPUT
# iOS 6 noninterference is covered by test/ClangImporter/legacy_ios5_foundation.swift;
# do not confuse a mismatched SDK's native Swift overlay load failure with gating.
set -euo pipefail
TC=${1:?toolchain}; SDK=${2:?SDK}; OUT=${3:?new output directory}
[[ "$TC" = /* && "$SDK" = /* && "$OUT" = /* ]] || { echo 'Use absolute paths.' >&2; exit 64; }
[ ! -e "$OUT" ] || { echo "Refusing to overwrite $OUT" >&2; exit 1; }
RES="$TC/usr/lib/swift_ios5"
RUNTIME="$RES/iphoneos/libswiftFoundation.dylib"
[ -x "$TC/usr/bin/swiftc" ] && [ -d "$SDK" ] && [ -f "$RUNTIME" ] || { echo 'Missing toolchain, SDK, or Foundation runtime.' >&2; exit 1; }
mkdir -p "$OUT"
report_failure() {
  local status=$?
  /usr/bin/python3 - "$OUT" <<'PY'
from pathlib import Path
import sys
for p in sorted(Path(sys.argv[1]).glob('*.log')):
    print(str(p) + ':', file=sys.stderr)
    print('\n'.join(p.read_text(errors='replace').splitlines()[-30:]), file=sys.stderr)
PY
  exit "$status"
}
trap report_failure ERR
COMMON=(-sdk "$SDK" -resource-dir "$RES" -enable-legacy-ios5-runtime
  -target armv7-apple-ios5.0 -parse-as-library
  -Xcc -DOS_OBJECT_USE_OBJC=0 -Xcc -I"$RES/legacy-overlay-shims"
  -module-cache-path "$OUT/module-cache"
  -runtime-compatibility-version none -disable-autolinking-runtime-compatibility-dynamic-replacements
  -Xfrontend -disable-autolink-library -Xfrontend swiftFileProvider)
cat > "$OUT/FoundationClient.swift" <<'SWIFT'
import Foundation
public func foundationClient() {
    var c = URLComponents(string: "https://example.com/a?q=v")!
    c.queryItems = [URLQueryItem(name: "x", value: "y")]
    _ = c.query
    _ = c.percentEncodedQuery
    _ = c.string
    _ = c.url
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    _ = iso.string(from: Date())
    _ = iso.date(from: "2020-01-01T00:00:00.000Z")
    let config = URLSessionConfiguration.default
    config.httpShouldSetCookies = false
    let session = URLSession(configuration: config)
    let task = session.dataTask(with: URL(string: "http://example.com")!)
    task.resume()
    task.cancel()
    _ = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in }
    _ = Calendar.current.isDateInToday(Date())
    _ = Calendar.current.isDate(Date(), inSameDayAs: Date())
    _ = CharacterSet.urlQueryAllowed
    _ = "hello world".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    _ = "hello%20world".removingPercentEncoding
    _ = Data([1, 2, 3]).base64EncodedString()
    _ = Data(base64Encoded: "AQID", options: .ignoreUnknownCharacters)
}
public func foundationClasses() -> [AnyClass] {
    [NSURLComponents.self, NSURLQueryItem.self, ISO8601DateFormatter.self,
     URLSession.self, URLSessionConfiguration.self, URLSessionTask.self,
     URLSessionDataTask.self, URLSessionUploadTask.self, URLSessionDownloadTask.self]
}
SWIFT
"$TC/usr/bin/swiftc" "${COMMON[@]}" -emit-ir "$OUT/FoundationClient.swift" -o "$OUT/client.ll" > "$OUT/positive.log" 2>&1
# Keep each denial independent: one error must not conceal an accidentally
# callable unsupported member, and module-load failure must never count as PASS.
/usr/bin/python3 - "$OUT" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
checks = {
    'protocolClasses': ('func f(_ x: URLSessionConfiguration) { _ = x.protocolClasses }', 'not implemented by the legacy iOS 5 Foundation runtime'),
    'ephemeral': ('func f() { _ = URLSessionConfiguration.ephemeral }', 'not implemented by the legacy iOS 5 Foundation runtime'),
    'suspend': ('func f(_ x: URLSessionTask) { x.suspend() }', 'not implemented by the legacy iOS 5 Foundation runtime'),
    'percentEncodedQueryItems': ('func f(_ x: NSURLComponents) { _ = x.percentEncodedQueryItems }', 'not implemented by the legacy iOS 5 Foundation runtime'),
    'rangeOfScheme': ('func f(_ x: NSURLComponents) { _ = x.rangeOfScheme }', 'not implemented by the legacy iOS 5 Foundation runtime'),
    'withWeekOfYear': ('func f() { _ = ISO8601DateFormatter.Options.withWeekOfYear }', 'not implemented by the legacy iOS 5 Foundation runtime'),
    'guardedRanges': ('@available(iOS 13.0, *) func f(_ x: URLComponents) { _ = x.rangeOfScheme }', 'not implemented by the legacy iOS 5 Foundation runtime'),
    'guardedQueryItems': ('@available(iOS 13.0, *) func f(_ x: URLComponents) { _ = x.percentEncodedQueryItems }', 'not implemented by the legacy iOS 5 Foundation runtime'),
    'guardedPriority': ('@available(iOS 13.0, *) func f(_ x: URLSessionTask) { _ = x.priority }', 'not implemented by the legacy iOS 5 Foundation runtime'),
}
for name, (source, diagnostic) in checks.items():
    (out / (name + '.swift')).write_text('import Foundation\n' + source + '\n')
    (out / (name + '.expected')).write_text(diagnostic)
PY
for name in protocolClasses ephemeral suspend percentEncodedQueryItems rangeOfScheme withWeekOfYear guardedRanges guardedQueryItems guardedPriority; do
  if "$TC/usr/bin/swiftc" "${COMMON[@]}" -typecheck "$OUT/$name.swift" > "$OUT/$name.log" 2>&1; then
    echo "FAIL: unsupported Foundation API $name compiled" >&2
    exit 1
  fi
done
# The runtime is fat; name the armv7 slice so the audit reads the legacy implementation.
/usr/bin/nm -arch armv7 -gU "$RUNTIME" > "$OUT/runtime-symbols.txt" 2> "$OUT/nm.log"
/usr/bin/python3 - "$OUT" <<'PY'
from pathlib import Path
import re
import sys
out = Path(sys.argv[1])
ir = (out / 'client.ll').read_text()
symbols = (out / 'runtime-symbols.txt').read_text()
names = ['URLComponents', 'URLQueryItem', 'ISO8601DateFormatter', 'URLSession',
         'URLSessionConfiguration', 'URLSessionTask', 'URLSessionDataTask',
         'URLSessionUploadTask', 'URLSessionDownloadTask']
for name in names:
    assert 'OBJC_CLASS_$_FBP' + name + '"' in ir, ('missing IR backport class', name)
    assert 'OBJC_CLASS_$_NS' + name + '"' not in ir, ('native class reference', name)
    assert re.search(r'\bS _OBJC_CLASS_\$_FBP' + name + r'$', symbols, re.M), ('missing exported runtime class', name)
for expected in out.glob('*.expected'):
    diagnostic = (out / (expected.stem + '.log')).read_text()
    assert expected.read_text() in diagnostic, (expected.stem, diagnostic)
    assert 'error:' in diagnostic and 'could not build' not in diagnostic and 'failed to build module' not in diagnostic, expected.stem
print('PASS: real Foundation client, all 9 FBP class references/exports, 9 independent API denials')
PY
