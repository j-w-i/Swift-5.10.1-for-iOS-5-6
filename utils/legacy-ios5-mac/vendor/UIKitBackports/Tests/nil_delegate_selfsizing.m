// Apple-route self-sizing with NO application delegate (iOS 8+ behaviour on iOS 6/7).
// Persistent app: real window, launch returns normally, checks deferred, app stays alive.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
extern void UICInstallCollectionViewDisplay(void);
static int checks, failures;
static NSMutableString *report;
static void Check(BOOL ok, const char *name, NSString *detail){checks++;if(!ok)failures++;[report appendFormat:@"%s: %s %@\n",ok?"PASS":"FAIL",name,detail?:@""];}
static NSInteger fits;
@interface FitCell:UICollectionViewCell @end
@implementation FitCell
- (UICollectionViewLayoutAttributes*)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes*)a{
 fits++;UICollectionViewLayoutAttributes*r=[a copy];r.size=CGSizeMake(a.size.width,40+(a.indexPath.item%5)*10);return r;}
@end
@interface Src:NSObject<UICollectionViewDataSource> @property NSInteger n; @end
@implementation Src
- (NSInteger)collectionView:(UICollectionView*)cv numberOfItemsInSection:(NSInteger)s{return self.n;}
- (UICollectionViewCell*)collectionView:(UICollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)p{return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];}
@end
@interface Del:NSObject<UICollectionViewDelegate> @property NSInteger scrolls; @end
@implementation Del
- (void)scrollViewDidScroll:(UIScrollView*)s{self.scrolls++;}
@end
static UICollectionViewFlowLayout *Layout(void){UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];
 [l setValue:[NSValue valueWithCGSize:CGSizeMake(320,50)] forKey:@"estimatedItemSize"];l.minimumLineSpacing=0;return l;}
static void Run(UIWindow *w){
 report=[NSMutableString string];UICInstallCollectionViewDisplay();
 Src*s=[Src new];s.n=200;
 // 1. no delegate at all
 fits=0;UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,320,480) collectionViewLayout:Layout()];
 [cv registerClass:[FitCell class] forCellWithReuseIdentifier:@"c"];cv.dataSource=s;[w addSubview:cv];[cv layoutIfNeeded];
 // item heights 40,50,60,70,80 repeating: mean 60 -> 200 items converge on the cell-reported sizes for loaded cells
 Check(cv.contentSize.height>11000 && cv.contentSize.height<13000,"no delegate: estimate is honoured (not the 50x50 default grid)",[NSString stringWithFormat:@"content height %.1f (default grid would be 2000)",cv.contentSize.height]);
 UICollectionViewCell*first=cv.visibleCells.count?[cv.visibleCells objectAtIndex:0]:nil;
 Check(first!=nil&&fits>0,"no delegate: cells are asked for their preferred size",[NSString stringWithFormat:@"%ld fitting calls",(long)fits]);
 // 2. isolation: the internal delegate must never be observable
 Check([cv delegate]==nil,"delegate getter stays nil outside layout",[NSString stringWithFormat:@"%@",[cv delegate]]);
 Check(![cv.delegate respondsToSelector:@selector(scrollViewDidScroll:)],"no phantom scroll delegate",nil);
 // 3. scrolling with no delegate must not crash and keeps the estimate in force
 ((UIScrollView*)cv).contentOffset=CGPointMake(0,900);[cv layoutIfNeeded];
 Check([cv delegate]==nil && cv.visibleCells.count>0,"scrolled with no delegate",[NSString stringWithFormat:@"%lu visible",(unsigned long)cv.visibleCells.count]);
 // 4. assigning a delegate later keeps working and receives scroll callbacks
 Del*d=[Del new];cv.delegate=d;((UIScrollView*)cv).contentOffset=CGPointMake(0,1500);[cv layoutIfNeeded];
 Check([cv delegate]==d,"real delegate is returned when set",nil);
 Check(d.scrolls>0,"real delegate still receives scroll callbacks",[NSString stringWithFormat:@"%ld",(long)d.scrolls]);
 Check(cv.contentSize.height>11000 && cv.contentSize.height<14000,"self-sizing survives a delegate assigned later",[NSString stringWithFormat:@"%.1f",cv.contentSize.height]);
 // 5. clearing the delegate again
 cv.delegate=nil;((UIScrollView*)cv).contentOffset=CGPointMake(0,300);[cv layoutIfNeeded];
 Check([cv delegate]==nil && cv.contentSize.height>11000,"self-sizing survives delegate removal",[NSString stringWithFormat:@"%.1f",cv.contentSize.height]);
 // 6. a layout without an estimate is left alone: default grid, delegate untouched
 UICollectionViewFlowLayout*plain=[UICollectionViewFlowLayout new];plain.itemSize=CGSizeMake(50,50);plain.minimumLineSpacing=0;plain.minimumInteritemSpacing=0;
 UICollectionView*cv2=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,320,480) collectionViewLayout:plain];
 [cv2 registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];cv2.dataSource=s;[w addSubview:cv2];[cv2 layoutIfNeeded];
 Check([cv2 delegate]==nil && fabs(cv2.contentSize.height-(200.0/6.0>33?34:33)*50)<60,"layout without estimate is unaffected",[NSString stringWithFormat:@"content height %.1f",cv2.contentSize.height]);
 // 7. delegate that already answers sizeForItem still wins as the seed (existing behaviour preserved)
 [cv removeFromSuperview];[cv2 removeFromSuperview];
}
@interface AD:UIResponder<UIApplicationDelegate> @property(nonatomic,strong) UIWindow*window; @property(nonatomic,strong) UILabel*label; @end
@implementation AD
- (BOOL)application:(UIApplication*)a didFinishLaunchingWithOptions:(NSDictionary*)o{
 freopen("/var/mobile/Documents/nil-delegate.txt","w",stdout);setvbuf(stdout,NULL,_IONBF,0);
 self.window=[[UIWindow alloc]initWithFrame:[UIScreen mainScreen].bounds];UIViewController*vc=[UIViewController new];vc.view.backgroundColor=[UIColor whiteColor];
 self.label=[[UILabel alloc]initWithFrame:CGRectMake(10,30,300,200)];self.label.numberOfLines=8;self.label.text=@"nil-delegate checks running";[vc.view addSubview:self.label];
 UIButton*b=[UIButton buttonWithType:UIButtonTypeRoundedRect];b.frame=CGRectMake(10,240,300,50);[b setTitle:@"Touch test" forState:UIControlStateNormal];[b addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside];[vc.view addSubview:b];
 self.window.rootViewController=vc;[self.window makeKeyAndVisible];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
  Run(self.window);printf("%s",report.UTF8String);printf("RESULT %s checks=%d failures=%d\nDONE\n",failures?"FAIL":"PASS",checks,failures);
  self.label.text=[NSString stringWithFormat:@"%s %d/%d\nTap below, then Home",failures?"FAILED":"PASSED",checks-failures,checks];});
 return YES;}
- (void)tap{self.label.text=@"Tap received";printf("tap received\n");}
@end
int main(int c,char**v){@autoreleasepool{return UIApplicationMain(c,v,nil,@"AD");}}
