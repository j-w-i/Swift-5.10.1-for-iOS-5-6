#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegate PSTCollectionViewDelegate
#endif
static NSMutableArray *LOG;
@interface SD : NSObject<UICollectionViewDataSource,UICollectionViewDelegate> @end
@implementation SD
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 40; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; }
- (void)collectionView:(UICollectionView *)cv willDisplayCell:(UICollectionViewCell *)c forItemAtIndexPath:(NSIndexPath *)p { [LOG addObject:[NSString stringWithFormat:@"will %ld",(long)p.row]]; }
- (void)collectionView:(UICollectionView *)cv didEndDisplayingCell:(UICollectionViewCell *)c forItemAtIndexPath:(NSIndexPath *)p { [LOG addObject:[NSString stringWithFormat:@"end %ld",(long)p.row]]; }
@end
static void run(void) {
    LOG=[NSMutableArray array];
    UICollectionViewFlowLayout *l=[UICollectionViewFlowLayout new]; l.itemSize=CGSizeMake(200,50); l.minimumLineSpacing=0;
    UICollectionView *cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,200) collectionViewLayout:l];
    [cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];
    SD *d=[SD new]; cv.dataSource=d; cv.delegate=d; [cv layoutIfNeeded];
    [LOG addObject:@"--scroll 100"]; cv.contentOffset=CGPointMake(0,100); [cv layoutIfNeeded];
    [LOG addObject:@"--scroll 1000"]; cv.contentOffset=CGPointMake(0,1000); [cv layoutIfNeeded];
    [LOG addObject:@"--scroll 0"]; cv.contentOffset=CGPointZero; [cv layoutIfNeeded];
    [LOG addObject:@"--reload"]; [cv reloadData]; [cv layoutIfNeeded];
    NSMutableString *all=[NSMutableString string]; for (NSString *s in LOG) [all appendFormat:@"%@\n",s];
#ifdef TEST_OUT_PATH
    [all writeToFile:@TEST_OUT_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
#endif
    fputs(all.UTF8String,stdout); fflush(stdout);
}
#ifdef TEST_APP_MAIN
// iOS 5 requires UIApplicationMain before UI objects exist; the iOS 27
// simulator crashes for scene-less UIApplicationMain, so use a plain main there.
@interface AD : UIResponder<UIApplicationDelegate> @property(nonatomic,strong) UIWindow *window; @end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o { run(); exit(0); return YES; }
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,@"AD"); } }
#else
int main(void) { @autoreleasepool { [UIApplication sharedApplication]; run(); } return 0; }
#endif
