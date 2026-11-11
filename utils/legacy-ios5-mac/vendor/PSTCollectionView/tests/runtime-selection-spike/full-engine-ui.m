// Persistent device-only full-engine experiment. No exit during launch, no system patches.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <string.h>
void UICInstallCollectionViewDisplay(void);
static NSUInteger made,reused,layoutQueries,willDisplay,checks,failures;
static void logLine(NSString*s){FILE*f=fopen("/var/mobile/Documents/full-engine-route.txt","a");if(f){fprintf(f,"%s\n",s.UTF8String);fclose(f);}}
static void check(BOOL ok,NSString*s){checks++;if(!ok)failures++;logLine([NSString stringWithFormat:@"%@ %@",ok?@"PASS":@"FAIL",s]);}
@interface EngineAppCell:UICollectionViewCell
@property(nonatomic,strong) UILabel *title;
@property(nonatomic) uint32_t canary;
@end
@implementation EngineAppCell
- (id)initWithFrame:(CGRect)r{self=[super initWithFrame:r];if(self){made++;self.canary=0x1234abcd;self.title=[[UILabel alloc]initWithFrame:CGRectMake(8,0,280,40)];self.title.backgroundColor=[UIColor clearColor];[self.contentView addSubview:self.title];}return self;}
- (void)prepareForReuse{[super prepareForReuse];reused++;if(self.canary!=0x1234abcd)logLine(@"FAIL canary damaged during reuse");}
@end
@interface EngineAppFlow:UICollectionViewFlowLayout @end
@implementation EngineAppFlow
- (NSArray*)layoutAttributesForElementsInRect:(CGRect)rect{layoutQueries++;return [super layoutAttributesForElementsInRect:rect];}
@end
@interface EngineAppDelegate:UIResponder<UIApplicationDelegate,UICollectionViewDataSource,UICollectionViewDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UICollectionView *collection;
@property(nonatomic,strong) UILabel *status;
@end
@implementation EngineAppDelegate
- (NSInteger)collectionView:(UICollectionView*)cv numberOfItemsInSection:(NSInteger)section{return 200;}
- (UICollectionViewCell*)collectionView:(UICollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)p{
 EngineAppCell*c=(id)[cv dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:p];
 c.title.text=[NSString stringWithFormat:@"Row %ld",(long)p.row];return c;
}
- (void)collectionView:(UICollectionView*)cv willDisplayCell:(UICollectionViewCell*)cell forItemAtIndexPath:(NSIndexPath*)p{willDisplay++;}
- (void)tapped{self.status.text=@"Tap received; Home returns normally";logLine(@"tap received");}
- (void)verifyCells{
 check(self.collection.visibleCells.count>0,@"visible cells exist");
 BOOL good=YES;
 for(EngineAppCell*c in self.collection.visibleCells){
  NSIndexPath*p=[self.collection indexPathForCell:c];
  good=good&&[c isKindOfClass:[EngineAppCell class]]&&[c isKindOfClass:[UICollectionReusableView class]]&&c.canary==0x1234abcd&&c.title.superview==c.contentView;
  good=good&&[c.title.text isEqual:[NSString stringWithFormat:@"Row %ld",(long)p.row]]&&fabs(c.bounds.size.height-50)<0.01;
 }
 check(good,@"cell subclass ivars, casts, content and frames intact");
}
- (void)exercise{
 [self.collection layoutIfNeeded];[self verifyCells];
 logLine([NSString stringWithFormat:@"screen=%@ scale=%g window=%@ collection=%@ background=%@",NSStringFromCGRect([UIScreen mainScreen].bounds),[UIScreen mainScreen].scale,NSStringFromCGRect(self.window.bounds),NSStringFromCGRect(self.collection.frame),self.collection.backgroundColor]);
 for(EngineAppCell*c in self.collection.visibleCells){logLine([NSString stringWithFormat:@"cell=%@ content=%@ label=%@ labelBackground=%@",NSStringFromCGRect(c.frame),NSStringFromCGRect(c.contentView.frame),NSStringFromCGRect(c.title.frame),c.title.backgroundColor]);break;}
 check(fabs(self.collection.contentSize.height-10000)<0.01,@"content height matches 200 x 50");
 for(NSNumber*y in @[@500,@1000,@1500,@0]){self.collection.contentOffset=CGPointMake(0,y.doubleValue);[self.collection layoutIfNeeded];[self verifyCells];}
 check(reused>0,@"prepareForReuse subclass override ran");
 check(layoutQueries>0,@"flow-layout subclass override ran");
 check(willDisplay>0,@"willDisplay delivered");
 logLine([NSString stringWithFormat:@"counts created=%lu reused=%lu layoutQueries=%lu willDisplay=%lu",(unsigned long)made,(unsigned long)reused,(unsigned long)layoutQueries,(unsigned long)willDisplay]);
 logLine([NSString stringWithFormat:@"RESULT %@ checks=%lu failures=%lu",failures?@"FAIL":@"PASS",(unsigned long)checks,(unsigned long)failures]);
 self.status.text=failures?@"Engine test failed; see log":@"Engine checks passed\nTap below, then Home";
}
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options{
 FILE*f=fopen("/var/mobile/Documents/full-engine-route.txt","w");if(f)fclose(f);
 logLine(@"didFinish entered");
 Class bound=[UICollectionView class];BOOL fallback=strstr(class_getImageName(bound),"RuntimeFallback.dylib")!=NULL;
 logLine(fallback?@"selected full PST fallback":@"selected native UIKit");
 check(bound==objc_getClass("UICollectionView"),@"compiled/runtime collection identity agrees");
 // The Apple-route hooks must not wrap the already implemented PST engine on iOS 5.
 if(!fallback)UICInstallCollectionViewDisplay();
 self.window=[[UIWindow alloc]initWithFrame:[UIScreen mainScreen].bounds];UIViewController*vc=[UIViewController new];vc.view.backgroundColor=[UIColor whiteColor];self.window.rootViewController=vc;
 self.status=[[UILabel alloc]initWithFrame:CGRectMake(10,25,300,85)];self.status.numberOfLines=3;self.status.text=@"Full engine diagnostic";[vc.view addSubview:self.status];
 UIButton*b=[UIButton buttonWithType:UIButtonTypeRoundedRect];b.frame=CGRectMake(10,110,300,45);[b setTitle:@"Test touch input" forState:UIControlStateNormal];[b addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];[vc.view addSubview:b];
 EngineAppFlow*l=[EngineAppFlow new];l.itemSize=CGSizeMake(320,50);l.minimumLineSpacing=0;
 self.collection=[[UICollectionView alloc]initWithFrame:CGRectMake(0,165,320,240) collectionViewLayout:l];
 self.collection.backgroundColor=[UIColor whiteColor]; // explicit fixture styling: native iOS 6 defaults to black
 [self.collection registerClass:[EngineAppCell class] forCellWithReuseIdentifier:@"cell"];self.collection.dataSource=self;self.collection.delegate=self;[vc.view addSubview:self.collection];[self.window makeKeyAndVisible];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self exercise];});
 logLine(@"didFinish returned normally");return YES;
}
- (void)applicationDidBecomeActive:(UIApplication*)app{logLine(@"application active");}
- (void)applicationDidEnterBackground:(UIApplication*)app{logLine(@"application backgrounded normally");}
@end
int main(int argc,char**argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,@"EngineAppDelegate");}}
