#!/usr/bin/env python3
"""Specialise the persistent full-engine UI fixture for real Swift cell instances."""
import pathlib,sys
source=pathlib.Path(sys.argv[1]);out=pathlib.Path(sys.argv[2]);text=source.read_text()
a=text.index('@interface EngineAppCell:');b=text.index('@interface EngineAppFlow:')
text=text[:a]+'''extern Class routeSwiftCellClass(void);
extern void routeSwiftConfigureCell(id object, int32_t row);
extern int32_t routeSwiftValidateCell(id object, int32_t row);
extern int32_t routeSwiftMadeCount(void), routeSwiftReuseCount(void), routeSwiftLayoutCount(void);
#define EngineAppCell UICollectionViewCell
'''+text[b:]
def replace(old,new):
 global text
 if text.count(old)!=1:raise SystemExit('Fixture changed; expected exactly one '+old)
 text=text.replace(old,new,1)
replace(' c.title.text=[NSString stringWithFormat:@"Row %ld",(long)p.row];return c;',
        ' routeSwiftConfigureCell(c,(int32_t)p.row);return c;')
replace('  good=good&&[c isKindOfClass:[EngineAppCell class]]&&[c isKindOfClass:[UICollectionReusableView class]]&&c.canary==0x1234abcd&&c.title.superview==c.contentView;\n  good=good&&[c.title.text isEqual:[NSString stringWithFormat:@"Row %ld",(long)p.row]]&&fabs(c.bounds.size.height-50)<0.01;',
        '  int32_t code=routeSwiftValidateCell(c,(int32_t)p.row);\n  if(code)logLine([NSString stringWithFormat:@"Swift validation code=%d",code]);\n  good=good&&code==0&&[c isKindOfClass:[UICollectionReusableView class]]&&fabs(c.bounds.size.height-50)<0.01;')
# This debug line intentionally references the original ObjC subclass's title property.
lines=text.splitlines(True)
lines=[line for line in lines if not ('for(EngineAppCell*c' in line and 'labelBackground=' in line)]
text=''.join(lines)
replace(' check(good,@"cell subclass ivars, casts, content and frames intact");',
        ' check(good,@"Swift cell state, casts, protocols, labels and frames intact");')
replace(' [self.collection registerClass:[EngineAppCell class]',' [self.collection registerClass:routeSwiftCellClass()')
replace(' check(reused>0,@"prepareForReuse subclass override ran");',
        ' made=(NSUInteger)routeSwiftMadeCount();reused=(NSUInteger)routeSwiftReuseCount();\n check(reused>0,@"Swift prepareForReuse override ran");\n check(routeSwiftLayoutCount()>0,@"Swift layoutSubviews override ran");')
# The Swift UIKit overlay already installs the collection hooks. Do not compile/install a second copy.
replace('void UICInstallCollectionViewDisplay(void);','// Hook installer comes from the Swift UIKit overlay.')
replace(' if(!fallback)UICInstallCollectionViewDisplay();',' // Do not reinstall the hooks from another image.')
replace(' [self.collection layoutIfNeeded];[self verifyCells];',' [self.collection layoutIfNeeded];[self verifyCells];\n check(willDisplay==self.collection.visibleCells.count,@"initial willDisplay count is exact");')
replace(' for(NSNumber*y in @[@500,@1000,@1500,@0]){self.collection.contentOffset=CGPointMake(0,y.doubleValue);[self.collection layoutIfNeeded];[self verifyCells];}',
''' for(NSNumber*y in @[@500,@1000,@1500,@0]){
  NSSet *before=[NSSet setWithArray:self.collection.indexPathsForVisibleItems];NSUInteger countBefore=willDisplay;
  self.collection.contentOffset=CGPointMake(0,y.doubleValue);[self.collection layoutIfNeeded];[self verifyCells];
  NSMutableSet *arrivals=[NSMutableSet setWithArray:self.collection.indexPathsForVisibleItems];[arrivals minusSet:before];
  check(willDisplay-countBefore==arrivals.count,@"willDisplay once per arriving index path");
 }''')
text=text.replace('/var/mobile/Documents/full-engine-route.txt','/var/mobile/Documents/swift-engine-route.txt')
text=text.replace('Engine checks passed','Swift engine checks passed')
out.write_text(text)
