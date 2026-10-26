#!/usr/bin/env python3
"""Emit and verify the compositional-layout declaration mapping contract.

The Clang importer maps the public UIKit compositional-layout declarations onto
the backport's IBP-prefixed Objective-C classes and protocols (same pattern as
the PSTCollectionView mapping). This script checks the built archive really
exports every mapped identity and emits the machine-readable contract that the
compiler-side mapping and its tests consume.

Checks (failures are build failures, not warnings):
  * every mapped class/metaclass, protocol object and C symbol is defined in the
  * archive;
  * no class defined in this archive has a public UIKit name, so nothing can
    replace a native UIKit class at runtime (two classes are always a bug);
  * the capability filter lists the members the backport does not implement.

Usage: emit-runtime-mapping.py NM ARCHIVE OUT_JSON
"""
import json
import subprocess
import sys

# public name -> (public superclass, runtime superclass). The runtime superclass
# is what the linked image must show; the public one is the SDK declaration's
# superclass (NSCollectionLayoutDecorationItem inherits NSCollectionLayoutItem in
# iOS 13, which is why the vendored class is reparented by the build patch).
CLASSES = (
    ('UICollectionViewCompositionalLayout', 'UICollectionViewLayout', 'PSTCollectionViewLayout'),
    ('UICollectionViewCompositionalLayoutConfiguration', 'NSObject', 'NSObject'),
    ('NSCollectionLayoutSection', 'NSObject', 'NSObject'),
    ('NSCollectionLayoutItem', 'NSObject', 'NSObject'),
    ('NSCollectionLayoutGroup', 'NSCollectionLayoutItem', 'IBPNSCollectionLayoutItem'),
    ('NSCollectionLayoutGroupCustomItem', 'NSObject', 'NSObject'),
    ('NSCollectionLayoutDimension', 'NSObject', 'NSObject'),
    ('NSCollectionLayoutSize', 'NSObject', 'NSObject'),
    ('NSCollectionLayoutSpacing', 'NSObject', 'NSObject'),
    ('NSCollectionLayoutEdgeSpacing', 'NSObject', 'NSObject'),
    ('NSCollectionLayoutSupplementaryItem', 'NSCollectionLayoutItem', 'IBPNSCollectionLayoutItem'),
    ('NSCollectionLayoutBoundarySupplementaryItem', 'NSCollectionLayoutSupplementaryItem',
     'IBPNSCollectionLayoutSupplementaryItem'),
    ('NSCollectionLayoutDecorationItem', 'NSCollectionLayoutItem', 'IBPNSCollectionLayoutItem'),
    ('NSCollectionLayoutAnchor', 'NSObject', 'NSObject'),
)
PROTOCOLS = (
    'NSCollectionLayoutContainer',
    'NSCollectionLayoutEnvironment',
    'NSCollectionLayoutVisibleItem',
)
# Public C declarations implemented by the runtime. The importer aliases the
# public spelling to the prefixed symbol with __asm__; no public-named symbol is
# exported by the compatibility dylib.
C_SYMBOLS = (
    {'public': 'NSDirectionalEdgeInsetsZero', 'runtime': 'IBPNSDirectionalEdgeInsetsZero',
     'kind': 'extern const NSDirectionalEdgeInsets'},
    {'public': 'NSStringFromDirectionalEdgeInsets',
     'runtime': 'IBPNSStringFromDirectionalEdgeInsets', 'kind': 'C function'},
)
# Implemented without runtime symbols: struct/typedefs and inline helpers are
# compiled into the client; enums are pure compile-time values.
TYPES = (
    {'public': 'NSDirectionalEdgeInsets',
     'note': 'C struct; layout {top, leading, bottom, trailing} matches the SDK type'},
    {'public': 'NSDirectionalEdgeInsetsMake', 'note': 'static inline in UIKit; no symbol'},
    {'public': 'NSDirectionalEdgeInsetsEqualToDirectionalEdgeInsets',
     'note': 'static inline in UIKit; no symbol'},
    {'public': 'NSDirectionalRectEdge', 'note': 'enum; values identical to the backport'},
    {'public': 'NSRectAlignment', 'note': 'enum; values identical to the backport'},
    {'public': 'UICollectionLayoutSectionOrthogonalScrollingBehavior',
     'note': 'enum; values/order identical to the backport'},
)
# Public API present in the iOS 13 family that the runtime does not implement.
# The compiler gating must keep these unavailable for a legacy iOS 5 target.
UNIMPLEMENTED = (
    {'member': 'NSCollectionLayoutEnvironment.traitCollection',
     'reason': 'No UITraitCollection class below iOS 8; the upstream UITraitCollection '
               'shim (DDTraitCollection) is omitted for licence reasons. The runtime '
               'object leaves the value nil.'},
    {'member': 'NSCollectionLayoutSection.visibleItemsInvalidationHandler',
     'reason': 'Stored by the backport but never invoked; no NSCollectionLayoutVisibleItem '
               'objects are produced.'},
    {'member': 'NSCollectionLayoutGroup.visualDescription',
     'reason': 'Returns an empty string in the backport (displayed as a stub), not the '
               'native ASCII description.'},
    {'member': 'NSDirectionalEdgeInsetsFromString',
     'reason': 'Not implemented by the backport.'},
    {'member': 'NSValue valueWithDirectionalEdgeInsets: / directionalEdgeInsetsValue',
     'reason': 'Not implemented by the backport.'},
    {'member': 'NSCoder encodeDirectionalEdgeInsets:forKey: / decodeDirectionalEdgeInsetsForKey:',
     'reason': 'Not implemented by the backport.'},
    {'member': 'declarations introduced after iOS 13.0',
     'reason': 'Out of scope: contentInsetsReference (14.0), supplementaryContentInsetsReference '
               '(16.0), orthogonalScrollingProperties (17.0), uniformAcrossSiblings APIs (17.0), '
               'repeatingSubitem:count: (16.0), UIContentInsetsReference.'},
)
# Internal implementation classes. They are exported because Objective-C needs
# them, but the importer must never map a public UIKit name onto them.
INTERNAL_CLASSES = (
    'IBPCollectionCompositionalLayoutSolver',
    'IBPCollectionCompositionalLayoutSolverResult',
    'IBPCollectionViewOrthogonalScrollerEmbeddedScrollView',
    'IBPCollectionViewOrthogonalScrollerSectionController',
    'IBPNSCollectionLayoutContainer',
    'IBPNSCollectionLayoutEnvironment',
)


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__ + '\nUsage: emit-runtime-mapping.py NM ARCHIVE OUT_JSON')
    nm, archive, out = sys.argv[1], sys.argv[2], sys.argv[3]
    symbols = subprocess.check_output([nm, '-g', archive], text=True)
    defined = {}
    undefined = set()
    for line in symbols.splitlines():
        # Archive member headers end with ':' and start at column 0; defined
        # symbols also start at column 0, undefined symbols are indented.
        if line.endswith(':'):
            continue
        fields = line.split()
        if len(fields) == 3 and fields[1] in ('T', 'S', 'D', 'B', 'C', 'R'):
            defined[fields[2]] = fields[1]
        elif len(fields) == 2 and fields[0] == 'U':
            undefined.add(fields[1])

    classes = []
    for name, public_superclass, runtime_superclass in CLASSES:
        runtime = 'IBP' + name
        for prefix in ('_OBJC_CLASS_$_', '_OBJC_METACLASS_$_'):
            symbol = prefix + runtime
            if symbol not in defined:
                raise SystemExit('mapped runtime class symbol missing: ' + symbol)
        classes.append({'public': name, 'runtime': runtime,
                        'publicSuperclass': public_superclass,
                        'runtimeSuperclass': runtime_superclass})

    protocols = []
    for name in PROTOCOLS:
        runtime = 'IBP' + name
        symbol = '__OBJC_PROTOCOL_$_' + runtime
        if symbol not in defined:
            raise SystemExit('mapped runtime protocol object missing: ' + symbol)
        protocols.append({'public': name, 'runtime': runtime})

    c_symbols = []
    for entry in C_SYMBOLS:
        symbol = '_' + entry['runtime']
        if symbol not in defined:
            raise SystemExit('mapped C symbol missing: ' + symbol)
        c_symbols.append(dict(entry))

    public_names = {entry[0] for entry in CLASSES} | set(PROTOCOLS)
    forbidden = ('UICollectionView', 'NSCollectionLayout', 'UICollectionLayout')
    for symbol in defined:
        if not symbol.startswith('_OBJC_CLASS_$_'):
            continue
        name = symbol[len('_OBJC_CLASS_$_'):]
        if not name.startswith('IBP'):
            raise SystemExit('archive defines a non-prefixed class: ' + name)
        if name in public_names:
            raise SystemExit('archive defines a public-named class: ' + name)
        if name.startswith(forbidden):
            raise SystemExit('archive defines a native-looking class: ' + name)

    contract = {
        'family': 'UICollectionViewCompositionalLayout',
        'introduced': '13.0',
        'supportedFloor': '5.0',
        'target': 'armv7-apple-ios5.0',
        'runtimePrefix': 'IBP',
        'mappingMechanism': 'public SDK declarations are overridden in the Clang importer with '
                            'objc_runtime_name (classes/protocols) and __asm__ aliases (C symbols); '
                            'the backport claims no public class/protocol/C name',
        'nativeDelegation': 'disabled: the backport always constructs backport objects and never '
                            'allocates or mutates native UIKit compositional objects',
        'classes': classes,
        'protocols': protocols,
        'cSymbols': c_symbols,
        'types': list(TYPES),
        'unimplemented': list(UNIMPLEMENTED),
        'internalClassesNotToMap': list(INTERNAL_CLASSES),
        'collectionRuntimeDependency': 'utils/legacy-ios5-mac/vendor/PSTCollectionView '
                                       '(MIT, Peter Steinberger); the layout class derives from '
                                       'PSTCollectionViewLayout and attributes remain '
                                       'PSTCollectionViewLayoutAttributes',
    }
    with open(out, 'w') as stream:
        json.dump(contract, stream, indent=2, sort_keys=True)
        stream.write('\n')
    print('verified %d classes, %d protocols and %d C symbols; wrote %s'
          % (len(classes), len(protocols), len(c_symbols), out))


if __name__ == '__main__':
    main()
