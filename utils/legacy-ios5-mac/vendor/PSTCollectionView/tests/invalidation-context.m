#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionViewLayout.h"
#define UICollectionViewLayoutInvalidationContext PSTCollectionViewLayoutInvalidationContext
#define UICollectionViewFlowLayoutInvalidationContext PSTCollectionViewFlowLayoutInvalidationContext
#endif
static void dump(UICollectionViewLayoutInvalidationContext *c) {
 printf("all=%d counts=%d itemsNil=%d suppNil=%d decoNil=%d offset=%.0f,%.0f size=%.0f,%.0f\n",c.invalidateEverything,c.invalidateDataSourceCounts,c.invalidatedItemIndexPaths==nil,c.invalidatedSupplementaryIndexPaths==nil,c.invalidatedDecorationIndexPaths==nil,c.contentOffsetAdjustment.x,c.contentOffsetAdjustment.y,c.contentSizeAdjustment.width,c.contentSizeAdjustment.height);
}
static NSString *paths(NSArray *p) { NSMutableArray *a=[NSMutableArray array]; for(NSIndexPath *x in p)[a addObject:[NSString stringWithFormat:@"%ld:%ld",(long)x.section,(long)x.item]]; return [[a sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]; }
int main(void){@autoreleasepool{
 UICollectionViewLayoutInvalidationContext*c=[UICollectionViewLayoutInvalidationContext new];dump(c);
 NSIndexPath*a=[NSIndexPath indexPathForItem:1 inSection:0],*b=[NSIndexPath indexPathForItem:2 inSection:0];
 [c invalidateItemsAtIndexPaths:@[a,b,a]];[c invalidateItemsAtIndexPaths:@[b]];
 [c invalidateSupplementaryElementsOfKind:@"header" atIndexPaths:@[a,a]];
 [c invalidateSupplementaryElementsOfKind:@"header" atIndexPaths:@[b]];
 [c invalidateDecorationElementsOfKind:@"back" atIndexPaths:@[b,b]];
 printf("items=%s supp=%s deco=%s\n",paths(c.invalidatedItemIndexPaths).UTF8String,paths(c.invalidatedSupplementaryIndexPaths[@"header"]).UTF8String,paths(c.invalidatedDecorationIndexPaths[@"back"]).UTF8String);
 c.contentOffsetAdjustment=CGPointMake(3,4);c.contentSizeAdjustment=CGSizeMake(5,6);dump(c);
 UICollectionViewFlowLayoutInvalidationContext*f=[UICollectionViewFlowLayoutInvalidationContext new];
 printf("flow attrs=%d metrics=%d\n",f.invalidateFlowLayoutAttributes,f.invalidateFlowLayoutDelegateMetrics);
 f.invalidateFlowLayoutAttributes=NO;f.invalidateFlowLayoutDelegateMetrics=NO;
 printf("flow attrs=%d metrics=%d\n",f.invalidateFlowLayoutAttributes,f.invalidateFlowLayoutDelegateMetrics);
}return 0;}
