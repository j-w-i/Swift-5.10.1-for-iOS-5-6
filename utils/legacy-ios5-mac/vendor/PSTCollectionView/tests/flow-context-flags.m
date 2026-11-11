#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewFlowLayoutInvalidationContext PSTCollectionViewFlowLayoutInvalidationContext
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegateFlowLayout PSTCollectionViewDelegateFlowLayout
#define UICollectionViewLayout PSTCollectionViewLayout
#endif
static CGFloat height;static NSUInteger sizeCalls;static NSMutableArray *queriedPaths;
@interface FlagSource : NSObject<UICollectionViewDataSource,UICollectionViewDelegateFlowLayout> @end
@implementation FlagSource
- (NSInteger)collectionView:(UICollectionView*)v numberOfItemsInSection:(NSInteger)s{return 8;}
- (UICollectionViewCell*)collectionView:(UICollectionView*)v cellForItemAtIndexPath:(NSIndexPath*)p{return [v dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];}
- (CGSize)collectionView:(UICollectionView*)v layout:(UICollectionViewLayout*)l sizeForItemAtIndexPath:(NSIndexPath*)p{sizeCalls++;[queriedPaths addObject:@(p.item)];return CGSizeMake(200,height);}
@end
int main(void){@autoreleasepool{
 [UIApplication sharedApplication];
#ifdef TEST_NAMED_ITEM_CONTEXT
 const int namedCases=2;
#else
 const int namedCases=1;
#endif
 for(int named=0;named<namedCases;named++)for(int attrs=0;attrs<2;attrs++)for(int metrics=0;metrics<2;metrics++){
 height=40;sizeCalls=0;UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.minimumLineSpacing=0;
 UICollectionView*v=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,120) collectionViewLayout:l];[v registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];
 FlagSource*d=[FlagSource new];v.dataSource=d;v.delegate=d;[v layoutIfNeeded];
 NSUInteger before=sizeCalls;height=60;queriedPaths=[NSMutableArray array];
 UICollectionViewFlowLayoutInvalidationContext*c=[UICollectionViewFlowLayoutInvalidationContext new];c.invalidateFlowLayoutAttributes=attrs;c.invalidateFlowLayoutDelegateMetrics=metrics;
 if(named)[c invalidateItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:0 inSection:0]]];
 [l invalidateLayoutWithContext:c];[v layoutIfNeeded];
 CGRect f=[l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]].frame;
 printf("named=%d attrs=%d metrics=%d queried=%d height=%.0f content=%.0f\n",named,attrs,metrics,sizeCalls>before,f.size.height,v.contentSize.height);
 if(named)printf("named queriedPaths=%s item1y=%.0f\n",[[queriedPaths componentsJoinedByString:@","] UTF8String],[l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:1 inSection:0]].frame.origin.y);
 }
 for(int order=0;order<2;order++){
 height=40;sizeCalls=0;UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.minimumLineSpacing=0;
 UICollectionView*v=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,120) collectionViewLayout:l];[v registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];
 FlagSource*d=[FlagSource new];v.dataSource=d;v.delegate=d;[v layoutIfNeeded];
 NSUInteger before=sizeCalls;height=60;queriedPaths=[NSMutableArray array];
 UICollectionViewFlowLayoutInvalidationContext*full=[UICollectionViewFlowLayoutInvalidationContext new];
 UICollectionViewFlowLayoutInvalidationContext*keep=[UICollectionViewFlowLayoutInvalidationContext new];keep.invalidateFlowLayoutAttributes=NO;keep.invalidateFlowLayoutDelegateMetrics=NO;
 [l invalidateLayoutWithContext:order?keep:full];[l invalidateLayoutWithContext:order?full:keep];[v layoutIfNeeded];
 printf("coalesced order=%d queried=%d height=%.0f\n",order,sizeCalls>before,[l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]].size.height);
 }
}return 0;}
