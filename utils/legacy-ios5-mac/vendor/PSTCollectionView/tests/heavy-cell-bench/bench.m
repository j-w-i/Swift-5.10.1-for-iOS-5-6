#import <UIKit/UIKit.h>
#include <mach/mach_time.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#endif
static int LABELS=3;
void SetLabels_(int n);
static double now(void){ static mach_timebase_info_data_t tb; if(!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time()*tb.numer/tb.denom; }
@interface HC : UICollectionViewCell @property(nonatomic,strong) UILabel *a,*b,*c; @end
@implementation HC
- (id)initWithFrame:(CGRect)f { self=[super initWithFrame:f]; if(self){
  NSMutableArray *ls=[NSMutableArray array]; for(int i=0;i<LABELS;i++){ UILabel*l=[[UILabel alloc] initWithFrame:CGRectMake(8,4+i*12,f.size.width-16,12)]; l.autoresizingMask=UIViewAutoresizingFlexibleWidth; l.backgroundColor=[UIColor clearColor]; l.font=[UIFont systemFontOfSize:10]; [self.contentView addSubview:l]; [ls addObject:l]; }
  self.a=ls.count>0?ls[0]:nil; self.b=ls.count>1?ls[1]:nil; self.c=ls.count>2?ls[2]:nil; }
  return self; }
@end
@interface D : NSObject<UICollectionViewDataSource> @end
@implementation D
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 200; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p {
  HC *c=[cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];
  c.a.text=@"Row title"; c.b.text=@"secondary"; c.c.text=@"#"; return c; }
@end
static UICollectionView *make(void){
  UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(320,58);l.minimumLineSpacing=0;
  UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,320,480) collectionViewLayout:l];
  [cv registerClass:[HC class] forCellWithReuseIdentifier:@"c"]; static D*d; d=[D new]; cv.dataSource=d; [cv layoutIfNeeded]; return cv; }
void BENCH_SETLABELS(int n){ LABELS=n; }
double BENCH_NAME(int scenario){
  @autoreleasepool{
    UICollectionView*cv=make(); UIScrollView*sv=(UIScrollView*)cv; double t=now();
    if(scenario==0){ for(int i=0;i<10;i++){ sv.contentOffset=CGPointMake(0,sv.contentOffset.y+87); [cv layoutIfNeeded]; } }
    else if(scenario==1){ UICollectionViewFlowLayout*l=(UICollectionViewFlowLayout*)cv.collectionViewLayout; for(int i=0;i<3;i++){ l.itemSize=CGSizeMake(i%2?300:320,i%2?62:58); [l invalidateLayout]; [cv layoutIfNeeded]; } }
    else if(scenario==2){ [cv reloadData]; [cv layoutIfNeeded]; }
    return now()-t; } }
