#!/usr/bin/env python3
"""Generate an isolated PST build with UIKit runtime names; never edit the vendor originals."""
import pathlib,re,sys
src=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2])
if out.exists():raise SystemExit('Output must not exist')
out.mkdir()
classes=['PSTCollectionView','PSTCollectionReusableView','PSTCollectionViewCell',
 'PSTCollectionViewLayout','PSTCollectionViewFlowLayout','PSTCollectionViewLayoutAttributes',
 'PSTCollectionViewController','PSTCollectionViewUpdateItem']
protocols=['PSTCollectionViewDataSource','PSTCollectionViewDelegate',
 'PSTCollectionViewDelegateFlowLayout','PSTCollectionViewDataSourcePrefetching']
seen={name:0 for name in classes+protocols}
constants=['PSTCollectionElementKindSectionHeader','PSTCollectionElementKindSectionFooter',
 'PSTCollectionViewFlowLayoutAutomaticSize']
for file in sorted(src.iterdir()):
 if not file.is_file() or file.suffix not in {'.m','.h'}:continue
 text=file.read_text()
 if file.suffix=='.h':
  for name in classes:
   pattern=r'@interface\s+'+re.escape(name)+r'(?=\s*:)'
   runtime=name.replace('PST','UI',1)
   text,n=re.subn(pattern,'__attribute__((objc_runtime_name("'+runtime+'")))\n@interface '+name,text)
   seen[name]+=n
  for name in protocols:
   pattern=r'@protocol\s+'+re.escape(name)+r'(?=\s*<)'
   runtime=name.replace('PST','UI',1)
   text,n=re.subn(pattern,'__attribute__((objc_runtime_name("'+runtime+'")))\n@protocol '+name,text)
   seen[name]+=n
 # Export native global spellings too; matching SDK declarations are harmless.
 for name in constants:text=re.sub(r'\b'+name+r'\b',name.replace('PST','UI',1),text)
 (out/file.name).write_text(text)
if any(n!=1 for n in seen.values()):raise SystemExit('Unexpected class/protocol declaration counts: '+repr(seen))
print('Generated isolated UIKit-runtime-name PST headers:',seen)
