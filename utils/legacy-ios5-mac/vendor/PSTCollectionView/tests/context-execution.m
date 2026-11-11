#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewLayout PSTCollectionViewLayout
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#define UICollectionViewLayoutInvalidationContext PSTCollectionViewLayoutInvalidationContext
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
static NSUInteger prepares,counts;
@interface ExecutionLayout : UICollectionViewLayout @end
@implementation ExecutionLayout
- (void)prepareLayout { [super prepareLayout]; prepares++; }
- (CGSize)collectionViewContentSize { return CGSizeMake(200,400); }
- (NSArray *)layoutAttributesForElementsInRect:(CGRect)r { return @[]; }
@end
@interface ExecutionSource : NSObject<UICollectionViewDataSource> @end
@implementation ExecutionSource
- (NSInteger)collectionView:(UICollectionView *)v numberOfItemsInSection:(NSInteger)s { counts++;return 1; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)v cellForItemAtIndexPath:(NSIndexPath *)p { return nil; }
@end
int main(void){@autoreleasepool{
 [UIApplication sharedApplication];
 ExecutionLayout*l=[ExecutionLayout new];UICollectionView*v=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,120) collectionViewLayout:l];
 ExecutionSource*d=[ExecutionSource new];v.dataSource=d;[v layoutIfNeeded];
 for(int mode=0;mode<2;mode++){
 NSUInteger p=prepares,c=counts;
 UICollectionViewLayoutInvalidationContext*x=[UICollectionViewLayoutInvalidationContext new];
 if(mode)[x invalidateItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:0 inSection:0]]];
 [l invalidateLayoutWithContext:x];[v layoutIfNeeded];
 printf("mode=%d prepared=%d recounted=%d\n",mode,prepares>p,counts>c);
 }
 v.contentOffset=CGPointMake(0,50);[v layoutIfNeeded];
 UICollectionViewLayoutInvalidationContext*adjustment=[UICollectionViewLayoutInvalidationContext new];
 adjustment.contentOffsetAdjustment=CGPointMake(0,7);adjustment.contentSizeAdjustment=CGSizeMake(0,20);
 [l invalidateLayoutWithContext:adjustment];
 printf("immediate offset=%.0f size=%.0f\n",v.contentOffset.y,v.contentSize.height);
 [v layoutIfNeeded];
 printf("settled offset=%.0f size=%.0f\n",v.contentOffset.y,v.contentSize.height);
 for(int sign=-1;sign<=1;sign+=2){
 UICollectionViewLayoutInvalidationContext*delta=[UICollectionViewLayoutInvalidationContext new];
 #ifdef TEST_CROSS_AXIS_ADJUSTMENT
 delta.contentOffsetAdjustment=CGPointMake(sign*3,sign*4);delta.contentSizeAdjustment=CGSizeMake(sign*10,sign*15);
#else
 delta.contentOffsetAdjustment=CGPointMake(0,sign*4);delta.contentSizeAdjustment=CGSizeMake(0,sign*15);
#endif
 [l invalidateLayoutWithContext:delta];[l invalidateLayoutWithContext:delta];
 printf("repeated sign=%d immediate=%.0f,%.0f %.0f,%.0f\n",sign,v.contentOffset.x,v.contentOffset.y,v.contentSize.width,v.contentSize.height);
 [v layoutIfNeeded];printf("repeated sign=%d settled=%.0f,%.0f %.0f,%.0f\n",sign,v.contentOffset.x,v.contentOffset.y,v.contentSize.width,v.contentSize.height);
 }
}return 0;}
