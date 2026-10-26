#!/usr/bin/env python3
"""Generate the PST-mapped UIKit collection declarations used to compile the
compositional-layout runtime for legacy iOS 5.

The runtime is written against the ordinary UIKit collection API. On an iOS 5
target those classes do not exist as native classes: the toolchain ships the
PSTCollectionView implementation instead, and the Clang importer maps the public
declarations onto the PST runtime names with objc_runtime_name attributes (see
lib/ClangImporter/ClangIncludePaths.cpp). A direct Clang compile of vendored
sources does not go through the importer, so this script applies the same
mapping to private copies of the SDK's collection headers and exposes them
through a VFS overlay.

Only the compiler's supported declaration set is mapped: the eight collection
classes and the three collection protocols. The generated copies live only in
the build output directory; the selected SDK is never modified.

Usage: generate-runtime-overlay.py SDK OUT
"""
import json
import os
import re
import sys
from pathlib import Path

CLASSES = ('UICollectionView', 'UICollectionViewCell', 'UICollectionReusableView',
           'UICollectionViewLayout', 'UICollectionViewFlowLayout',
           'UICollectionViewLayoutAttributes', 'UICollectionViewController',
           'UICollectionViewUpdateItem')
PROTOCOLS = ('UICollectionViewDataSource', 'UICollectionViewDelegate',
             'UICollectionViewDelegateFlowLayout')
HEADERS = ('UICollectionView.h', 'UICollectionViewCell.h', 'UICollectionViewLayout.h',
           'UICollectionViewFlowLayout.h', 'UICollectionViewController.h',
           'UICollectionViewUpdateItem.h')


def runtime_name(name):
    # Same rule as the compiler's legacyCollectionHeader(): replace the "UI"
    # prefix, not the whole framework prefix (UICollectionViewLayout ->
    # PSTCollectionViewLayout).
    return 'PST' + name[2:]


def transform(text, origin):
    """Insert objc_runtime_name before each supported class/protocol declaration.

    Declarations must start a line (`@interface X :` / `@interface X <`), which
    excludes categories (`@interface X (`), forward declarations (`@protocol X;`)
    and protocol-list positions (`@protocol X, Y;`). Every expected declaration
    must be found exactly once; a differently shaped SDK header is a hard error,
    never a silent unmapped compile.
    """
    found = {}

    def rewrite(match):
        kind, name = match.group(1), match.group(2)
        expected = CLASSES if kind == 'interface' else PROTOCOLS
        if name not in expected:
            return match.group(0)
        if name in found:
            raise SystemExit('%s: duplicate declaration for %s' % (origin, name))
        found[name] = kind
        return '__attribute__((objc_runtime_name("%s"))) %s' % (
            runtime_name(name), match.group(0))

    pattern = re.compile(r'@(interface|protocol) (UICollection\w+)(?=\s*[:<])')
    result = pattern.sub(rewrite, text)
    return result, found


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__ + '\nUsage: generate-runtime-overlay.py SDK OUT')
    # Keep the caller's absolute SDK spelling: Clang resolves -isysroot exactly as
    # given, and a VFS root name written through a symlink (or after resolving one)
    # no longer matches the path Clang opens, silently disabling the overlay.
    sdk = Path(os.path.abspath(sys.argv[1]))
    out = Path(os.path.abspath(sys.argv[2]))
    headers = sdk / 'System' / 'Library' / 'Frameworks' / 'UIKit.framework' / 'Headers'
    if not headers.is_dir():
        raise SystemExit('No UIKit headers in SDK: %s' % headers)
    out.mkdir(parents=True, exist_ok=True)
    roots = []
    seen = set()
    for name in HEADERS:
        source = headers / name
        if not source.is_file():
            raise SystemExit('SDK is missing %s; it cannot supply the legacy collection API' % source)
        text, found = transform(source.read_text(), name)
        for declared, kind in found.items():
            expected_kind = 'interface' if declared in CLASSES else 'protocol'
            if kind != expected_kind or declared in seen:
                raise SystemExit('%s: unexpected declaration of %s' % (name, declared))
            seen.add(declared)
        target = out / ('gen-' + name)
        target.write_text(text)
        roots.append({'type': 'file', 'name': str(source),
                      'external-contents': str(target)})
    missing = [name for name in CLASSES + PROTOCOLS if name not in seen]
    if missing:
        raise SystemExit('SDK headers did not declare: ' + ', '.join(missing))
    # The pinned legacy Clang's VFS overlay parser requires "version" to be the
    # first member, so insertion order matters here (do not sort the keys).
    (out / 'overlay.json').write_text(
        json.dumps({'version': 0, 'roots': roots}, indent=2) + '\n')
    print('mapped %d collection classes and %d protocols into %s'
          % (len(CLASSES), len(PROTOCOLS), out / 'overlay.json'))


if __name__ == '__main__':
    main()
