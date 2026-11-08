#!/bin/bash
# Prepare isolated inputs only: this does not compile/install a usable runtime.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
exec "${PYTHON:-python3}" - "$SCRIPT_DIR" "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

p = argparse.ArgumentParser(description='Prepare a NEW isolated Swift 5.10 legacy-overlay probe stage; never overwrite/delete a stage.')
p.add_argument('--swift510-resource', required=True, type=Path, help='Installed host toolchain usr/lib/swift (with iphoneos modules and shims)')
p.add_argument('--swift51-source', required=True, type=Path, help='Original Swift 5.1 source checkout, including utils/gyb and stdlib/public/SwiftShims')
p.add_argument('--output', required=True, type=Path, help='Nonexistent stage directory (use a new path on retry)')
a = p.parse_args(sys.argv[2:])
script_dir = Path(sys.argv[1]).resolve()
resource = a.swift510_resource.resolve(strict=True)
old = a.swift51_source.resolve(strict=True)
out = a.output.resolve()
overlays = script_dir / 'overlays'
rebuilt = ('Dispatch', 'Foundation', 'CoreGraphics', 'Metal', 'QuartzCore', 'CoreImage', 'UIKit')

def require(condition, message):
    if not condition:
        raise RuntimeError(message)

require(sys.version_info >= (3, 8), 'Python 3.8 or newer is required')
require(not out.exists(), 'Output already exists; choose a new stage (nothing will be deleted): ' + str(out))
require(not a.output.is_symlink(), 'Output may not be a symlink')
for source in (resource, old, overlays):
    require(source != out and source not in out.parents and out not in source.parents,
            'Output must be separate from every input tree: ' + str(source))
require((resource / 'iphoneos').is_dir(), 'Missing installed iphoneos resource directory')
require((resource / 'shims').is_dir(), 'Missing installed Swift 5.10 shims')
require((resource / 'iphoneos' / 'Swift.swiftmodule').exists(), 'Missing real Swift 5.10 core module')
require((old / 'utils' / 'gyb').is_file(), 'Missing original Swift 5.1 utils/gyb')
old_shims = old / 'stdlib/public/SwiftShims'
require((old_shims / 'module.modulemap').is_file(), 'Missing original shim module definitions')
for name in rebuilt:
    require((overlays / name).is_dir(), 'Missing committed migrated overlay: ' + name)

# No installed runtime binaries are transplanted: these are compiler/import
# inputs, not evidence of ABI compatibility with the old target runtime.
def ignore_resources(directory, names):
    ignored = []
    for name in names:
        if (name in ('__pycache__', '.DS_Store') or
            name.endswith(('.dylib', '.a', '.o', '.so', '.dll', '.lib')) or
            re.search(r'\.so\.', name) or
            any(name == module + ext for module in rebuilt
                for ext in ('.swiftmodule', '.swiftdoc', '.swiftsourceinfo', '.abi.json'))):
            ignored.append(name)
    return ignored

# Validate source lists before creating output. CMake lists deliberately omit
# some .swift files in Foundation; globbing that directory is not equivalent.
source_lists = {}
for name in rebuilt:
    source = overlays / name
    cmake = source / 'CMakeLists.txt'
    if cmake.exists():
        text = '\n'.join(line.split('#', 1)[0] for line in cmake.read_text().splitlines())
        text = text.split('add_swift_target_library(', 1)[1].split('SWIFT_COMPILE_FLAGS', 1)[0]
        files = re.findall(r'(?<![\w/])([\w+.-]+\.swift(?:\.gyb)?)\b', text)
    else:
        files = sorted(path.name for path in source.glob('*.swift'))
    require(files and len(files) == len(set(files)), 'Missing/duplicate source list for ' + name)
    for filename in files:
        require((source / filename).is_file(), 'Missing overlay source: ' + str(source / filename))
    source_lists[name] = files

# Use the real old module declarations, but never redeclare SwiftShims or
# SwiftOverlayShims. Swift 5.10 must retain its own core ABI shim definitions.
module_text = (old_shims / 'module.modulemap').read_text()
blocks = re.findall(r'module\s+(_Swift\w+OverlayShims)\s*\{[^}]*\}', module_text, re.S)
require('_SwiftFoundationOverlayShims' in blocks and '_SwiftDispatchOverlayShims' in blocks,
        'Original module map lacks required real Foundation/Dispatch overlay shims')
legacy_map = '\n\n'.join(match.group(0) for match in
    re.finditer(r'module\s+_Swift\w+OverlayShims\s*\{[^}]*\}', module_text, re.S)) + '\n'

out.mkdir(parents=True, exist_ok=False)
probes = out / 'probes'
probes.mkdir()
shutil.copytree(resource, probes / 'modules510', ignore=ignore_resources, symlinks=False)
shutil.copytree(overlays, out / 'src/legacy-overlays', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
shims = probes / 'dispatch-shims'
shims.mkdir()
# Copy the complete real header closure, including NS*, CF*, Visibility and
# FoundationShimSupport. Keeping it separate avoids replacing modern shims.
for header in sorted(old_shims.glob('*.h')):
    shutil.copy2(header, shims / header.name)
(shims / 'module.modulemap').write_text(legacy_map)
cdispatch = overlays / 'Dispatch/CDispatch'
require((cdispatch / 'module.modulemap').is_file(), 'Missing real CDispatch module')
# Co-locate both maps: the existing probe scripts pass -I dispatch-shims.
with (shims / 'module.modulemap').open('a') as f:
    f.write('\n' + (cdispatch / 'module.modulemap').read_text())
shutil.copytree(cdispatch / 'cdispatch', shims / 'cdispatch')

# GYB runs serially using the original source utility with Python 3, not its
# python2.7 shebang and never generated files from a previous build directory.
env = dict(os.environ)
env['PYTHONDONTWRITEBYTECODE'] = '1'  # Never mutate the original source checkout.
# Sources are generated once per pointer width: armv7/armv7s are 32-bit, arm64 is 64-bit, and
# the gyb templates bake that decision in (CGFloat.NativeType is Float on 32-bit, Double on 64-bit).
for name, files in source_lists.items():
    for width, generated_dir, suffix in ((4, 'generated', ''), (8, 'generated-64', '-64')):
        response = []
        for filename in files:
            path = out / 'src/legacy-overlays' / name / filename
            if filename.endswith('.gyb'):
                generated = out / generated_dir / name / filename[:-4]
                generated.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run([sys.executable, str(old / 'utils/gyb'), '--line-directive=',
                                '-DCMAKE_SIZEOF_VOID_P=' + str(width), str(path), '-o', str(generated)],
                               env=env, check=True)
                require(generated.stat().st_size > 0, 'GYB generated an empty source: ' + str(generated))
                path = generated
            # Swift response files accept double quoted paths with escaped quotes.
            response.append('"' + str(path).replace('\\', '\\\\').replace('"', '\\"') + '"')
        (probes / (name.lower() + '510-sources' + suffix + '.txt')).write_text('\n'.join(response) + '\n')

# Content manifest allows comparing preparation runs without relying on mtimes.
manifest = {}
for path in sorted(out.rglob('*')):
    if path.is_file():
        manifest[str(path.relative_to(out))] = hashlib.sha256(path.read_bytes()).hexdigest()
(out / 'bootstrap-manifest.json').write_text(json.dumps({
    'schema': 1, 'inputs': {'swift510Resource': str(resource), 'swift51Source': str(old),
                           'migratedOverlays': str(overlays)},
    'rebuiltOverlaysExcluded': rebuilt, 'sha256': manifest,
    'warning': 'Import/compiler inputs only; target runtime, CRT, linking, ABI and device validation still required.'
}, indent=2, sort_keys=True) + '\n')
print('Prepared isolated inputs: ' + str(out))
print('Resource tree: ' + str(probes / 'modules510'))
print('Real legacy overlay shims: ' + str(shims))
print('No compilation, installation, runtime validation or global toolchain changes performed.')
PY
