// Self-sizing cold/scroll/reload cost versus item count. CPU time only; single engine per build.
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
static NSInteger COUNT=200, delegateCalls, fitCalls, requests;
static double contentHeight;
#ifndef REPS
#define REPS 3
#endif
static double now(void){static mach_timebase_info_data_t tb;if(!tb.denom)mach_timebase_info(&tb);return (double)mach_absolute_time()*tb.numer/tb.denom;}
@interface SC:UICollectionViewCell @end
@implementation SC
- (UICollectionViewLayoutAttributes*)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes*)a{
 fitCalls++;UICollectionViewLayoutAttributes*r=[a copy];r.size=CGSizeMake(a.size.width,40+(a.indexPath.item%7)*6);return r;}
@end
@interface DS:NSObject<UICollectionViewDataSource,UICollectionViewDelegateFlowLayout> @property BOOL delegateSizes; @end
@implementation DS
- (NSInteger)collectionView:(UICollectionView*)cv numberOfItemsInSection:(NSInteger)s{return COUNT;}
- (UICollectionViewCell*)collectionView:(UICollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)p{requests++;return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];}
- (CGSize)collectionView:(UICollectionView*)cv layout:(UICollectionViewLayout*)l sizeForItemAtIndexPath:(NSIndexPath*)p{delegateCalls++;return CGSizeMake(320,40+(p.item%7)*6);}
@end
static void run(NSInteger n,BOOL withDelegate,double o[6]){COUNT=n;delegateCalls=fitCalls=requests=0;
 @autoreleasepool{
  UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.estimatedItemSize=CGSizeMake(320,50);l.minimumLineSpacing=0;
  UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,320,480) collectionViewLayout:l];
  [cv registerClass:[SC class] forCellWithReuseIdentifier:@"c"];static DS*d;d=[DS new];cv.dataSource=d;if(withDelegate)cv.delegate=d;
  double t=now();[cv layoutIfNeeded];o[0]=(now()-t)/1000;o[3]=delegateCalls;o[4]=fitCalls;o[5]=requests;contentHeight=cv.contentSize.height;
  for(int i=0;i<5;i++){cv.contentOffset=CGPointMake(0,i*37);[cv layoutIfNeeded];}
  t=now();int steps=40;for(int i=0;i<steps;i++){cv.contentOffset=CGPointMake(0,200+i*29);[cv layoutIfNeeded];}o[1]=(now()-t)/1000/steps;
  for(int i=0;i<3;i++){[cv reloadData];[cv layoutIfNeeded];}
  t=now();int rl=10;for(int i=0;i<rl;i++){[cv reloadData];[cv layoutIfNeeded];}o[2]=(now()-t)/1000/rl;}}
static void all(void){
 NSInteger counts[]={200,1000,5000};
 for(int m=0;m<2;m++)for(int k=0;k<3;k++){double o[6];run(counts[k],m,o);
  printf("%s delegate=%d items=%-5ld cold=%.0fus scroll=%.0fus reload=%.0fus  (cold: delegateCalls=%.0f fits=%.0f requests=%.0f contentHeight=%.0f)\n",
  #ifdef TEST_PST
  "PST   ",
  #else
  "native",
  #endif
  m,(long)counts[k],o[0],o[1],o[2],o[3],o[4],o[5],contentHeight);}
}
#ifdef DEVICE_APP
// Persistent app: real root VC/window, launch returns normally, work is deferred, app stays alive.
@interface SD:UIResponder<UIApplicationDelegate> @property(nonatomic,strong) UIWindow*window; @end
@implementation SD
- (BOOL)application:(UIApplication*)a didFinishLaunchingWithOptions:(NSDictionary*)o{
 self.window=[[UIWindow alloc]initWithFrame:[UIScreen mainScreen].bounds];UIViewController*vc=[UIViewController new];
 vc.view.backgroundColor=[UIColor whiteColor];UILabel*l=[[UILabel alloc]initWithFrame:CGRectMake(10,30,300,60)];l.numberOfLines=3;l.text=@"Self-sizing scaling running";[vc.view addSubview:l];
 self.window.rootViewController=vc;[self.window makeKeyAndVisible];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
  FILE*f=fopen(OUTFILE,"w");int saved=dup(1);fflush(stdout);dup2(fileno(f),1);setvbuf(stdout,NULL,_IONBF,0);
  for(int rep=0;rep<REPS;rep++){printf("--- repetition %d\n",rep);all();}
  printf("DONE\n");fflush(stdout);dup2(saved,1);fclose(f);l.text=@"Done. Home works normally.";});
 return YES;}
@end
int main(int c,char**v){@autoreleasepool{return UIApplicationMain(c,v,nil,@"SD");}}
#else
int main(){@autoreleasepool{setvbuf(stdout,NULL,_IONBF,0);[UIApplication sharedApplication];all();}return 0;}
#endif
