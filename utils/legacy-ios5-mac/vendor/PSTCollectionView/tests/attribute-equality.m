#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#endif
static UICollectionViewLayoutAttributes *base(void) {
    UICollectionViewLayoutAttributes *a=[UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:[NSIndexPath indexPathForItem:2 inSection:1]];
    a.frame=CGRectMake(10,20,80,30); return a;
}
static void expect(NSString *name, void (^change)(UICollectionViewLayoutAttributes *), BOOL equal) {
    UICollectionViewLayoutAttributes *a=base(), *b=[a copy]; change(b);
    BOOL actual=[a isEqual:b], reverse=[b isEqual:a];
    printf("%s equal=%d symmetric=%d\n",name.UTF8String,actual,actual==reverse);
    if (actual!=equal || reverse!=equal || (equal && a.hash!=b.hash)) exit(1);
}
int main(void) { @autoreleasepool {
    UICollectionViewLayoutAttributes *empty=[UICollectionViewLayoutAttributes new];
    UICollectionViewLayoutAttributes *emptyCopy=[empty copy];
    printf("default self=%d copy=%d\n",[empty isEqual:empty],[empty isEqual:emptyCopy]);
    if (![empty isEqual:empty] || [empty isEqual:emptyCopy] || [emptyCopy isEqual:empty]) return 1;
    expect(@"indexPath",^(UICollectionViewLayoutAttributes*a){a.indexPath=[NSIndexPath indexPathForItem:3 inSection:1];},NO);
    expect(@"copy",^(id a){},YES);
    expect(@"frame",^(UICollectionViewLayoutAttributes*a){a.frame=CGRectMake(11,20,80,30);},NO);
    expect(@"size",^(UICollectionViewLayoutAttributes*a){a.size=CGSizeMake(81,30);},NO);
    expect(@"center",^(UICollectionViewLayoutAttributes*a){a.center=CGPointMake(0,0);},NO);
    expect(@"alpha",^(UICollectionViewLayoutAttributes*a){a.alpha=0.5;},NO);
    expect(@"hidden",^(UICollectionViewLayoutAttributes*a){a.hidden=YES;},NO);
    expect(@"zIndex",^(UICollectionViewLayoutAttributes*a){a.zIndex=1;},NO);
    expect(@"transform",^(UICollectionViewLayoutAttributes*a){a.transform3D=CATransform3DMakeScale(2,1,1);},NO);
} return 0; }
