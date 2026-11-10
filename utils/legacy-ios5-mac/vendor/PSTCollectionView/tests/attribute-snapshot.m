#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "PSTCollectionView.h"
static void require(BOOL ok, const char *message) { if (!ok) { fprintf(stderr,"FAIL: %s\n",message); exit(1); } }
int main(void) { @autoreleasepool {
    UICollectionReusableView *native=[[UICollectionReusableView alloc]initWithFrame:CGRectZero];
    UICollectionViewLayoutAttributes *a=[UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
    a.frame=CGRectMake(10,20,80,30);
    SEL set=NSSelectorFromString(@"_setLayoutAttributes:");
    SEL get=NSSelectorFromString(@"_layoutAttributes");
    require([native respondsToSelector:set] && [native respondsToSelector:get],"native private snapshot probe unavailable");
    ((void(*)(id,SEL,id))objc_msgSend)(native,set,a);
    id snapshot=((id(*)(id,SEL))objc_msgSend)(native,get);
    require(snapshot!=a,"native stores distinct attributes");
    a.frame=CGRectMake(100,200,90,40);
    require(CGRectEqualToRect([snapshot frame],CGRectMake(10,20,80,30)),"native snapshot survives input mutation");
    PSTCollectionReusableView *pst=[[PSTCollectionReusableView alloc]initWithFrame:CGRectZero];
    PSTCollectionViewLayoutAttributes *p=[PSTCollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
    p.frame=CGRectMake(10,20,80,30); [pst applyLayoutAttributes:p];
    require(pst.layoutAttributes!=p,"PST stores distinct attributes");
    p.frame=CGRectMake(100,200,90,40);
    require(CGRectEqualToRect(pst.layoutAttributes.frame,CGRectMake(10,20,80,30)),"PST snapshot survives input mutation");
    [pst applyLayoutAttributes:p];
    require(CGRectEqualToRect(pst.frame,p.frame),"PST reapplies mutated source attributes");
    puts("PASS: native/PST store independent attribute snapshots; mutated source reapplies");
} return 0; }
