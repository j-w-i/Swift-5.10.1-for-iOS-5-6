#!/bin/bash
# Assemble an isolated experimental toolchain; NEVER installs or selects it.
# Usage: assemble-510-toolchain.sh BASELINE.xctoolchain FRONTEND SWIFT_DRIVER \
#          STAGE OLD_RUNTIME_DIR BACKPORTS_ARCHIVE CRT1_OBJECT NEW.xctoolchain
# STAGE must have probes/modules510 and probes/linked510 from preparation/build/link.
# OLD_RUNTIME_DIR is a build root containing lib/swift/iphoneos, or that directory.
# BACKPORTS_ARCHIVE and CRT1_OBJECT are explicit, real armv7 build products.
# Default resources remain the complete baseline usr/lib/swift installation.
# No runtime5.1.5 slot is created. The ios5 resource slot is opt-in, experimental.
# Run on macOS when ready; this script does not build or qualify any input.
set -euo pipefail
umask 022
if [ "$#" -ne 8 ]; then
  printf '%s\n' 'Usage: assemble-510-toolchain.sh BASELINE.xctoolchain FRONTEND SWIFT_DRIVER STAGE OLD_RUNTIME_DIR BACKPORTS_ARCHIVE CRT1_OBJECT NEW.xctoolchain' >&2
  exit 64
fi
command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'python3 is required.' >&2; exit 1; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# The python block is read from stdin, so it cannot use __file__; pass the helper
# location explicitly for the dylib version normalization step.
export LEGACY_NORMALIZE_DYLIB_VERSIONS="$HERE/normalize-dylib-versions.py"
[ -f "$LEGACY_NORMALIZE_DYLIB_VERSIONS" ] || { printf '%s\n' 'missing normalize-dylib-versions.py beside this script' >&2; exit 1; }
exec python3 - "$@" <<'PY'

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ID = 'org.swift.5101.ios5.experimental'
OVERLAYS = ('Dispatch', 'CoreGraphics', 'Foundation', 'Metal', 'QuartzCore', 'CoreImage', 'UIKit')

def fail(message):
    raise SystemExit('assemble-510-toolchain: ' + str(message))

def run(*args):
    result = subprocess.run([str(x) for x in args], text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    if result.returncode:
        fail(f'{args[0]} failed ({result.returncode}): {result.stderr.strip()}')
    return result.stdout

def tool(name):
    value = shutil.which(name)
    if not value:
        fail('Required verification tool not found: ' + name)
    return value

try:
    if sys.platform != 'darwin':
        fail('Assembly requires macOS file/otool; no cross-host assembly is supported.')
    paths = [Path(x) for x in sys.argv[1:]]
    if any(not p.is_absolute() for p in paths):
        fail('All eight paths must be explicit absolute paths.')
    baseline, frontend, driver, stage, old, backports, crt1, requested = paths
    if requested.exists() or requested.is_symlink():
        fail('Output already exists (including symlinks): ' + str(requested))
    if not requested.parent.is_dir() or requested.suffix != '.xctoolchain':
        fail('Output needs an existing parent and a .xctoolchain suffix.')
    baseline, frontend, driver, stage, old, backports, crt1 = [
        p.resolve(strict=True) for p in paths[:-1]]
    out = requested.parent.resolve(strict=True) / requested.name
    inputs = (baseline, frontend, driver, stage, old, backports, crt1)
    for p in inputs:
        if p == out or out in p.parents or p in out.parents:
            fail('Output and inputs must not overlap: ' + str(p))
    # No global toolchain installation, even when explicitly supplied as output.
    for root in (Path('/Library/Developer/Toolchains'),
                 Path.home() / 'Library/Developer/Toolchains', Path('/Applications')):
        if root.resolve() == out or root.resolve() in out.parents:
            fail('Choose a staging output outside global/user installation locations.')
    FILE, OTOOL, AR, NM = (tool(x) for x in ('file', 'otool', 'ar', 'nm'))
    CODESIGN = shutil.which('codesign')  # optional, never Gatekeeper/quarantine changes
    modules = stage / 'probes/modules510'
    linked_name = os.environ.get('LINK_OUTPUT_NAME', 'linked510')
    if '/' in linked_name or linked_name.startswith('.'):
        fail('LINK_OUTPUT_NAME must be a simple non-hidden directory name.')
    linked = stage / 'probes' / linked_name
    oldlib = old / 'lib/swift/iphoneos'
    if not oldlib.is_dir():
        oldlib = old

    def nonempty(p):
        if not p.is_file() or p.stat().st_size == 0:
            fail('Missing or empty required file: ' + str(p))

    for p in (baseline / 'Info.plist', frontend, driver, backports, crt1):
        nonempty(p)
    for p in (baseline / 'usr/lib/swift', baseline / 'usr/lib/clang',
              baseline / 'usr/bin', modules, linked, oldlib):
        if not p.is_dir():
            fail('Missing required directory: ' + str(p))
    # Writable output ancestors must be real directories, not baseline links back
    # to an original installation. Preserve all other baseline symlinks verbatim.
    for relative in ('usr', 'usr/bin', 'usr/lib'):
        if (baseline / relative).is_symlink():
            fail('Unsafe symlink in baseline output ancestor: ' + relative)
    if (modules / 'iphoneos').is_symlink() or not (modules / 'iphoneos').is_dir():
        fail('Staged iphoneos must be a real module directory.')
    for p in modules.rglob('*'):
        if p == modules / 'clang':
            continue
        if p.is_symlink():
            target = p.resolve(strict=True)
            if os.path.isabs(os.readlink(p)) or modules not in target.parents:
                fail('Staged resource symlink escapes the copied module tree: ' + str(p))
    with (baseline / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') == ID:
        fail('Baseline already uses the experimental identifier.')
    for reserved in ('usr/lib/swift_ios5', 'ios5-assembly-receipt.json'):
        if os.path.lexists(baseline / reserved):
            fail('Baseline already contains reserved output: ' + reserved)
    for name in ('swift-frontend', 'swift-driver', 'swift', 'swiftc'):
        nonempty(baseline / 'usr/bin' / name)
    for p in (frontend, driver):
        if not os.access(p, os.X_OK):
            fail('Patched compiler/driver must be executable: ' + str(p))
        desc = run(FILE, '-b', p).strip()
        if not re.fullmatch(r'Mach-O 64-bit executable x86_64(?:,.*)?', desc):
            fail('Expected a compiled thin x86_64 Mach-O executable, not a wrapper/fat binary: ' + desc)
        if 'EXECUTE' not in run(OTOOL, '-hv', p):
            fail('Mach-O input is not MH_EXECUTE: ' + str(p))

    def dependencies(p, image):
        # Check in the intended installation layout, not against build-tree libs.
        lines = run(OTOOL, '-L', p).splitlines()[1:]
        loads = run(OTOOL, '-l', p)
        rpaths = re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset \d+\)', loads)
        def expand(value):
            return value.replace('@loader_path', str(image.parent)).replace(
                '@executable_path', str(baseline / 'usr/bin'))
        for line in lines:
            dep = line.strip().split(' (compatibility version', 1)[0]
            if not dep:
                continue
            if dep.startswith(('/usr/lib/', '/System/Library/')):
                continue
            if dep.startswith('@rpath/'):
                candidates = [Path(expand(r)) / dep[len('@rpath/'):] for r in rpaths]
            elif dep.startswith(('@loader_path/', '@executable_path/')):
                candidates = [Path(expand(dep))]
            else:
                fail('Nonrelocatable compiler dependency: ' + dep)
            valid = False
            for candidate in candidates:
                resolved = candidate.resolve()
                if (baseline in resolved.parents and resolved.is_file()) or (
                    str(resolved).startswith(('/usr/lib/', '/System/Library/'))):
                    valid = True
            if not valid:
                fail('Unresolved/nonrelocatable compiler dependency: ' + dep)
    dependencies(frontend, baseline / 'usr/bin/swift-frontend')
    dependencies(driver, baseline / 'usr/bin/swift-driver')

    for name in ('Core', 'Darwin', 'ObjectiveC', 'CoreFoundation'):
        nonempty(oldlib / ('libswift' + name + '.dylib'))
        # ObjectiveC/CoreFoundation import from the real selected SDK (Clang or
        # SDK overlay), not fabricated local Swift modules. Core/Darwin ship
        # with this compiler and must be present in its resource tree.
        if name not in ('Core', 'Darwin'):
            continue
        module = modules / 'iphoneos' / (('Swift' if name == 'Core' else name) + '.swiftmodule')
        if not any((module / candidate).is_file() and (module / candidate).stat().st_size > 0
                   for candidate in ('armv7.swiftmodule', 'armv7-apple-ios.swiftmodule')):
            fail('Missing actual armv7 import module: ' + str(module))
    for name in OVERLAYS:
        nonempty(modules / 'iphoneos' / (name + '.swiftmodule') / 'armv7.swiftmodule')
        dylib = linked / ('libswift' + name + '.dylib')
        nonempty(dylib)
        if not re.search(r'arm_?v7\b', run(FILE, '-b', dylib)) or 'DYLIB' not in run(OTOOL, '-hv', dylib):
            fail('Expected a rebuilt armv7 Mach-O dylib: ' + str(dylib))
        ids = run(OTOOL, '-D', dylib).splitlines()[1:]
        if ids != ['@rpath/' + dylib.name]:
            fail('Unexpected overlay install name: ' + str(dylib))
        run(OTOOL, '-L', dylib)
    for p in modules.rglob('*.swiftmodule'):
        if p.is_dir():
            if not any(x.is_file() and x.stat().st_size for x in p.rglob('*')):
                fail('Empty module directory: ' + str(p))
        else:
            nonempty(p)
    if not run(AR, '-t', backports).strip():
        fail('Backports archive has no real members.')
    if not re.search(r'\b[Tt]\s+_swift_stdlib_isStackAllocationSafe\b', run(NM, '-g', backports)):
        fail('Backports archive lacks the rebuilt stack-allocation helper.')
    if not re.search(r'\bARM\s+V7\b', run(OTOOL, '-hv', backports)):
        fail('Backports archive must contain armv7 Mach-O objects.')
    if not re.search(r'arm_?v7\b', run(FILE, '-b', crt1)) or 'OBJECT' not in run(OTOOL, '-hv', crt1):
        fail('CRT1 input must be a real armv7 Mach-O object.')

    # Atomic claim. Failed outputs are deliberately retained; never delete/reuse.
    out.mkdir()
    print('Copying complete baseline to ' + str(out), flush=True)
    shutil.copytree(baseline, out, symlinks=True, dirs_exist_ok=True)
    # Replace only copied paths via new regular files, never follow copied links.
    def replace_copy(source, destination):
        temporary = destination.with_name(destination.name + '.ios5-new')
        if os.path.lexists(temporary):
            fail('Unexpected temporary output collision: ' + str(temporary))
        with source.open('rb') as src, temporary.open('xb') as dst:
            shutil.copyfileobj(src, dst)
        shutil.copymode(source, temporary)
        os.replace(temporary, destination)
    # swift/swiftc are aliases of the driver. They must stay byte-identical (the
    # qualification evidence binds one driver hash for all three), and ad-hoc
    # signing produces a different signature per file, so the signed driver is
    # copied over the aliases below instead of being signed separately.
    for name, source in (('swift-frontend', frontend), ('swift-driver', driver)):
        replace_copy(source, out / 'usr/bin' / name)
    slot = out / 'usr/lib/swift_ios5'
    # The staged clang link points into its original host tree: do not copy it.
    shutil.copytree(modules, slot, symlinks=True,
                    ignore=lambda root, names: ['clang'] if Path(root) == modules else [])
    # Swift derives Clang's resource directory as <swift-resource-dir>/clang, so
    # that entry must itself be a Clang resource directory (the one containing
    # include/stdarg.h), not the directory that holds version subdirectories.
    clang_resources = []
    for candidate in sorted((out / 'usr/lib/clang').iterdir()):
        if candidate.is_dir() and (candidate / 'include/stdarg.h').is_file():
            clang_resources.append(candidate)
    if not clang_resources:
        fail('Baseline toolchain has no usr/lib/clang/<version>/include/stdarg.h.')
    chosen = clang_resources[-1]
    # Clang emits __isPlatformVersionAtLeast for @available checks on iOS, and the
    # baseline only ships macOS builtins. Without the armv7 iOS compiler-rt archive
    # any Objective-C dependency using availability fails to link with
    # "Undefined symbols: ___isPlatformVersionAtLeast".
    builtins = Path(os.environ.get('LEGACY_515_ROOT', '')) / 'build/crt-armv7-ios50/lib/darwin/libclang_rt.ios.a'
    if not builtins.is_file():
        fail('iOS compiler-rt builtins missing (run the crt-515 stage): ' + str(builtins))
    builtins_dir = chosen / 'lib' / 'darwin'
    builtins_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(builtins, builtins_dir / 'libclang_rt.ios.a')
    (slot / 'clang').symlink_to(os.path.relpath(chosen, slot), target_is_directory=True)
    if not (slot / 'clang/include/stdarg.h').is_file():
        fail('Slot clang resource link does not expose Clang builtin headers.')
    # The rebuilt overlays import the legacy Swift 5.1 overlay shim modules, so
    # they must ship with the toolchain for clients to compile.
    shims_source = stage / 'probes/dispatch-shims'
    if not (shims_source / 'module.modulemap').is_file():
        fail('Stage lacks probes/dispatch-shims/module.modulemap.')
    shutil.copytree(shims_source, slot / 'legacy-overlay-shims', symlinks=True)
    ios = slot / 'iphoneos'
    # Modules always come from the rebuilt tree, never from OLD_RUNTIME_DIR.
    for source in sorted(oldlib.glob('*.dylib')):
        replace_copy(source, ios / source.name)
    for name in OVERLAYS:
        source = linked / ('libswift' + name + '.dylib')
        replace_copy(source, ios / source.name)
    replace_copy(backports, ios / 'libswiftLegacyIOS5Backports.a')
    # The overlays are linked by a different toolchain than the runtime they sit
    # beside, so the LC_ID_DYLIB versions can be lower than what their consumers
    # require; iOS 5 dyld rejects that ("requires 1.0.0 ... provides 0.0.0").
    run(sys.executable, os.environ['LEGACY_NORMALIZE_DYLIB_VERSIONS'], str(ios))

    replace_copy(crt1, ios / 'crt1.3.1.o')
    info['CFBundleIdentifier'] = ID
    info['DisplayName'] = 'Swift 5.10.1 — iOS 5 Experimental'
    info['CFBundleDisplayName'] = info['DisplayName']
    info['CFBundleName'] = info['DisplayName']
    # Info.plist may be a copied symlink; replacement never touches its referent.
    temporary = out / 'Info.plist.ios5-new'
    with temporary.open('xb') as stream:
        plistlib.dump(info, stream)
    os.replace(temporary, out / 'Info.plist')

    signed = []
    for name in ('swift-frontend', 'swift-driver'):
        p = out / 'usr/bin' / name
        run(FILE, '-b', p)
        run(OTOOL, '-L', p)
        if CODESIGN:
            run(CODESIGN, '--force', '--sign', '-', p)
            run(CODESIGN, '--verify', '--strict', '--verbose=2', p)
            signed.append(str(p.relative_to(out)))
    for alias in ('swift', 'swiftc'):
        replace_copy(out / 'usr/bin' / 'swift-driver', out / 'usr/bin' / alias)
        if CODESIGN:
            run(CODESIGN, '--verify', '--strict', '--verbose=2', out / 'usr/bin' / alias)
            signed.append('usr/bin/' + alias)
    def digest(p):
        h = hashlib.sha256()
        with p.open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                h.update(block)
        return h.hexdigest()
    receipt = {
        'toolchainID': ID, 'baseline': str(baseline), 'stage': str(stage),
        'defaultResourceProfile': 'baseline', 'ios5ResourceDirectory': 'usr/lib/swift_ios5',
        'runtime515SlotIncluded': False, 'overlays': list(OVERLAYS),
        'inputs': {str(p): digest(p) for p in (frontend, driver, backports, crt1)},
        'adhocSignedAndVerified': signed,
        'limitations': ['Packaging only; no compiler execution or device tests.',
                        'iOS 5 ABI/import/load-command/runtime qualification is pending.',
                        'Baseline receipts/default resources preserved; no profile selection changed.',
                        'Ad-hoc signatures are not Developer ID signing or notarization.']}
    with (out / 'ios5-assembly-receipt.json').open('x') as stream:
        json.dump(receipt, stream, indent=2)
        stream.write('\n')
    print('Assembled: ' + str(out))
    print('Default resources: unchanged baseline. iOS5 resources: opt-in usr/lib/swift_ios5.')
    print('No installation/selection performed; no runtime5.1.5 slot included.')
    if not CODESIGN:
        print('WARNING: codesign unavailable; output signature verification NOT performed.')
    print('Packaging only: iOS 5 device execution and regression qualification remain pending.')
except (OSError, ValueError, plistlib.InvalidFileException) as error:
    fail(error)
PY
