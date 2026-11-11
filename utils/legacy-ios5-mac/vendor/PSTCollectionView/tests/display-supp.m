#import <UIKit/UIKit.h>
#ifdef TEST_PST
#import "PSTCollectionView.h"
#define UICollectionView PSTCollectionView
#define UICollectionViewCell PSTCollectionViewCell
#define UICollectionReusableView PSTCollectionReusableView
#define UICollectionViewFlowLayout PSTCollectionViewFlowLayout
#define UICollectionViewDataSource PSTCollectionViewDataSource
#define UICollectionViewDelegate PSTCollectionViewDelegate
#define UICollectionElementKindSectionHeader PSTCollectionElementKindSectionHeader
#endif
static NSMutableArray *LOG; static NSInteger COUNT=12;
@interface SD : NSObject<UICollectionViewDataSource,UICollectionViewDelegate> @end
@implementation SD
- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv { return 3; }
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return COUNT; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; }
- (UICollectionReusableView *)collectionView:(UICollectionView *)cv viewForSupplementaryElementOfKind:(NSString *)k atIndexPath:(NSIndexPath *)p { return [cv dequeueReusableSupplementaryViewOfKind:k withReuseIdentifier:@"h" forIndexPath:p]; }
- (void)collectionView:(UICollectionView *)cv willDisplayCell:(UICollectionViewCell *)c forItemAtIndexPath:(NSIndexPath *)p { [LOG addObject:[NSString stringWithFormat:@"will cell %ld.%ld",(long)p.section,(long)p.row]]; }
- (void)collectionView:(UICollectionView *)cv didEndDisplayingCell:(UICollectionViewCell *)c forItemAtIndexPath:(NSIndexPath *)p { [LOG addObject:[NSString stringWithFormat:@"end cell %ld.%ld",(long)p.section,(long)p.row]]; }
- (void)collectionView:(UICollectionView *)cv willDisplaySupplementaryView:(UICollectionReusableView *)v forElementKind:(NSString *)k atIndexPath:(NSIndexPath *)p { [LOG addObject:[NSString stringWithFormat:@"will supp %ld",(long)p.section]]; }
- (void)collectionView:(UICollectionView *)cv didEndDisplayingSupplementaryView:(UICollectionReusableView *)v forElementOfKind:(NSString *)k atIndexPath:(NSIndexPath *)p { [LOG addObject:[NSString stringWithFormat:@"end supp %ld",(long)p.section]]; }
@end
static void run(void) {
    LOG=[NSMutableArray array];
    UICollectionViewFlowLayout *l=[UICollectionViewFlowLayout new]; l.itemSize=CGSizeMake(200,40); l.minimumLineSpacing=0; l.headerReferenceSize=CGSizeMake(200,30);
    UICollectionView *cv=[[UICollectionView alloc]initWithFrame:CGRectMake(0,0,200,200) collectionViewLayout:l];
    [cv registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"c"];
    [cv registerClass:[UICollectionReusableView class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"h"];
    SD *d=[SD new]; cv.dataSource=d; cv.delegate=d; [cv layoutIfNeeded];
    [LOG addObject:@"--scroll 400"]; cv.contentOffset=CGPointMake(0,400); [cv layoutIfNeeded];
    [LOG addObject:@"--scroll 0"]; cv.contentOffset=CGPointZero; [cv layoutIfNeeded];
    [LOG addObject:@"--reload"]; [cv reloadData]; [cv layoutIfNeeded];
    NSMutableString *all=[NSMutableString string]; for (NSString *s in LOG) [all appendFormat:@"%@\n",s];
#ifdef TEST_OUT_PATH
    [all writeToFile:@TEST_OUT_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
#endif
    fputs(all.UTF8String,stdout); fflush(stdout);
}
#ifdef TEST_APP_MAIN
@interface AD : UIResponder<UIApplicationDelegate> @property(nonatomic,strong) UIWindow *window; @end
@implementation AD
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o { run(); exit(0); return YES; }
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,@"AD"); } }
#else
int main(void) { @autoreleasepool { [UIApplication sharedApplication]; run(); } return 0; }
#endif
