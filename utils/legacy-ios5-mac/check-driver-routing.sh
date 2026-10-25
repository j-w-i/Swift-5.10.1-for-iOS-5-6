#!/bin/bash
# macOS-only, planning regression: never compiles or links a program.
# Usage: check-driver-routing.sh SWIFTC SDK freshOUTPUT
# Requires Python 3 and an assembled compiler with the patched SwiftDriver backend.
# The deliberately invalid CRT/archive below are ONLY existence-check fixtures for
# -driver-print-jobs. They must never be passed to a real compilation/link step.
set -euo pipefail
if [ "$#" -ne 3 ]; then
  echo 'Usage: check-driver-routing.sh SWIFTC SDK freshOUTPUT' >&2
  exit 2
fi
[ "$(uname -s)" = Darwin ] || { echo 'Requires macOS; no cross-host driver execution.' >&2; exit 1; }
[ -x "$1" ] || { echo 'SWIFTC must name an executable.' >&2; exit 1; }
[ -d "$2" ] || { echo 'SDK must name an existing SDK directory.' >&2; exit 1; }
[ ! -e "$3" ] && [ ! -L "$3" ] || { echo 'OUTPUT must be fresh (including no dangling symlink).' >&2; exit 1; }
command -v python3 >/dev/null
python3 - "$1" "$2" "$3" <<'PY'
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

swiftc = Path(sys.argv[1]).absolute()  # Preserve swiftc symlink/name for driver dispatch.
sdk = Path(sys.argv[2]).resolve()
out = Path(sys.argv[3]).absolute()
out.mkdir()  # Atomic freshness check; never overwrite or delete an earlier run.
print('Driver routing evidence:', out, flush=True)
env = os.environ.copy()
# Do not allow the caller's driver overrides to make the modern test silently
# exercise the old implementation (or redirect its frontend to another build).
for key in ('SWIFT_USE_OLD_DRIVER', 'SWIFT_USE_NEW_DRIVER',
            'SWIFT_DRIVER_SWIFT_FRONTEND_EXEC', 'SWIFT_DRIVER_TESTS_ENABLE_EXEC_PATH_FALLBACK'):
    env.pop(key, None)
env['SWIFT_AVOID_WARNING_USING_OLD_DRIVER'] = '1'
fixture = out / 'test resources (PRINT JOBS ONLY)'
(fixture / 'iphoneos').mkdir(parents=True)
crt = fixture / 'iphoneos' / 'crt1.3.1.o'
archive = fixture / 'iphoneos' / 'libswiftLegacyIOS5Backports.a'
for path in (crt, archive):
    path.write_text('NOT A LINKABLE FILE: -driver-print-jobs fixture only\n')
source = out / 'main.swift'
source.write_text('print("driver planning only")\n')
legacy = '-enable-legacy-ios5-runtime'
commands = []


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(label, backend, args, failure=False):
    selector = [] if backend == 'modern' else ['-disallow-use-new-driver']
    command = [str(swiftc), *selector, '-sdk', str(sdk), *args]
    commands.append({'label': label, 'backend': backend, 'argv': command})
    (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    result = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    (out / (label + '.stdout')).write_text(result.stdout)
    (out / (label + '.stderr')).write_text(result.stderr)
    (out / (label + '.status')).write_text(str(result.returncode) + '\n')
    require((result.returncode != 0) if failure else (result.returncode == 0),
            f'{label}: unexpected status {result.returncode}; see retained stdout/stderr')
    if failure:
        diagnostic = result.stderr.lower()
        require('error:' in diagnostic and ('legacy' in diagnostic or legacy in diagnostic),
                f'{label}: failed for an unrelated reason, not a legacy-mode diagnostic')
        require('unknown argument' not in diagnostic and 'unknown option' not in diagnostic,
                f'{label}: backend does not recognize the legacy flags')
    return result.stdout


def info(label, backend, target, flags):
    value = json.loads(run(label, backend, ['-target', target, '-print-target-info', *flags]))
    paths = value['paths']
    resource = Path(paths['runtimeResourcePath'])
    libraries = [Path(p) for p in paths['runtimeLibraryPaths']]
    return resource, libraries


def check_jobs(label, backend, is_legacy, library):
    output = out / (label + ('.dylib' if library else '.executable'))
    flags = [legacy] if is_legacy else []
    args = ['-target', 'armv7-apple-ios7.0', '-resource-dir', str(fixture),
            '-runtime-compatibility-version', 'none', '-driver-print-jobs',
            *flags, *(['-emit-library'] if library else []), str(source), '-o', str(output)]
    printed = run(label, backend, args)
    jobs = [shlex.split(line) for line in printed.splitlines() if line.strip()]
    # Discover commands from their structure, never from a baked frontend path.
    frontends = [job for job in jobs if '-frontend' in job]
    links = [job for job in jobs if '-o' in job and
             job[job.index('-o') + 1] == str(output) and '-frontend' not in job]
    require(bool(frontends) and len(links) == 1, f'{label}: expected frontend and single linker job')
    link = links[0]
    tool = Path(link[0]).name
    # A missing swift-driver can cause swiftc to fall back silently. Distinguish
    # the actual implementations by their Darwin linker command, not help text.
    require(tool.startswith('clang') if backend == 'modern' else tool in ('ld', 'ld64'),
            f'{label}: wrong actual backend/link tool: {tool}')
    for frontend in frontends:
        require('-resource-dir' in frontend and
                frontend[frontend.index('-resource-dir') + 1] == str(fixture),
                f'{label}: frontend lost explicit resource directory')
        require((legacy in frontend) == is_legacy, f'{label}: frontend legacy forwarding')
    require(link.count(str(archive)) == int(is_legacy), f'{label}: backports archive routing')
    require(link.count(str(crt)) == int(is_legacy and not library), f'{label}: CRT routing')
    # Normalize clang -Wl, and -Xlinker encodings as well as direct ld arguments.
    linker_args = []
    for token in link[1:]:
        linker_args.extend(token[4:].split(',') if token.startswith('-Wl,') else [token])
    require(linker_args.count('-no_new_main') == int(is_legacy and not library),
            f'{label}: executable-only -no_new_main routing')
    require(any(token in ('-dylib', '-dynamiclib') for token in linker_args) == library,
            f'{label}: dynamic-library versus executable job kind')
    require(sum(Path(token).name.startswith('crt1') for token in link[1:]) ==
            int(is_legacy and not library), f'{label}: unexpected startup CRT input')
    if is_legacy:
        require(not any('force_load' in token or token == '-all_load' for token in linker_args),
                f'{label}: backports must be an ordinary archive input, not force-loaded')
    require(not output.exists() and not output.is_symlink(), f'{label}: unexpectedly created linked output')
    require(not list(out.rglob('*.o')) or list(out.rglob('*.o')) == [crt],
            f'{label}: unexpectedly compiled object output')


try:
    for backend in ('modern', 'cpp'):
        stock, stock_libs = info(backend + '-default7', backend, 'armv7-apple-ios7.0', [])
        old, old_libs = info(backend + '-legacy5', backend, 'armv7-apple-ios5.0', [legacy])
        require(stock.name == 'swift' and stock.parent.name == 'lib',
                f'{backend}: default iOS 7 resource must end in lib/swift')
        require(old == stock.parent / 'swift_ios5',
                f'{backend}: legacy iOS 5 must select parallel lib/swift_ios5')
        require(stock / 'iphoneos' in stock_libs and old / 'iphoneos' in old_libs,
                f'{backend}: runtime library paths do not follow resource selection')
        # Deployment floor alone must not opt in; opt-in must survive newer floor.
        stock5, _ = info(backend + '-default5', backend, 'armv7-apple-ios5.0', [])
        old7, _ = info(backend + '-legacy7', backend, 'armv7-apple-ios7.0', [legacy])
        require(stock5 == stock and old7 == old, f'{backend}: deployment target changed opt-in routing')
        for name, flags in (('default', []), ('legacy', [legacy])):
            resource, libs = info(backend + '-explicit-' + name, backend, 'armv7-apple-ios7.0',
                                  [*flags, '-resource-dir', str(fixture)])
            require(resource == fixture and fixture / 'iphoneos' in libs,
                    f'{backend}: explicit resource directory was replaced')
        invalid = (
            ('arm64', 'arm64-apple-ios7.0', [legacy]),
            ('simulator', 'i386-apple-ios7.0-simulator', [legacy]),
            ('conflicting-marker', 'armv7-apple-ios7.0',
             [legacy, '-disable-legacy-ios5-class-marking']),
        )
        for name, target, flags in invalid:
            run(backend + '-invalid-' + name, backend,
                ['-target', target, '-print-target-info', *flags], failure=True)
        for name, use_legacy, library in (
                ('legacy-executable', True, False),
                ('legacy-library', True, True),
                ('default-executable', False, False),
                ('default-library', False, True)):
            check_jobs(backend + '-' + name, backend, use_legacy, library)
        print('PASS:', backend, 'target-info, explicit resources, invalid modes, printed link routing', flush=True)
    print('PASS: driver planning only; no compile, link, Mach-O, deployment, or device-runtime validation.')
    print('Fixture CRT/archive are invalid and are NOT runtime artifacts. Evidence retained:', out)
except Exception as error:
    print('FAIL:', error, file=sys.stderr)
    print('Evidence retained (nothing deleted):', out, file=sys.stderr)
    sys.exit(1)
PY
