#import <UIKit/UIKit.h>
#include <mach/mach_time.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
static NSInteger COUNT=200;
static double now(void){ static mach_timebase_info_data_t tb; if(!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time()*tb.numer/tb.denom; }
@interface D : NSObject<UICollectionViewDataSource> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return COUNT; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; }
@end
static void run(NSInteger n, double out[3]){ COUNT=n; out[0]=out[1]=out[2]=0;
 @autoreleasepool{
 UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(320,58);l.minimumLineSpacing=0;
 UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,320,480) collectionViewLayout:l];
 [cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];static D*d; d=[D new];cv.dataSource=d;
 double t=now(); [cv layoutIfNeeded]; out[0]=(now()-t)/1000;
 for(int i=0;i<5;i++){ cv.contentOffset=CGPointMake(0,i*37); [cv layoutIfNeeded]; }
 t=now(); int steps=40; for(int i=0;i<steps;i++){ cv.contentOffset=CGPointMake(0,200+i*29); [cv layoutIfNeeded]; } out[1]=(now()-t)/1000/steps;
 for(int i=0;i<3;i++){ [cv reloadData]; [cv layoutIfNeeded]; }
 t=now(); int rl=10; for(int i=0;i<rl;i++){ [cv reloadData]; [cv layoutIfNeeded]; } out[2]=(now()-t)/1000/rl; } }
int main(){@autoreleasepool{[UIApplication sharedApplication];
 NSInteger counts[]={200,1000,5000,20000}; for(int k=0;k<4;k++){ double o[3]; run(counts[k],o); printf("items=%-6ld cold=%.0f us  scroll step=%.0f us  reload=%.0f us\n",(long)counts[k],o[0],o[1],o[2]); }
}return 0;}
