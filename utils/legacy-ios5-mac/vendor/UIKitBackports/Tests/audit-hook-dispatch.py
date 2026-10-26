#!/usr/bin/env python3
"""Audit the injected UIView hook surface for the iOS 5 dispatch crash class.

Hooks are installed as IMPs on UIView, so `self` inside a hook is the receiving
view, not the LegacyUIViewRuntimeHooks object. Calling another @objc dynamic hook
on `self` therefore sends a selector that UIView does not implement and raises
`doesNotRecognizeSelector:` (the device crash in rr_a_addConstraints). This audit
fails the build if any hook body calls a sibling hook selector, or if the
installer references a #selector that has no hook method.
"""
import re
import sys

path = sys.argv[1]
text = open(path).read()
start = text.index('private final class LegacyUIViewRuntimeHooks')
end = text.index('// MARK: - Installer')
body = text[start:end]
violations = []

call = re.compile(r'\b(rr_[ar]_[A-Za-z0-9_]+)\s*\(')
for number, line in enumerate(body.splitlines(), 1):
    stripped = line.strip()
    for match in call.finditer(line):
        name = match.group(1)
        prefix = line[:match.start()]
        if prefix.rstrip().endswith('func'):
            continue  # definition
        if prefix.rstrip().endswith('.') or '#' in prefix:
            continue  # qualified reference, e.g. header docs/#selector
        violations.append('line %d: hook body calls sibling hook %s: %s' % (number, name, stripped))

hook_names = set(re.findall(r'@objc dynamic func (rr_[ar]_[A-Za-z0-9_]+)', text))
selectors = set(re.findall(r'#selector\(LegacyUIViewRuntimeHooks\.([A-Za-z0-9_]+)', text))
for name in sorted(selectors - hook_names):
    violations.append('#selector references missing hook method: %s' % name)

if violations:
    print('FAIL: hook dispatch audit:')
    for violation in violations:
        print('  ' + violation)
    sys.exit(1)
print('PASS: hook dispatch audit (%d hook methods, %d selectors; no sibling @objc dispatch)' %
      (len(hook_names), len(selectors)))
