// Paired cold/reload/batch-update benchmark. Compiled twice (native UICollectionView, then PSTCollectionView
// with distinct class names) into one app so both engines run on the same device in one launch, alternating order.
#import <UIKit/UIKit.h>
#include <mach/mach_time.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegateFlowLayout PSTCollectionViewDelegateFlowLayout
#define UICollectionViewLayoutAttributes PSTCollectionViewLayoutAttributes
#endif
// performWithoutAnimation: is iOS 7 API; setAnimationsEnabled: exists on every iOS this runs on.
static void withoutAnimation(void(^block)(void)){BOOL was=[UIView areAnimationsEnabled];[UIView setAnimationsEnabled:NO];block();[UIView setAnimationsEnabled:was];}
static double now(void){static mach_timebase_info_data_t tb;if(!tb.denom)mach_timebase_info(&tb);return (double)mach_absolute_time()*tb.numer/tb.denom;}
static NSInteger COUNT_;
@interface BENCH_CELL:UICollectionViewCell @end
@implementation BENCH_CELL
- (UICollectionViewLayoutAttributes*)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes*)a{
 UICollectionViewLayoutAttributes*r=[a copy];r.size=CGSizeMake(a.size.width,40+(a.indexPath.item%7)*6);return r;}
@end
@interface BENCH_DS:NSObject<UICollectionViewDataSource,UICollectionViewDelegateFlowLayout> @end
@implementation BENCH_DS
- (NSInteger)collectionView:(UICollectionView*)cv numberOfItemsInSection:(NSInteger)s{return COUNT_;}
- (CGSize)collectionView:(UICollectionView*)cv layout:(UICollectionViewLayout*)l sizeForItemAtIndexPath:(NSIndexPath*)p{return CGSizeMake(320,40+(p.item%7)*6);}
- (UICollectionViewCell*)collectionView:(UICollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)p{return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];}
@end
static BOOL SELFSIZE_;
static UICollectionView *make(NSInteger n,BENCH_DS**keep){COUNT_=n;
 UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(320,58);l.minimumLineSpacing=0;
 UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,320,480) collectionViewLayout:l];
 if(SELFSIZE_)[l setValue:[NSValue valueWithCGSize:CGSizeMake(320,50)] forKey:@"estimatedItemSize"];
 [cv registerClass:SELFSIZE_?[BENCH_CELL class]:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];BENCH_DS*d=[BENCH_DS new];*keep=d;cv.dataSource=d;if(SELFSIZE_)cv.delegate=d;return cv;}
// scenario: 0 cold layout, 1 reload, 2 insert 5 at end + delete 5 at start (each in its own batch, laid out)
double BENCH_NAME(int scenario,NSInteger items){
 @autoreleasepool{
  SELFSIZE_=scenario>=3;if(scenario>=3)scenario-=3;
  BENCH_DS*d;UICollectionView*cv=make(items,&d);double t;
  if(scenario==0){t=now();[cv layoutIfNeeded];return now()-t;}
  [cv layoutIfNeeded];
  if(scenario==1){for(int i=0;i<2;i++){[cv reloadData];[cv layoutIfNeeded];}t=now();for(int i=0;i<5;i++){[cv reloadData];[cv layoutIfNeeded];}return (now()-t)/5;}
  for(int i=0;i<2;i++){ // warm
   withoutAnimation(^{[cv performBatchUpdates:^{COUNT_++;[cv insertItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:COUNT_-1 inSection:0]]];} completion:nil];});[cv layoutIfNeeded];}
  t=now();
  for(int i=0;i<5;i++){
   withoutAnimation(^{[cv performBatchUpdates:^{for(int k=0;k<5;k++){COUNT_++;[cv insertItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:COUNT_-1 inSection:0]]];}} completion:nil];});[cv layoutIfNeeded];
   withoutAnimation(^{[cv performBatchUpdates:^{for(int k=0;k<5;k++){COUNT_--;[cv deleteItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:k inSection:0]]];}} completion:nil];});[cv layoutIfNeeded];}
  return (now()-t)/5;
 }}
