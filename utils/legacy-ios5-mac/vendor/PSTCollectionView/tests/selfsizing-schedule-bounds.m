// Prototype-only safety test. No native-parity claim: the cell deliberately never converges.
#import <UIKit/UIKit.h>
#import "PSTCollectionView.h"
static NSUInteger calls;static BOOL emergency;
@interface UnstableCell:PSTCollectionViewCell @end
@implementation UnstableCell
- (PSTCollectionViewLayoutAttributes*)preferredLayoutAttributesFittingAttributes:(PSTCollectionViewLayoutAttributes*)a{
 calls++;PSTCollectionViewLayoutAttributes*r=[a copy];
 if(calls>500){emergency=YES;return r;} // fail closed instead of hanging if the prototype bound breaks
 r.size=CGSizeMake(a.size.width,a.size.height+1);return r;
}
@end
@interface UnstableSource:NSObject<PSTCollectionViewDataSource> @end
@implementation UnstableSource
- (NSInteger)collectionView:(PSTCollectionView*)cv numberOfItemsInSection:(NSInteger)section{return 3;}
- (PSTCollectionViewCell*)collectionView:(PSTCollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)p{return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];}
@end
int main(void){@autoreleasepool{
 [UIApplication sharedApplication];PSTCollectionViewFlowLayout*l=[PSTCollectionViewFlowLayout new];l.estimatedItemSize=CGSizeMake(200,40);l.minimumLineSpacing=0;
 PSTCollectionView*cv=[[PSTCollectionView alloc]initWithFrame:CGRectMake(0,0,200,120) collectionViewLayout:l];
 if(![cv respondsToSelector:NSSelectorFromString(@"pstPrototypeScheduleBudgetHit")])return 64;
 [cv registerClass:[UnstableCell class] forCellWithReuseIdentifier:@"c"];UnstableSource*s=[UnstableSource new];cv.dataSource=s;
 [cv reloadData];[cv layoutIfNeeded];
 BOOL hit=[[cv valueForKey:@"pstPrototypeScheduleBudgetHit"] boolValue];
 BOOL ok=hit&&!emergency&&calls<=100;
 printf("%s prototype nonconverging cell bound: calls=%lu hit=%d emergency=%d\n",ok?"PASS":"FAIL",(unsigned long)calls,hit,emergency);return ok?0:1;
}}
