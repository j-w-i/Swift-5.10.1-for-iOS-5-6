#!/usr/bin/env python3
"""Generate test-only reference directly from unmodified canonical SDK sources.

Not a second hand-written scanner: exact 5.10 template body/helper extraction.
Only substitutions: private test names, two gyb type expansions, and replacement
of stdlib-only unprotected pointer access with scoped public pointer access.
"""
import hashlib
import json
import pathlib
import sys

root, out = map(pathlib.Path, sys.argv[1:])
swift_path = root / 'stdlib/public/core/FloatingPointParsing.swift.gyb'
cxx_path = root / 'stdlib/public/stubs/Stubs.cpp'
swift = swift_path.read_text()
cxx = cxx_path.read_text()

def between(text, start, end):
    assert text.count(start) == 1, start
    return text[text.index(start):text.index(end, text.index(start))]

notice = swift[:swift.index('import SwiftShims')]
body = between(swift, '  @available(SwiftStdlib 5.3, *)\n  public init?(_ text: Substring)', '\n}\n\n% if bits in [16,80]:')
body = body[body.index('    self = 0.0'):body.rindex('\n  }')]
swift_reference = notice + '// Generated test-only direct canonical-source reference.\n'
swift_reference += '@_implementationOnly import _CanonicalNumericReference\n'
for name, suffix in [('Double', 'd'), ('Float', 'f')]:
    expanded = body.replace('self = 0.0', f'var result: {name} = 0.0')
    expanded = expanded.replace('_withUnprotectedUnsafeMutablePointer(to: &self)', 'withUnsafeMutablePointer(to: &result)')
    expanded = expanded.replace('${cFuncSuffix2[bits]}', suffix)
    expanded = expanded.replace('_swift_stdlib_strto', 'canonical_reference_strto')
    assert '${' not in expanded
    swift_reference += f'func canonicalReference{name}(_ text: Substring) -> {name}? {{\n{expanded}\n    return result\n}}\n'
(out / 'CanonicalReference.swift').write_text(swift_reference)

header = '#ifdef __cplusplus\nextern "C" {\n#endif\n'
for name, suffix in [('double', 'd'), ('float', 'f')]:
    header += f'const char *canonical_reference_strto{suffix}_clocale(const char *, {name} *);\n'
header += '#ifdef __cplusplus\n}\n#endif\n'
(out / 'CanonicalReference.h').write_text(header)
(out / 'module.modulemap').write_text('module _CanonicalNumericReference { header "CanonicalReference.h" export * }\n')
# Keep canonical C++ #if logic, including its unused huge parameter and TODO.
reference = cxx[:cxx.index('//\n// Misc stubs')]
reference += '\n// Generated test-only direct canonical-source reference.\n'
reference += '#include "CanonicalReference.h"\n#include <cerrno>\n#include <cmath>\n#include <cstdlib>\n#include <cstring>\n#include <limits>\n#include <xlocale.h>\n#define SWIFT_STDLIB_HAS_LOCALE 1\n'
reference += between(cxx, 'static inline locale_t getCLocale() {', '#elif defined(_WIN32)')
reference += between(cxx, 'static bool swift_stringIsSignalingNaN(', '#if defined(__CYGWIN__) || defined(__HAIKU__)')
reference += between(cxx, 'static inline void _swift_set_errno(', 'const char *_swift_stdlib_strtold_clocale(')
reference += between(cxx, 'const char *_swift_stdlib_strtod_clocale(', 'const char *_swift_stdlib_strtof16_clocale(')
reference = reference.replace('_swift_stdlib_strtod_clocale', 'canonical_reference_strtod_clocale')
reference = reference.replace('_swift_stdlib_strtof_clocale', 'canonical_reference_strtof_clocale')
(out / 'CanonicalReference.cpp').write_text(reference)
(out / 'source-manifest.json').write_text(json.dumps({
    str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (swift_path, cxx_path)
}, indent=2) + '\n')
