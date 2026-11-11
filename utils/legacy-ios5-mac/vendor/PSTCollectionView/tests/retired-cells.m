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
static void dump(UICollectionView *cv,const char *tag){
  int attached=0, hidden=0, visibleCells=(int)cv.visibleCells.count; NSMutableString *tags=[NSMutableString string];
  for(UIView *v in cv.subviews) if([v isKindOfClass:[UICollectionViewCell class]]){ attached++; if(v.hidden) hidden++; [tags appendFormat:@"%ld%s ",(long)v.tag,v.hidden?"h":""]; }
  printf("%-22s cell subviews=%d hidden=%d visibleCells=%d  tags: %s\n",tag,attached,hidden,visibleCells,tags.UTF8String);
}
int main(){@autoreleasepool{[UIApplication sharedApplication];
UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(200,50);l.minimumLineSpacing=0;
UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,100) collectionViewLayout:l];
[cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];D*d=[D new];cv.dataSource=d;[cv layoutIfNeeded];
dump(cv,"initial");
cv.contentOffset=CGPointMake(0,500);[cv layoutIfNeeded];dump(cv,"scrolled to 500");
cv.contentOffset=CGPointMake(0,1000);[cv layoutIfNeeded];dump(cv,"scrolled to 1000");
cv.contentOffset=CGPointZero;[cv layoutIfNeeded];dump(cv,"back to 0");
}return 0;}
