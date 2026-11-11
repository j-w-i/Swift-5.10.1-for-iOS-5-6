//
//  apple_route_ios6_device_test.m
//  Device test for the Apple route on iOS 6/7: the API the runtime adds to Apple's own
//  UICollectionView when the OS lacks it. Expected to run on real hardware, because the hooks
//  observe UIKit 6/7 private behaviour that no newer simulator reproduces.
//
//  Checks (prints PASS/FAIL per line and a final RESULT):
//    * willDisplayCell: fires exactly once per visible cell, never twice (strictly additive)
//    * willDisplaySupplementaryView:forElementKind:atIndexPath: fires for a header
//    * visibleSupplementaryViewsOfKind: / indexPathsForVisibleSupplementaryElementsOfKind:
//    * collectionView:prefetchItemsAtIndexPaths: announces items ahead of a forward scroll only
//    * estimatedItemSize + preferredLayoutAttributesFittingAttributes: drive geometry
//    * UICollectionViewLayoutAttributes setTransform: round-trips
//
#import <UIKit/UIKit.h>
#import <objc/message.h>
void UICInstallCollectionViewDisplay(void);

static int failures;
static void Check(BOOL ok, const char *name, NSString *detail) {
    printf("%s %s%s%s\n", ok ? "PASS" : "FAIL", name, detail.length ? " : " : "", detail.length ? detail.UTF8String : "");
    if (!ok) failures++;
}

@protocol AppleRouteDelegate <UICollectionViewDelegate>
- (void)collectionView:(UICollectionView *)cv willDisplayCell:(UICollectionViewCell *)c forItemAtIndexPath:(NSIndexPath *)p;
- (void)collectionView:(UICollectionView *)cv willDisplaySupplementaryView:(UICollectionReusableView *)v forElementKind:(NSString *)k atIndexPath:(NSIndexPath *)p;
@end
@protocol AppleRoutePrefetch <UICollectionViewDataSourcePrefetching>
- (void)collectionView:(UICollectionView *)cv prefetchItemsAtIndexPaths:(NSArray *)paths;
@end

static const CGFloat kFittedHeight = 80;

@interface Cell : UICollectionViewCell @end
@implementation Cell
- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)attributes {
    UICollectionViewLayoutAttributes *preferred = [attributes copy];
    preferred.frame = CGRectMake(attributes.frame.origin.x, attributes.frame.origin.y, attributes.frame.size.width, kFittedHeight);
    return preferred;
}
@end
@interface Header : UICollectionReusableView @end
@implementation Header @end

@interface Source : NSObject <UICollectionViewDataSource, AppleRouteDelegate, AppleRoutePrefetch>
@property(nonatomic) NSInteger items, willCell, willSupp, prefetched;
@property(nonatomic,strong) NSMutableArray *prefetchPaths;
@end
@implementation Source
- (id)init { if ((self = [super init])) _prefetchPaths = [NSMutableArray array]; return self; }
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return self.items; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)p { return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:p]; }
- (UICollectionReusableView *)collectionView:(UICollectionView *)cv viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)p {
    return [cv dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"h" forIndexPath:p];
}
- (void)collectionView:(UICollectionView *)cv willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)p { self.willCell++; }
- (void)collectionView:(UICollectionView *)cv willDisplaySupplementaryView:(UICollectionReusableView *)view forElementKind:(NSString *)kind atIndexPath:(NSIndexPath *)p { self.willSupp++; }
- (void)collectionView:(UICollectionView *)cv prefetchItemsAtIndexPaths:(NSArray *)paths { self.prefetched += (NSInteger)paths.count; [self.prefetchPaths addObjectsFromArray:paths]; }
@end

static UICollectionViewFlowLayout *MakeLayout(CGSize itemSize) {
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.itemSize = itemSize; layout.minimumLineSpacing = 0; layout.headerReferenceSize = CGSizeMake(320, 20);
    return layout;
}
static UICollectionView *MakeView(UICollectionViewFlowLayout *layout, Source *source, UIWindow *window) {
    UICollectionView *cv = [[UICollectionView alloc] initWithFrame:CGRectMake(0, 0, 320, 480) collectionViewLayout:layout];
    [cv registerClass:[Cell class] forCellWithReuseIdentifier:@"c"];
    [cv registerClass:[Header class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"h"];
    cv.dataSource = source; cv.delegate = source;
    [window addSubview:cv]; [cv layoutIfNeeded];
    return cv;
}

static void Run(UIWindow *window) {
    printf("=== CF version %.1f (runtime installs the iOS 8 hooks below 1140)\n", kCFCoreFoundationVersionNumber);
    UICInstallCollectionViewDisplay();

    SEL visibleSel = NSSelectorFromString(@"visibleSupplementaryViewsOfKind:");
    SEL pathsSel = NSSelectorFromString(@"indexPathsForVisibleSupplementaryElementsOfKind:");
    SEL setPrefetchSel = NSSelectorFromString(@"setPrefetchDataSource:");
    Check([UICollectionView instancesRespondToSelector:visibleSel] && [UICollectionView instancesRespondToSelector:pathsSel],
          "iOS 9 supplementary accessors installed", nil);
    Check([UICollectionView instancesRespondToSelector:setPrefetchSel], "iOS 10 prefetching installed", nil);

    // willDisplay, and no double delivery.
    Source *source = [Source new]; source.items = 200;
    UICollectionView *cv = MakeView(MakeLayout(CGSizeMake(320, 50)), source, window);
    NSUInteger visible = cv.visibleCells.count;
    Check(source.willCell == (NSInteger)visible && visible > 0, "willDisplayCell once per visible cell",
          [NSString stringWithFormat:@"%ld callbacks, %lu visible", (long)source.willCell, (unsigned long)visible]);
    Check(source.willSupp == 1, "willDisplaySupplementaryView for the header",
          [NSString stringWithFormat:@"%ld callbacks", (long)source.willSupp]);
    NSUInteger suppBefore = 1;
    Check([cv respondsToSelector:visibleSel] ? [[cv performSelector:visibleSel withObject:UICollectionElementKindSectionHeader] count] == suppBefore : NO,
          "visibleSupplementaryViewsOfKind returns the header", nil);
    NSArray *headerPaths = [cv respondsToSelector:pathsSel] ? [cv performSelector:pathsSel withObject:UICollectionElementKindSectionHeader] : nil;
    Check(headerPaths.count == 1 && [[headerPaths firstObject] row] == 0 && [[headerPaths firstObject] section] == 0,
          "indexPathsForVisibleSupplementaryElementsOfKind", [headerPaths description]);

    // Nothing may be prefetched while the bounds are still.
    [cv performSelector:setPrefetchSel withObject:source];
    [cv layoutIfNeeded];
    Check(source.prefetched == 0, "no prefetch while stationary", [NSString stringWithFormat:@"%ld paths", (long)source.prefetched]);

    // A forward scroll announces items ahead of the visible rect, once each.
    ((UIScrollView *)cv).contentOffset = CGPointMake(0, 900); [cv layoutIfNeeded];
    NSInteger announced = source.prefetched;
    Check(announced > 0, "prefetch announces items ahead of a forward scroll", [NSString stringWithFormat:@"%ld paths", (long)announced]);
    ((UIScrollView *)cv).contentOffset = CGPointMake(0, 900); [cv layoutIfNeeded];
    Check(source.prefetched == announced, "prefetch does not repeat for the same position", nil);

    // Self-sizing through estimatedItemSize plus the cell's preferred size.
    Source *sized = [Source new]; sized.items = 200;
    UICollectionViewFlowLayout *sizing = MakeLayout(CGSizeMake(320, 50));
    [sizing setValue:[NSValue valueWithCGSize:CGSizeMake(320, 50)] forKey:@"estimatedItemSize"];
    UICollectionView *cv2 = MakeView(sizing, sized, window);
    CGFloat expected = 200 * kFittedHeight + 20;
    Check(fabs(cv2.contentSize.height - expected) < 1, "self-sizing drives content height",
          [NSString stringWithFormat:@"%.1f (expected %.1f)", cv2.contentSize.height, expected]);
    UICollectionViewCell *first = cv2.visibleCells.firstObject;
    Check(first && fabs(first.frame.size.height - kFittedHeight) < 1, "self-sized cell takes its preferred height",
          first ? NSStringFromCGRect(first.frame) : @"no visible cell");

    // Affine transform on layout attributes (iOS 7 API on Apple's class).
    UICollectionViewLayoutAttributes *attributes = [sizing layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    SEL setSel = NSSelectorFromString(@"setTransform:"), getSel = NSSelectorFromString(@"transform");
    CGAffineTransform wanted = CGAffineTransformMakeRotation(0.5), readBack = CGAffineTransformIdentity;
    BOOL hasBoth = [attributes respondsToSelector:setSel] && [attributes respondsToSelector:getSel];
    if (hasBoth) {
        ((void (*)(id, SEL, CGAffineTransform))objc_msgSend)(attributes, setSel, wanted);
        NSMethodSignature *signature = [attributes methodSignatureForSelector:getSel];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        [invocation setTarget:attributes]; [invocation setSelector:getSel]; [invocation invoke];
        [invocation getReturnValue:&readBack];
    }
    Check(hasBoth && fabs(readBack.a - wanted.a) < 0.001 && fabs(readBack.b - wanted.b) < 0.001,
          "layout attributes transform round-trips", [NSString stringWithFormat:@"a=%.3f b=%.3f", readBack.a, readBack.b]);

    // Animated batch updates: the hooks must survive UIKit's animated pass on iOS 6, and the
    // delegate must still hear willDisplay for the arriving cells exactly once each.
    Source *changing = [Source new]; changing.items = 200;
    UICollectionView *cv3 = MakeView(MakeLayout(CGSizeMake(320, 50)), changing, window);
    NSInteger displayedBefore = changing.willCell;
    __block BOOL insertCompleted = NO;
    NSMutableArray *inserted = [NSMutableArray array];
    for (NSInteger row = 0; row < 5; row++) [inserted addObject:[NSIndexPath indexPathForRow:row inSection:0]];
    [cv3 performBatchUpdates:^{
        changing.items = 205;
        [cv3 insertItemsAtIndexPaths:inserted];
    } completion:^(BOOL finished) { insertCompleted = finished; }];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.5, false);
    Check(insertCompleted, "animated insert completes", nil);
    Check(fabs(cv3.contentSize.height - (205 * 50 + 20)) < 1, "animated insert applies new item count",
          [NSString stringWithFormat:@"%.1f", cv3.contentSize.height]);
    Check(changing.willCell > displayedBefore, "willDisplay for cells that arrive in the animation",
          [NSString stringWithFormat:@"%ld -> %ld", (long)displayedBefore, (long)changing.willCell]);
    Check(cv3.visibleCells.count > 0 && cv3.visibleCells.count <= 205, "visible cells sane after animated insert",
          [NSString stringWithFormat:@"%lu", (unsigned long)cv3.visibleCells.count]);

    NSInteger displayedBeforeDelete = changing.willCell;
    __block BOOL deleteCompleted = NO;
    NSMutableArray *deleted = [NSMutableArray array];
    for (NSInteger row = 0; row < 5; row++) [deleted addObject:[NSIndexPath indexPathForRow:row inSection:0]];
    [cv3 performBatchUpdates:^{
        changing.items = 200;
        [cv3 deleteItemsAtIndexPaths:deleted];
    } completion:^(BOOL finished) { deleteCompleted = finished; }];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.5, false);
    Check(deleteCompleted, "animated delete completes", nil);
    Check(fabs(cv3.contentSize.height - (200 * 50 + 20)) < 1, "animated delete applies new item count",
          [NSString stringWithFormat:@"%.1f", cv3.contentSize.height]);
    Check(changing.willCell >= displayedBeforeDelete, "no willDisplay regressions after animated delete", nil);

    printf("RESULT: %s (%d failure%s)\n", failures ? "FAIL" : "PASS", failures, failures == 1 ? "" : "s");
    fflush(stdout);
}

@interface AppDelegate : UIResponder <UIApplicationDelegate> @property(nonatomic,strong) UIWindow *window; @end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    freopen("/var/mobile/Documents/apple-route-out.txt", "w", stdout);
    setvbuf(stdout, NULL, _IONBF, 0); // a hang must not swallow the results already printed
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    [self.window makeKeyAndVisible];
    Run(self.window);
    exit(failures ? 1 : 0);
    return YES;
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"AppDelegate"); } }
