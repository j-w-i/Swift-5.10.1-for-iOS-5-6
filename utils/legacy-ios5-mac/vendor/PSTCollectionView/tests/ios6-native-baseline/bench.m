#import <UIKit/UIKit.h>
#include <mach/mach_time.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
static double now(void){ static mach_timebase_info_data_t tb; if(!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time()*tb.numer/tb.denom; }
static NSInteger CELLS;
@interface DD : NSObject<UICollectionViewDataSource> @end
@implementation DD
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 200; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { CELLS++; return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; }
@end
// mode: 0 plain layoutIfNeeded, 1 + CATransaction flush, 2 + run loop turn, 3 + both
double BENCH_NAME(int mode, BOOL windowed, double *out, NSInteger *cells){
  @autoreleasepool{
    UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(320,58);l.minimumLineSpacing=0;
    UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,320,480) collectionViewLayout:l];
    [cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"]; static DD*d; d=[DD new]; cv.dataSource=d;
    UIWindow*w=nil; if(windowed){ w=[[UIWindow alloc] initWithFrame:CGRectMake(0,0,320,480)]; [w addSubview:cv]; w.hidden=NO; }
    [cv layoutIfNeeded];
    for(int i=0;i<400;i++){@autoreleasepool{ [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0]]; }}
    CELLS=0;
    double t=now();
    for(int i=0;i<20;i++){
      ((UIScrollView*)cv).contentOffset=CGPointMake(0,i*37+100);
      [cv layoutIfNeeded];
      if(mode==1||mode==3) [CATransaction flush];
      if(mode==2||mode==3) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0,true);
    }
    double el=now()-t;
    *out=(double)cv.visibleCells.count; *cells=CELLS;
    return el;
  } }
