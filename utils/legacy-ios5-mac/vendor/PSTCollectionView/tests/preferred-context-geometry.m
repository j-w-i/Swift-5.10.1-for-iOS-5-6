#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#define UICollectionViewFlowLayoutInvalidationContext PSTCollectionViewFlowLayoutInvalidationContext
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
@interface ContextSource : NSObject<UICollectionViewDataSource> @end
@implementation ContextSource
- (NSInteger)collectionView:(UICollectionView*)v numberOfItemsInSection:(NSInteger)s{return 20;}
- (UICollectionViewCell*)collectionView:(UICollectionView*)v cellForItemAtIndexPath:(NSIndexPath*)p{return [v dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];}
@end
int main(void){@autoreleasepool{
 [UIApplication sharedApplication];
 for(int change=0;change<2;change++){
 UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.estimatedItemSize=CGSizeMake(200,40);l.minimumLineSpacing=0;
 UICollectionView*v=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,120) collectionViewLayout:l];[v registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];
 ContextSource*d=[ContextSource new];v.dataSource=d;[v layoutIfNeeded];
 UICollectionViewFlowLayoutInvalidationContext*clean=[UICollectionViewFlowLayoutInvalidationContext new];clean.invalidateFlowLayoutAttributes=NO;clean.invalidateFlowLayoutDelegateMetrics=NO;[l invalidateLayoutWithContext:clean];[v layoutIfNeeded];
 NSIndexPath*p=[NSIndexPath indexPathForItem:0 inSection:0];
 UICollectionViewLayoutAttributes*original=[[l layoutAttributesForItemAtIndexPath:p] copy],*preferred=[original copy];
 if(change)preferred.size=CGSizeMake(200,60);
 UICollectionViewFlowLayoutInvalidationContext*c=(id)[l invalidationContextForPreferredLayoutAttributes:preferred withOriginalAttributes:original];
 NSMutableArray*paths=[NSMutableArray array];for(NSIndexPath*x in c.invalidatedItemIndexPaths)[paths addObject:@(x.item)];
 printf("changed=%d attrs=%d metrics=%d delta=%.3f,%.3f offset=%.3f,%.3f paths=%s\n",change,c.invalidateFlowLayoutAttributes,c.invalidateFlowLayoutDelegateMetrics,c.contentSizeAdjustment.width,c.contentSizeAdjustment.height,c.contentOffsetAdjustment.x,c.contentOffsetAdjustment.y,[[[paths sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","] UTF8String]);
 for(int i=0;i<5;i++){
 CGRect f=[l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]].frame;
 printf("item=%d y=%.3f h=%.3f\n",i,f.origin.y,f.size.height);
 }
 printf("layoutHeight=%.3f viewHeight=%.3f\n",l.collectionViewContentSize.height,v.contentSize.height);
 [l invalidateLayoutWithContext:c];[v layoutIfNeeded];
 printf("after layoutHeight=%.3f viewHeight=%.3f\n",l.collectionViewContentSize.height,v.contentSize.height);
 for(int i=0;i<3;i++){CGRect f=[l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]].frame;printf("after item=%d y=%.3f h=%.3f\n",i,f.origin.y,f.size.height);}
 }
}return 0;}
