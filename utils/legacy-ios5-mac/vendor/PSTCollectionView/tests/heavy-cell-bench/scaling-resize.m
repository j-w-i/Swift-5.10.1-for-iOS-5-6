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
static double run(NSInteger n){ COUNT=n; double total=0; int reps=0;
 @autoreleasepool{
 UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(320,58);l.minimumLineSpacing=0;
 UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,320,480) collectionViewLayout:l];
 [cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];static D*d; d=[D new];cv.dataSource=d;[cv layoutIfNeeded];
 for(int i=1;i<=6;i++){ l.itemSize=CGSizeMake(i%2?300:320,i%2?62:58); [l invalidateLayout]; [cv layoutIfNeeded]; }
 for(int i=1;i<=40;i++){ double t=now(); l.itemSize=CGSizeMake(i%2?300:320,i%2?62:58); [l invalidateLayout]; [cv layoutIfNeeded]; total+=now()-t; reps++; } }
 return total/reps/1000; }
int main(){@autoreleasepool{[UIApplication sharedApplication];
 NSInteger counts[]={8,50,200,1000,5000}; for(int k=0;k<5;k++) printf("items=%-5ld  %.0f us per resize\n",(long)counts[k],run(counts[k]));
}return 0;}
