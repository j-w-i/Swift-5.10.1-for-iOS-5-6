#!/usr/bin/env python3
"""Fail closed on native public symbols, hidden C boundary, or Core imports."""
import pathlib
import subprocess
import sys

src, out, core = map(pathlib.Path, sys.argv[1:])
archive = out / 'libswiftLegacyNativeNumeric.a'

def capture(name, args):
    result = subprocess.check_output(args, text=True)
    (out / 'logs' / name).write_text(result)
    return result

symbols = capture('archive-symbols.txt', ['/usr/bin/nm', '-m', str(archive)])
undefined = capture('undefined-symbols.txt', ['/usr/bin/nm', '-u', '-j', str(archive)])
core_symbols = set(capture('core-exports.txt', ['/usr/bin/nm', '-gUj', str(core)]).splitlines())
expected = set((src / 'exports.txt').read_text().splitlines())
if expected & core_symbols:
    raise SystemExit('Selected Core already defines native entries; review duplicate integration')
public = []
definitions = set()
for line in symbols.splitlines():
    fields = line.split()
    if '(undefined)' in line or not fields:
        continue
    symbol = fields[-1]
    if 'external' in fields:
        definitions.add(symbol)
        if 'private external' not in line:
            public.append(symbol)
if set(public) != expected or len(public) != 2:
    raise SystemExit('Unexpected public definitions: ' + repr(public))
for symbol in expected:
    if sum(line.split()[-1:] == [symbol] and '(undefined)' not in line
           for line in symbols.splitlines()) != 1:
        raise SystemExit('Missing or duplicate native entry: ' + symbol)
helpers = {'_swift_legacy510_numeric_strtod', '_swift_legacy510_numeric_strtof'}
for helper in helpers:
    if not any('private external' in line and line.split()[-1:] == [helper]
               and '(undefined)' not in line for line in symbols.splitlines()):
        raise SystemExit('C helper is not hidden: ' + helper)
if '$ld$hide' in symbols:
    raise SystemExit('Unexpected relocation hide directive')
# The C implementation also calls these long-established libSystem functions.
system = {'___error', '_strtod_l', '_strtof_l', '_strlen',
          '___stack_chk_fail', '___stack_chk_guard'}
imports = {line.strip() for line in undefined.splitlines()
           if line.strip().startswith('_')}
unresolved = imports - definitions - core_symbols - system
if unresolved:
    raise SystemExit('Unqualified imports: ' + repr(sorted(unresolved)))
if imports & expected:
    raise SystemExit('Recursive native initializer import')
if any('Concurrency' in s or 'Compatibility56' in s for s in imports):
    raise SystemExit('Unexpected modern runtime import')
loads = capture('archive-load-commands.txt', ['/usr/bin/otool', '-l', str(archive)])
if 'LC_LINKER_OPTION' in loads:
    raise SystemExit('Unexpected autolink directive in archive')
(out / 'logs' / 'symbol-audit.txt').write_text(
    'PASS: exactly two public native initializer definitions; hidden C helpers; '
    'no hide/autolink directives; all imports resolve to selected Core, archive, '
    'or explicit libSystem allowlist. Final link test validates libSystem.\n')
