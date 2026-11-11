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
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 40; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { UICollectionViewCell *c=[cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; c.tag=1000+p.row; return c; }
@end
int main(){@autoreleasepool{[UIApplication sharedApplication];
UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(200,50);l.minimumLineSpacing=0;
UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,100) collectionViewLayout:l];
[cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];D*d=[D new];cv.dataSource=d;[cv layoutIfNeeded];
cv.contentOffset=CGPointMake(0,500);[cv layoutIfNeeded];cv.contentOffset=CGPointMake(0,1000);[cv layoutIfNeeded];
NSMutableArray*vis=[NSMutableArray array];for(UICollectionViewCell*c in cv.visibleCells)[vis addObject:@(c.tag)];
UIView*hit=[cv hitTest:CGPointMake(100,1010) withEvent:nil]; UIView*hitOld=[cv hitTest:CGPointMake(100,510) withEvent:nil]; // lands on the hidden cell's old spot? (content coords -> view coords)
NSIndexPath*ip=[cv indexPathForItemAtPoint:CGPointMake(100,1025)];
NSArray*paths=[cv indexPathsForVisibleItems];
for(UICollectionViewCell*c in cv.visibleCells) printf("visible cell %ld frame=%s\n",(long)c.tag,[NSStringFromCGRect(c.frame) UTF8String]);
printf("bounds=%s offset=%g\n",[NSStringFromCGRect(cv.bounds) UTF8String],cv.contentOffset.y);
printf("visibleCells tags=%s\nindexPathsForVisibleItems=%lu\nindexPathForItemAtPoint(100,1025)=%ld\nhitTest inside visible cell tag=%ld\nhitTest at stale position (old frame of a hidden cell) tag=%ld\n",[[vis componentsJoinedByString:@","] UTF8String],(unsigned long)paths.count,(long)ip.row,(long)hit.tag,(long)hitOld.tag);
int hidden=0;for(UIView*v in cv.subviews)if([v isKindOfClass:[UICollectionViewCell class]]&&v.hidden)hidden++;
printf("hit class=%s superview class=%s\n",hit?object_getClassName(hit):"nil",hit.superview?object_getClassName(hit.superview):"nil");
printf("hidden cell subviews=%d\n",hidden);}return 0;}
