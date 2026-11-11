// Default flow alignment, independent of estimated sizes and scheduling prototypes.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegateFlowLayout PSTCollectionViewDelegateFlowLayout
#define UICollectionViewScrollDirectionHorizontal PSTCollectionViewScrollDirectionHorizontal
#endif
static int failures,checks;
static CGFloat dimension(NSInteger item){const CGFloat sizes[]={10,30,50,20,40,60,26};return sizes[item];}
@interface CenterSource:NSObject<UICollectionViewDataSource,UICollectionViewDelegateFlowLayout>
@property(nonatomic) NSInteger count;
@property(nonatomic) BOOL horizontal;
@end
@implementation CenterSource
- (NSInteger)collectionView:(UICollectionView*)cv numberOfItemsInSection:(NSInteger)s{return self.count;}
- (UICollectionViewCell*)collectionView:(UICollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)p{return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p];}
- (CGSize)collectionView:(UICollectionView*)cv layout:(UICollectionViewFlowLayout*)layout sizeForItemAtIndexPath:(NSIndexPath*)p{
 return self.horizontal?CGSizeMake(dimension(p.item),60):CGSizeMake(60,dimension(p.item));
}
@end
static CGRect expected(NSInteger item,NSInteger count,BOOL horizontal,BOOL padded){
 NSInteger row=item/3,slot=item%3;CGFloat start=0,max=0;
 for(NSInteger r=0;r<=row;r++){
  CGFloat largest=0;for(NSInteger i=r*3;i<MIN(r*3+3,count);i++)largest=MAX(largest,dimension(i));
  if(r==row)max=largest;else start+=largest+10;
 }
 CGFloat top=padded?12:0,left=padded?14:0,center=(max-dimension(item))/2;
 return horizontal?CGRectMake(left+start+center,top+slot*70,dimension(item),60):CGRectMake(left+slot*70,top+start+center,60,dimension(item));
}
static void run(UIWindow*window){
 printf("provider=%s image=%s\n",class_getName([UICollectionView class]),class_getImageName([UICollectionView class]));
 for(NSInteger horizontal=0;horizontal<2;horizontal++)for(NSInteger padded=0;padded<2;padded++)for(NSNumber*n in @[@1,@5,@6,@7]){
  CenterSource*s=[CenterSource new];s.count=n.integerValue;s.horizontal=horizontal;
  UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];if(horizontal)l.scrollDirection=UICollectionViewScrollDirectionHorizontal;
  // Equal spacings isolate alignment from direction-specific spacing.
  l.minimumLineSpacing=10;l.minimumInteritemSpacing=10;
  l.sectionInset=padded?UIEdgeInsetsMake(12,14,8,6):UIEdgeInsetsZero;
  CGRect bounds=horizontal?CGRectMake(0,0,300,padded?220:200):CGRectMake(0,0,padded?220:200,300);
  UICollectionView*cv=[[UICollectionView alloc]initWithFrame:bounds collectionViewLayout:l];
  [cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];cv.dataSource=s;cv.delegate=s;
  if(window)[window.rootViewController.view addSubview:cv];[cv reloadData];[cv layoutIfNeeded];
  BOOL good=YES;NSMutableArray*frames=[NSMutableArray array];
  for(NSInteger i=0;i<s.count;i++){
   CGRect f=[l layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]].frame,w=expected(i,s.count,horizontal,padded);
   [frames addObject:@[@(f.origin.x),@(f.origin.y),@(f.size.width),@(f.size.height)]];
   good=good&&fabs(f.origin.x-w.origin.x)<.01&&fabs(f.origin.y-w.origin.y)<.01&&fabs(f.size.width-w.size.width)<.01&&fabs(f.size.height-w.size.height)<.01;
  }
  checks++;if(!good)failures++;
  NSDictionary*r=@{@"horizontal":@(horizontal),@"padded":@(padded),@"count":n,@"frames":frames,@"pass":@(good)};
  NSData*json=[NSJSONSerialization dataWithJSONObject:r options:0 error:NULL];printf("CASE %s\n",[[NSString alloc]initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
  [cv removeFromSuperview];cv.dataSource=nil;cv.delegate=nil;
 }
 printf("RESULT %s checks=%d failures=%d\n",failures?"FAIL":"PASS",checks,failures);
}
#ifdef DEVICE_APP
@interface CenterDelegate:UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow*window;
@property(nonatomic,strong) UILabel*status;
@end
@implementation CenterDelegate
- (void)tapped{self.status.text=@"Tap received; Home works normally";printf("tap received\n");}
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options{
 freopen("/var/mobile/Documents/flow-centering.txt","w",stdout);setvbuf(stdout,NULL,_IONBF,0);
 self.window=[[UIWindow alloc]initWithFrame:[UIScreen mainScreen].bounds];UIViewController*vc=[UIViewController new];vc.view.backgroundColor=[UIColor whiteColor];self.window.rootViewController=vc;
 self.status=[[UILabel alloc]initWithFrame:CGRectMake(10,30,300,100)];self.status.numberOfLines=4;self.status.text=@"Flow centering checks running";[vc.view addSubview:self.status];
 UIButton*b=[UIButton buttonWithType:UIButtonTypeRoundedRect];b.frame=CGRectMake(10,140,300,50);[b setTitle:@"Test touch input" forState:UIControlStateNormal];[b addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];[vc.view addSubview:b];[self.window makeKeyAndVisible];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{run(self.window);self.status.text=failures?@"Flow centering failed; see log":@"Flow centering passed\nTap below, then Home";});
 printf("didFinish returning normally\n");return YES;
}
- (void)applicationDidBecomeActive:(UIApplication*)app{printf("application active\n");}
- (void)applicationDidEnterBackground:(UIApplication*)app{printf("application backgrounded normally\n");}
@end
int main(int argc,char**argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,@"CenterDelegate");}}
#else
int main(void){@autoreleasepool{setvbuf(stdout,NULL,_IONBF,0);[UIApplication sharedApplication];run(nil);}return failures?1:0;}
#endif
