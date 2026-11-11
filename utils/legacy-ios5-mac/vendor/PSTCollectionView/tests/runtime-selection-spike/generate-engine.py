#!/usr/bin/env python3
"""Generate an isolated PST build with UIKit runtime names; never edit vendor originals."""
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
if out.exists():
    raise SystemExit('Output must not exist')
out.mkdir()
public_classes = [
    'PSTCollectionView', 'PSTCollectionReusableView', 'PSTCollectionViewCell',
    'PSTCollectionViewLayout', 'PSTCollectionViewFlowLayout', 'PSTCollectionViewLayoutAttributes',
    'PSTCollectionViewController', 'PSTCollectionViewUpdateItem',
]
# These also exist in the packaged Swift UIKit overlay. Keep both runtime identities
# and compiler-emitted class symbols private to this experimental implementation.
private_classes = [
    'PSTCollectionViewExt', 'PSTCollectionViewData', 'PSTCollectionViewItemKey',
    'PSTGridLayoutInfo', 'PSTGridLayoutItem', 'PSTGridLayoutRow', 'PSTGridLayoutSection',
    'PSUICollectionView_', 'PSUICollectionViewCell_', 'PSUICollectionReusableView_',
    'PSUICollectionViewLayout_', 'PSUICollectionViewFlowLayout_',
    'PSUICollectionViewLayoutAttributes_', 'PSUICollectionViewController_',
]
protocols = [
    'PSTCollectionViewDataSource', 'PSTCollectionViewDelegate',
    'PSTCollectionViewDelegateFlowLayout', 'PSTCollectionViewDataSourcePrefetching',
]
class_names = {name: name.replace('PST', 'UI', 1) for name in public_classes}
class_names.update({name: 'RouteEngine' + name for name in private_classes})
seen = {name: 0 for name in list(class_names) + protocols}
constants = [
    'PSTCollectionElementKindSectionHeader', 'PSTCollectionElementKindSectionFooter',
    'PSTCollectionViewFlowLayoutAutomaticSize',
]
for file in sorted(src.iterdir()):
    if not file.is_file() or file.suffix not in {'.m', '.h'}:
        continue
    text = file.read_text()
    # The private Ext class is declared in an implementation, not a header.
    for name, runtime in class_names.items():
        pattern = r'@interface\s+' + re.escape(name) + r'(?=\s*:)'
        text, count = re.subn(pattern,
            '__attribute__((objc_runtime_name("' + runtime + '")))\n@interface ' + name, text)
        seen[name] += count
    if file.suffix == '.h':
        for name in protocols:
            pattern = r'@protocol\s+' + re.escape(name) + r'(?=\s*<)'
            runtime = name.replace('PST', 'UI', 1)
            text, count = re.subn(pattern,
                '__attribute__((objc_runtime_name("' + runtime + '")))\n@protocol ' + name, text)
            seen[name] += count
    # Export native global spellings too; matching SDK declarations are harmless.
    for name in constants:
        text = re.sub(r'\b' + name + r'\b', name.replace('PST', 'UI', 1), text)
    (out / file.name).write_text(text)
if any(count != 1 for count in seen.values()):
    raise SystemExit('Unexpected class/protocol declaration counts: ' + repr(seen))
print('Generated isolated runtime-name PST declarations:', seen)
