#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdio.h>
static void mark(const char *s){ FILE*f=fopen("/var/mobile/Documents/route-ui-binding.txt","a");if(f){fprintf(f,"%s\n",s);fclose(f);} }
@interface BindingDelegate:UIResponder<UIApplicationDelegate,UICollectionViewDataSource>
@property(nonatomic,strong) UIWindow*window;
@property(nonatomic,strong) UILabel*status;
@end
@implementation BindingDelegate
- (NSInteger)collectionView:(UICollectionView*)cv numberOfItemsInSection:(NSInteger)section{return 12;}
- (UICollectionViewCell*)collectionView:(UICollectionView*)cv cellForItemAtIndexPath:(NSIndexPath*)p{
 UICollectionViewCell*c=[cv dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:p];
 c.backgroundColor=p.row%2?[UIColor blueColor]:[UIColor grayColor];return c;
}
- (void)tapped { self.status.text=@"Tap received — main thread responsive";mark("tap received"); }
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options{
 mark("didFinish entered");
 Class direct=[UICollectionView class],lookup=objc_getClass("UICollectionView");
 BOOL injected=class_getInstanceMethod(direct,sel_registerName("spikeEngine"))!=NULL;
 mark(direct==lookup?"compiled/runtime class references AGREE":"FAIL: class references differ");
 mark(injected?"selected injected class":"selected native UIKit class");
 self.window=[[UIWindow alloc]initWithFrame:[UIScreen mainScreen].bounds];
 UIViewController*vc=[UIViewController new];vc.view.backgroundColor=[UIColor whiteColor];self.window.rootViewController=vc;
 self.status=[[UILabel alloc]initWithFrame:CGRectMake(10,30,300,100)];self.status.numberOfLines=4;
 self.status.text=injected?@"iOS 5: injected stand-in\nNo full engine in this spike":@"iOS 6: native UICollectionView\nTap the button to check input";
 [vc.view addSubview:self.status];
 UIButton*b=[UIButton buttonWithType:UIButtonTypeRoundedRect];b.frame=CGRectMake(20,135,280,50);[b setTitle:@"Test touch input" forState:UIControlStateNormal];[b addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];[vc.view addSubview:b];
 if(!injected && direct==lookup){
  UICollectionViewFlowLayout*l=[UICollectionViewFlowLayout new];l.itemSize=CGSizeMake(80,55);
  UICollectionView*cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,200,320,200) collectionViewLayout:l];
  [cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"cell"];cv.dataSource=self;[vc.view addSubview:cv];[cv layoutIfNeeded];
  mark(cv.visibleCells.count>0?"native collection laid out real cells":"FAIL: no native cells");
 }
 [self.window makeKeyAndVisible];
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{mark("delayed main queue callback ran");});
 mark("didFinish returning normally");return YES;
}
- (void)applicationDidBecomeActive:(UIApplication*)app{mark("application active");}
- (void)applicationDidEnterBackground:(UIApplication*)app{mark("application backgrounded normally");}
@end
int main(int argc,char**argv){@autoreleasepool{mark("main entered");return UIApplicationMain(argc,argv,nil,@"BindingDelegate");}}
