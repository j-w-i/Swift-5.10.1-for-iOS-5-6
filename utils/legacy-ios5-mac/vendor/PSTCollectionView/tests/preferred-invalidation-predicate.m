#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionViewLayout PSTCollectionViewLayout
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#define UICollectionViewLayoutInvalidationContext PSTCollectionViewLayoutInvalidationContext
#define UICollectionViewFlowLayoutInvalidationContext PSTCollectionViewFlowLayoutInvalidationContext
#endif
@interface CustomContext : UICollectionViewLayoutInvalidationContext @end
@implementation CustomContext @end
@interface CustomLayout : UICollectionViewLayout @end
@implementation CustomLayout
+ (Class)invalidationContextClass { return [CustomContext class]; }
@end
int main(void) { @autoreleasepool {
 [UIApplication sharedApplication];
 UICollectionViewLayoutAttributes *a=[UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
 CustomLayout *custom=[CustomLayout new];
 id context1=[custom invalidationContextForPreferredLayoutAttributes:a withOriginalAttributes:a];
 id context2=[custom invalidationContextForPreferredLayoutAttributes:a withOriginalAttributes:a];
 printf("customContext=%d fresh=%d itemsNil=%d baseClass=%d flowClass=%d\n",[context1 isKindOfClass:[CustomContext class]],context1!=context2,[context1 invalidatedItemIndexPaths]==nil,[UICollectionViewLayout invalidationContextClass]==[UICollectionViewLayoutInvalidationContext class],[UICollectionViewFlowLayout invalidationContextClass]==[UICollectionViewFlowLayoutInvalidationContext class]);
 UICollectionViewLayout *base=[UICollectionViewLayout new];
 UICollectionViewFlowLayout *flow=[UICollectionViewFlowLayout new];
 UICollectionViewFlowLayoutInvalidationContext *same=(id)[flow invalidationContextForPreferredLayoutAttributes:a withOriginalAttributes:a];
 printf("unchangedFlow attrs=%d metrics=%d paths=%lu\n",same.invalidateFlowLayoutAttributes,same.invalidateFlowLayoutDelegateMetrics,(unsigned long)same.invalidatedItemIndexPaths.count);
 NSArray *layouts=@[base,flow,flow];
 for(NSUInteger mode=0;mode<3;mode++) {
  if(mode==2)flow.estimatedItemSize=CGSizeMake(50,40);
  UICollectionViewLayout *layout=layouts[mode];
  for(NSUInteger change=0;change<5;change++) {
   UICollectionViewLayoutAttributes *original=[UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
   original.frame=CGRectMake(0,0,50,40);
   UICollectionViewLayoutAttributes *preferred=[original copy];
   if(change==1)preferred.size=CGSizeMake(50,60);
   if(change==2)preferred.size=CGSizeMake(70,40);
   if(change==3)preferred.frame=CGRectMake(0,20,50,40);
   if(change==4)preferred.alpha=0.5;
   BOOL invalidates=[layout shouldInvalidateLayoutForPreferredLayoutAttributes:preferred withOriginalAttributes:original];
   printf("mode=%lu change=%lu invalidates=%d\n",(unsigned long)mode,(unsigned long)change,invalidates);
  }
 }
}return 0;}
