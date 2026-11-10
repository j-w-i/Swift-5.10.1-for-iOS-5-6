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
    NSIndexPath *path=[NSIndexPath indexPathForItem:3 inSection:2];
    UICollectionViewLayoutAttributes *na=[UICollectionViewLayoutAttributes layoutAttributesForSupplementaryViewOfKind:@"header-test" withIndexPath:path];
    PSTCollectionViewLayoutAttributes *pa=[PSTCollectionViewLayoutAttributes layoutAttributesForSupplementaryViewOfKind:@"header-test" withIndexPath:path];
    CGRect geometry=CGRectMake(7,11,91,43);
    CATransform3D transform=CATransform3DMakeScale(1.2,0.8,1);
    na.frame=geometry; pa.frame=geometry; na.transform3D=transform; pa.transform3D=transform;
    na.alpha=0.4; pa.alpha=0.4; na.zIndex=9; pa.zIndex=9; na.hidden=YES; pa.hidden=YES;
    native.bounds=CGRectMake(4,6,1,1); pst.bounds=CGRectMake(4,6,1,1);
    ((void(*)(id,SEL,id))objc_msgSend)(native,set,na);
    [pst applyLayoutAttributes:pa];
    UICollectionViewLayoutAttributes *ns=((id(*)(id,SEL))objc_msgSend)(native,get);
    PSTCollectionViewLayoutAttributes *ps=pst.layoutAttributes;
    require([ps.indexPath isEqual:ns.indexPath] && [ps.representedElementKind isEqual:ns.representedElementKind],"copy preserves supplementary identity");
    require((NSInteger)ps.representedElementCategory==(NSInteger)ns.representedElementCategory,"copy preserves category");
    require(CGRectEqualToRect(ps.frame,pa.frame) && CGSizeEqualToSize(ps.size,ns.size) && CGPointEqualToPoint(ps.center,ns.center),"copy preserves stored geometry");
    require(!CGRectEqualToRect(ps.frame,ns.frame),"known transformed frame getter discrepancy changed; revisit oracle");
    puts("KNOWN GAP: PST frame getter is untransformed; native attributes frame includes transform");
    require(CATransform3DEqualToTransform(ps.transform3D,ns.transform3D) && ps.alpha==ns.alpha && ps.zIndex==ns.zIndex && ps.hidden==ns.hidden,"copy preserves presentation properties");
    require(CGSizeEqualToSize(pst.bounds.size,native.bounds.size) && CGPointEqualToPoint(pst.center,native.center),"application applies size and center");
    require(CGPointEqualToPoint(pst.bounds.origin,CGPointMake(4,6)) && CGPointEqualToPoint(native.bounds.origin,CGPointZero),"known bounds-origin difference changed; revisit oracle");
    puts("KNOWN GAP: iOS 27 resets bounds origin; PST preserves it (consistent with existing iOS 6 reference notes)");
    require(CATransform3DEqualToTransform(ps.transform3D,transform),"snapshot retains original transform");
    printf("OBSERVATION: applied hidden native=%d PST=%d transformEqual=%d opacity native=%g PST=%g\n",native.hidden,pst.hidden,CATransform3DEqualToTransform(pst.layer.transform,native.layer.transform),native.layer.opacity,pst.layer.opacity);
    puts("PASS: supplementary snapshot preserves identity, stored geometry and presentation properties (application parity NOT established)");
} return 0; }
