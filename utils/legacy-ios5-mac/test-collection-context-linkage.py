#!/usr/bin/env python3
"""Verify generated context declarations reference legacy classes, not absent iOS 5 UIKit classes.
Usage: test-collection-context-linkage.py SDK CLANG
"""
import pathlib, subprocess, sys, tempfile
import importlib.util
here=pathlib.Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('headers',here/'generate-collection-headers.py')
headers=importlib.util.module_from_spec(spec);spec.loader.exec_module(headers)
sdk,clang=sys.argv[1:]
with tempfile.TemporaryDirectory(prefix='collection-context-linkage-') as temporary:
    out=pathlib.Path(temporary);headers.generate(here/'vendor/PSTCollectionView',out)
    source=out/'probe.m'
    source.write_text('#import "UIKitLegacyCollection.h"\n'
        'id context(void) { return [UICollectionViewLayoutInvalidationContext new]; }\n'
        'id flowContext(void) { return [UICollectionViewFlowLayoutInvalidationContext new]; }\n')
    obj=out/'probe.o'
    subprocess.run([clang,'-target','armv7-apple-ios5.0','-marm','-isysroot',sdk,
        '-fobjc-arc','-fblocks','-fno-modules','-Wno-nullability-completeness',
        '-c',str(source),'-o',str(obj)],check=True)
    symbols=subprocess.check_output(['nm','-u',str(obj)],text=True)
    for name in ('CollectionViewLayoutInvalidationContext','CollectionViewFlowLayoutInvalidationContext'):
        assert '_OBJC_CLASS_$_PST'+name in symbols,symbols
        assert '_OBJC_CLASS_$_UI'+name not in symbols,symbols
print('PASS: generated UIKit context declarations reference both PST runtime classes on armv7 iOS 5')
