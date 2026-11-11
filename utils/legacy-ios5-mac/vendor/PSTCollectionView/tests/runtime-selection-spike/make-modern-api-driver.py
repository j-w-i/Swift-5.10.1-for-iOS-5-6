#!/usr/bin/env python3
"""Adapt the Apple device assertions into a persistent, asynchronous dual-route experiment."""
import pathlib,sys
source,out=map(pathlib.Path,sys.argv[1:]);text=source.read_text()
def replace(old,new):
    global text
    if text.count(old)!=1:raise SystemExit('Fixture changed: '+old)
    text=text.replace(old,new,1)
replace('#import <objc/message.h>','#import <objc/message.h>\n#import <objc/runtime.h>\n#include <string.h>')
replace('static int failures;', 'static int failures,checks;\nstatic NSArray *keptFixtures;')
replace('    if (!ok) failures++;','    checks++; if (!ok) failures++;')
replace('static void Run(UIWindow *window) {','static void Run(UIWindow *window, void (^completion)(void)) {')
replace('    UICInstallCollectionViewDisplay();','''    Class bound=[UICollectionView class];
    const char *image=class_getImageName(bound);
    BOOL fallback=image&&strstr(image,"RuntimeFallback.dylib")!=NULL;
    printf("provider=%s image=%s\\n",fallback?"PST":"UIKit",image?:"unknown");
    Check(fallback==(kCFCoreFoundationVersionNumber<793.0),"expected engine selected",nil);
    Check(bound==objc_getClass("UICollectionView"),"compiled/runtime class identity agrees",nil);
    if(!fallback) UICInstallCollectionViewDisplay();''')
start=text.index('    // Animated batch updates:')
text=text[:start]+'''    // No nested run-loop pumping inside a main-queue block: completions must run asynchronously.
    Source *changing=[Source new];changing.items=200;
    UICollectionView *cv3=MakeView(MakeLayout(CGSizeMake(320,50)),changing,window);
    keptFixtures=@[source,sized,changing,cv,cv2,cv3]; // assign delegates stay alive on timeout too
    __block BOOL done=NO,insertCalled=NO,deleteCalled=NO;
    void (^finish)(void)=^{
        if(done)return;done=YES;
        [cv removeFromSuperview];[cv2 removeFromSuperview];[cv3 removeFromSuperview];
        printf("RESULT: %s (%d checks, %d failures)\\n",failures?"FAIL":"PASS",checks,failures);
        completion();
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(!done){Check(NO,"animation callback timeout",[NSString stringWithFormat:@"insertCalled=%d deleteCalled=%d",insertCalled,deleteCalled]);finish();}
    });
    NSInteger displayedBefore=changing.willCell;
    NSMutableArray *inserted=[NSMutableArray array];
    for(NSInteger row=0;row<5;row++)[inserted addObject:[NSIndexPath indexPathForRow:row inSection:0]];
    [cv3 performBatchUpdates:^{changing.items=205;[cv3 insertItemsAtIndexPaths:inserted];} completion:^(BOOL finished){
        if(done)return;insertCalled=YES;printf("insert callback called finished=%d\\n",finished);
        Check(finished,"animated insert completes",nil);
        Check(fabs(cv3.contentSize.height-(205*50+20))<1,"animated insert applies new item count",[NSString stringWithFormat:@"%.1f",cv3.contentSize.height]);
        Check(changing.willCell>displayedBefore,"willDisplay for cells that arrive in the animation",[NSString stringWithFormat:@"%ld -> %ld",(long)displayedBefore,(long)changing.willCell]);
        Check(cv3.visibleCells.count>0&&cv3.visibleCells.count<=205,"visible cells sane after animated insert",[NSString stringWithFormat:@"%lu",(unsigned long)cv3.visibleCells.count]);
        dispatch_async(dispatch_get_main_queue(),^{
            if(done)return;
            NSInteger beforeDelete=changing.willCell;
            NSMutableArray *deleted=[NSMutableArray array];
            for(NSInteger row=0;row<5;row++)[deleted addObject:[NSIndexPath indexPathForRow:row inSection:0]];
            [cv3 performBatchUpdates:^{changing.items=200;[cv3 deleteItemsAtIndexPaths:deleted];} completion:^(BOOL deleteFinished){
                if(done)return;deleteCalled=YES;printf("delete callback called finished=%d\\n",deleteFinished);
                Check(deleteFinished,"animated delete completes",nil);
                Check(fabs(cv3.contentSize.height-(200*50+20))<1,"animated delete applies new item count",[NSString stringWithFormat:@"%.1f",cv3.contentSize.height]);
                Check(changing.willCell>=beforeDelete,"no willDisplay regressions after animated delete",nil);
                finish();
            }];
        });
    }];
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UILabel *status;
@end
@implementation AppDelegate
- (void)tapped{self.status.text=@"Tap received; Home works normally";printf("tap received\\n");}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    freopen("/var/mobile/Documents/modern-route-out.txt","w",stdout);setvbuf(stdout,NULL,_IONBF,0);
    self.window=[[UIWindow alloc]initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *vc=[UIViewController new];vc.view.backgroundColor=[UIColor whiteColor];self.window.rootViewController=vc;
    self.status=[[UILabel alloc]initWithFrame:CGRectMake(10,30,300,100)];self.status.numberOfLines=4;self.status.text=@"Modern API checks running";[vc.view addSubview:self.status];
    UIButton *button=[UIButton buttonWithType:UIButtonTypeRoundedRect];button.frame=CGRectMake(10,140,300,50);
    [button setTitle:@"Test touch input" forState:UIControlStateNormal];[button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];[vc.view addSubview:button];
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        Run(self.window,^{self.status.text=failures?@"Modern API checks failed; see log":@"Modern API checks passed\\nTap below, then Home";});
    });
    printf("didFinish returning normally\\n");return YES;
}
- (void)applicationDidBecomeActive:(UIApplication*)app{printf("application active\\n");}
- (void)applicationDidEnterBackground:(UIApplication*)app{printf("application backgrounded normally\\n");}
@end
int main(int argc,char**argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,@"AppDelegate");}}
'''
out.write_text(text)
