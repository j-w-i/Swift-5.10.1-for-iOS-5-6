#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewLayout PSTCollectionViewLayout
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegate PSTCollectionViewDelegate
#endif
static BOOL HIDE_EVEN; static NSMutableArray *EV;
@interface HL : UICollectionViewLayout @end
@implementation HL
- (CGSize)collectionViewContentSize { return CGSizeMake(200,2000); }
- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)p { UICollectionViewLayoutAttributes *a=[UICollectionViewLayoutAttributes layoutAttributesForCellWithIndexPath:p]; a.frame=CGRectMake(0,p.row*50,200,50); a.hidden=HIDE_EVEN&&(p.row%2==0); return a; }
- (NSArray *)layoutAttributesForElementsInRect:(CGRect)r { NSMutableArray *o=[NSMutableArray array]; for(int i=0;i<40;i++){ CGRect f=CGRectMake(0,i*50,200,50); if(CGRectIntersectsRect(f,r)) [o addObject:[self layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForRow:i inSection:0]]]; } return o; }
- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)b { return NO; }
@end
@interface D : NSObject<UICollectionViewDataSource,UICollectionViewDelegate> @end
@implementation D
- (void)collectionView:(UICollectionView *)cv willDisplayCell:(UICollectionViewCell *)c forItemAtIndexPath:(NSIndexPath *)p { [EV addObject:[NSString stringWithFormat:@"will %ld",(long)p.row]]; }
- (void)collectionView:(UICollectionView *)cv didEndDisplayingCell:(UICollectionViewCell *)c forItemAtIndexPath:(NSIndexPath *)p { [EV addObject:[NSString stringWithFormat:@"end %ld hidden=%d",(long)p.row,c.hidden]]; }
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 40; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { UICollectionViewCell *c=[cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; c.tag=1000+p.row; return c; }
@end
static void dump(UICollectionView *cv,const char *tag){
  NSMutableString *m=[NSMutableString string];
  NSArray *cells=[[cv.visibleCells sortedArrayUsingComparator:^NSComparisonResult(UIView*a,UIView*b){ return a.tag<b.tag?NSOrderedAscending:NSOrderedDescending; }] copy];
  for(UICollectionViewCell*c in cells) [m appendFormat:@"%ld%s ",(long)c.tag-1000,c.hidden?"h":""];
  printf("%-28s visible: %s\n",tag,m.UTF8String);
}
int main(){@autoreleasepool{[UIApplication sharedApplication]; HIDE_EVEN=NO; EV=[NSMutableArray array];
UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,100) collectionViewLayout:[HL new]];
[cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];D*d=[D new];cv.dataSource=d;cv.delegate=d;[cv layoutIfNeeded];
dump(cv,"initial (nothing hidden)"); [EV addObject:@"-- layout now hides even items"]; HIDE_EVEN=YES; [cv.collectionViewLayout invalidateLayout]; [cv layoutIfNeeded]; dump(cv,"after hide"); [EV addObject:@"-- layout un-hides"]; HIDE_EVEN=NO; [cv.collectionViewLayout invalidateLayout]; [cv layoutIfNeeded]; dump(cv,"after un-hide");
for(NSString*e in EV)printf("%s\n",e.UTF8String); return 0;
cv.contentOffset=CGPointMake(0,500);[cv layoutIfNeeded];dump(cv,"scrolled to 500");
cv.contentOffset=CGPointMake(0,1000);[cv layoutIfNeeded];dump(cv,"scrolled to 1000");
cv.contentOffset=CGPointZero;[cv layoutIfNeeded];dump(cv,"back to 0");
HIDE_EVEN=NO;[cv.collectionViewLayout invalidateLayout];[cv layoutIfNeeded];dump(cv,"layout stops hiding");
}return 0;}
