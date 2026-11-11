#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
static int CREATED;
@interface RC : UICollectionViewCell @end
@implementation RC
- (id)initWithFrame:(CGRect)f { self=[super initWithFrame:f]; CREATED++; return self; }
@end
@interface D : NSObject<UICollectionViewDataSource> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 400; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; }
@end
static void run(CGFloat w, CGFloat h, CGFloat viewH){
  CREATED=0;
  UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(w,h);l.minimumLineSpacing=0;l.minimumInteritemSpacing=0;
  UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,viewH) collectionViewLayout:l];
  [cv registerClass:[RC class] forCellWithReuseIdentifier:@"c"];D*d=[D new];cv.dataSource=d;[cv layoutIfNeeded];
  for(int i=1;i<=60;i++){ cv.contentOffset=CGPointMake(0,i*h*0.9); [cv layoutIfNeeded]; }
  int attached=0,hidden=0; for(UIView*v in cv.subviews) if([v isKindOfClass:[UICollectionViewCell class]]){attached++; if(v.hidden)hidden++;}
  printf("item %3gx%-4g view h=%-4g created=%-3d cell subviews=%-3d hidden=%-3d visible=%d\n",w,h,viewH,CREATED,attached,hidden,(int)cv.visibleCells.count);
}
int main(){@autoreleasepool{[UIApplication sharedApplication];
 run(200,50,100); run(200,50,400); run(200,200,400); run(200,400,400); run(200,800,400); run(100,50,400);
}return 0;}
