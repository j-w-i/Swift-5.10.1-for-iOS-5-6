// Numeric affine frame expectations measured against native iOS 27 UIKit.
#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#endif
static void check(UICollectionViewLayoutAttributes *a, CGRect expected, const char *name) {
    CGRect f=a.frame;
    if (fabs(f.origin.x-expected.origin.x)>0.001 || fabs(f.origin.y-expected.origin.y)>0.001 ||
        fabs(f.size.width-expected.size.width)>0.001 || fabs(f.size.height-expected.size.height)>0.001) {
        fprintf(stderr,"FAIL: %s frame=%s\n",name,NSStringFromCGRect(f).UTF8String); exit(1);
    }
    UICollectionViewLayoutAttributes *copy=[a copy];
    CGRect c=copy.frame;
    if (!CGRectEqualToRect(c,f) || !CGSizeEqualToSize(copy.size,a.size) || !CGPointEqualToPoint(copy.center,a.center)) exit(1);
    printf("PASS: %s and independent copy\n",name);
}
int main(void) { @autoreleasepool {
    UICollectionViewLayoutAttributes *a=[UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:[NSIndexPath indexPathForItem:0 inSection:0]];
    a.frame=CGRectMake(10,20,80,30); check(a,CGRectMake(10,20,80,30),"identity");
    a.transform3D=CATransform3DMakeScale(2,3,1); check(a,CGRectMake(-30,-10,160,90),"scale");
    a.frame=CGRectMake(100,200,90,40); check(a,CGRectMake(55,160,180,120),"frame assignment while scaled");
    a.transform3D=CATransform3DIdentity; check(a,CGRectMake(100,200,90,40),"identity restored");
    a.frame=CGRectMake(10,20,80,30); a.transform3D=CATransform3DMakeRotation(M_PI/2,0,0,1);
    check(a,CGRectMake(35,-5,30,80),"rotation");
    a.transform3D=CATransform3DMakeTranslation(7,9,0); check(a,CGRectMake(17,29,80,30),"translation");
    a.center=CGPointMake(100,200); check(a,CGRectMake(67,194,80,30),"center assignment while translated");
} return 0; }
