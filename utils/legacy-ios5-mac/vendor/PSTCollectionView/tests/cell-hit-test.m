#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
@interface D : NSObject<UICollectionViewDataSource> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 3; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; }
@end
int main(){@autoreleasepool{[UIApplication sharedApplication];
UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(200,50);l.minimumLineSpacing=0;
UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,200) collectionViewLayout:l];
[cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];D*d=[D new];cv.dataSource=d;[cv layoutIfNeeded];
UICollectionViewCell*c=(UICollectionViewCell*)[cv cellForItemAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
printf("cell.userInteractionEnabled=%d contentView.userInteractionEnabled=%d backgroundView=%s selectedBackgroundView=%s\n",c.userInteractionEnabled,c.contentView.userInteractionEnabled,c.backgroundView?"set":"nil",c.selectedBackgroundView?"set":"nil");
printf("subviews: %s\n",[[[c.subviews valueForKey:@"class"] description] UTF8String]);
UIView*h=[c hitTest:CGPointMake(10,10) withEvent:nil]; printf("cell hitTest -> %s (isCell=%d isContentView=%d)\n",object_getClassName(h),h==c,h==c.contentView);
UIView*h2=[cv hitTest:CGPointMake(10,10) withEvent:nil]; printf("collection hitTest -> %s (isCell=%d isContentView=%d)\n",object_getClassName(h2),h2==c,h2==c.contentView);
cv.contentOffset=CGPointMake(0,60);[cv layoutIfNeeded]; cv.contentOffset=CGPointMake(0,120);[cv layoutIfNeeded];
UICollectionViewCell*r=nil; for(UICollectionViewCell*x in cv.visibleCells) if(!r||x.frame.origin.y<r.frame.origin.y) r=x;
CGPoint pt=CGPointMake(10,cv.bounds.origin.y+ (r.frame.origin.y>cv.bounds.origin.y?r.frame.origin.y-cv.bounds.origin.y:0)+10); pt.y=r.frame.origin.y>=cv.bounds.origin.y? r.frame.origin.y+10 : cv.bounds.origin.y+10; UIView*root=cv;
UIView*hs=[cv hitTest:pt withEvent:nil]; UIView*hs2=[cv hitTest:CGPointMake(10,cv.bounds.origin.y+10) withEvent:nil]; printf("hit at bounds-top+10 -> %s tag=%ld frame=%s\n",hs2?object_getClassName(hs2):"nil",(long)hs2.tag,hs2?[NSStringFromCGRect(hs2.frame) UTF8String]:"-"); printf("after scrolling: top visible cell frame y=%g hidden=%d; hitTest -> %s isCell=%d isContentView=%d userInteraction cell=%d content=%d\n",r.frame.origin.y,r.hidden,object_getClassName(hs),hs==r,hs==r.contentView,r.userInteractionEnabled,r.contentView.userInteractionEnabled);
UILabel*lab=[[UILabel alloc] initWithFrame:CGRectMake(0,0,50,20)]; [c.contentView addSubview:lab];
UIView*h3=[cv hitTest:CGPointMake(10,10) withEvent:nil]; printf("with a label in contentView -> %s (isLabel=%d)\n",object_getClassName(h3),h3==lab);
}return 0;}
