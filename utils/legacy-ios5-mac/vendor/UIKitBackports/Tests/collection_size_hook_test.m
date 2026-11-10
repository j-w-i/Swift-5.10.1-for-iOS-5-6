// Focused hook test, not a substitute for the iOS 6/7 layout-engine device gate.
#import "../Runtime/UICCollectionViewDisplay.m"

@interface SizeHookLayout : UICollectionViewFlowLayout
@property(nonatomic) NSUInteger flagsRefreshes;
@end
@implementation SizeHookLayout
- (void)_updateDelegateFlags { self.flagsRefreshes++; }
@end

@interface SizeHookCollection : UICollectionView
@property(nonatomic, strong) id testDelegate;
@property(nonatomic, strong) SizeHookLayout *testLayout;
@end
@implementation SizeHookCollection
- (id)delegate { return self.testDelegate; }
- (UICollectionViewLayout *)collectionViewLayout { return self.testLayout; }
@end

@interface SharedSizeDelegate : NSObject @end
@implementation SharedSizeDelegate @end
@interface DerivedSizeDelegate : SharedSizeDelegate @end
@implementation DerivedSizeDelegate @end
@interface AppSizeDelegate : NSObject @end
@implementation AppSizeDelegate
- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)path {
    return CGSizeMake(31, 47);
}
@end

@interface DerivedAppSizeDelegate : AppSizeDelegate @end
@implementation DerivedAppSizeDelegate @end
@interface OverrideAppSizeDelegate : AppSizeDelegate @end
@implementation OverrideAppSizeDelegate
- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)path {
    CGSize base=[super collectionView:cv layout:layout sizeForItemAtIndexPath:path];
    return CGSizeMake(base.width+2,base.height+3);
}
@end

@interface ForwardingSizeDelegate : NSObject @end
@implementation ForwardingSizeDelegate
- (BOOL)respondsToSelector:(SEL)selector {
    return selector == @selector(collectionView:layout:sizeForItemAtIndexPath:) || [super respondsToSelector:selector];
}
@end

@interface CancelSource : NSObject
@property(nonatomic) NSUInteger calls;
@property(nonatomic,strong) NSArray *cancelled;
@end
@implementation CancelSource
- (void)collectionView:(id)cv cancelPrefetchingForItemsAtIndexPaths:(NSArray *)paths {
    self.calls++; self.cancelled=paths;
    UICSetPrefetchingEnabled(cv, NULL, NO); // reentrant disable must not duplicate
}
@end

static void require(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static SizeHookCollection *collection(id delegate) {
    SizeHookCollection *cv = [[SizeHookCollection alloc] initWithFrame:CGRectZero collectionViewLayout:[SizeHookLayout new]];
    cv.testLayout = [SizeHookLayout new];
    cv.testDelegate = delegate;
    return cv;
}
int main(void) { @autoreleasepool {
    Class cvClass = [UICollectionView class], flowClass = [UICollectionViewFlowLayout class];
    SEL selectors[] = { @selector(layoutSubviews), @selector(reloadData), @selector(prefetchDataSource) };
    IMP native[3];
    for (int i = 0; i < 3; i++) native[i] = class_getMethodImplementation(cvClass, selectors[i]);
    IMP nativeInvalidate = class_getMethodImplementation(flowClass, @selector(invalidateLayout));
    IMP nativeEstimate = class_getMethodImplementation(flowClass, @selector(estimatedItemSize));
    UICInstallCollectionViewDisplay();
    for (int i = 0; i < 3; i++) require(native[i] == class_getMethodImplementation(cvClass, selectors[i]), @"native collection IMP unchanged");
    require(nativeEstimate == class_getMethodImplementation(flowClass, @selector(estimatedItemSize)), @"native self-sizing IMP unchanged");
    UICollectionViewFlowLayout *automatic = [UICollectionViewFlowLayout new];
    automatic.itemSize = CGSizeMake(77, 33);
    UICEstimatedItemSizeSetter(automatic, NULL, CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX));
    require(CGSizeEqualToSize(UICEstimatedItemSizeGetter(automatic, NULL), CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)), @"automatic sentinel getter preserved");
    require(CGSizeEqualToSize(UICSizeForItem(automatic, [NSIndexPath indexPathForItem:0 inSection:0]), CGSizeMake(50, 50)), @"automatic estimate normalized");
    require(nativeInvalidate == class_getMethodImplementation(flowClass, @selector(invalidateLayout)), @"native invalidate IMP unchanged");
    NSIndexPath *measuredPath = [NSIndexPath indexPathForItem:0 inSection:0];
    objc_setAssociatedObject(automatic, &UICStableKey, [NSMutableSet setWithObject:measuredPath], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(automatic, &UICMeasuredKey, [NSMutableDictionary dictionaryWithObject:[NSValue valueWithCGSize:CGSizeMake(80,60)] forKey:measuredPath], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UICOriginalInvalidateFlowLayout = nativeInvalidate;
    UICInvalidateFlowLayout(automatic, @selector(invalidateLayout));
    require([(NSSet *)objc_getAssociatedObject(automatic, &UICStableKey) count] == 0, @"invalidation removes stability");
    require(CGSizeEqualToSize(UICSizeForItem(automatic, measuredPath), CGSizeMake(80,60)), @"invalidation retains measured estimate");
    SharedSizeDelegate *delegate = [SharedSizeDelegate new];
    SizeHookCollection *first = collection(delegate), *second = collection(delegate);
    require(UICInstallSizeHook(first), @"first collection installs shim");
    require(first.testLayout.flagsRefreshes == 1, @"first layout refreshes flags");
    require(!UICInstallSizeHook(second), @"second collection reuses shim");
    require(second.testLayout.flagsRefreshes == 1, @"second layout refreshes cached flags too");
    SizeHookCollection *derived = collection([DerivedSizeDelegate new]);
    UICInstallSizeHook(derived);
    require(derived.testLayout.flagsRefreshes == 1, @"inherited shim refreshes flags");
    SizeHookCollection *app = collection([AppSizeDelegate new]);
    SEL selector = @selector(collectionView:layout:sizeForItemAtIndexPath:);
    IMP original = [app.testDelegate methodForSelector:selector];
    require(UICInstallSizeHook(app), @"app method wrapped");
    require([app.testDelegate methodForSelector:selector] != original, @"app wrapper installed");
    CGSize (*answer)(id,SEL,id,id,id)=(void *)[app.testDelegate methodForSelector:selector];
    require(CGSizeEqualToSize(answer(app.testDelegate,selector,app,app.testLayout,measuredPath),CGSizeMake(31,47)), @"zero estimates preserve original app answer");
    UICEstimatedItemSizeSetter(app.testLayout,NULL,CGSizeMake(50,50));
    require(CGSizeEqualToSize(answer(app.testDelegate,selector,app,app.testLayout,measuredPath),CGSizeMake(31,47)), @"app answer seeds estimated sizing");
    objc_setAssociatedObject(app.testLayout,&UICMeasuredKey,[NSMutableDictionary dictionaryWithObject:[NSValue valueWithCGSize:CGSizeMake(80,99)] forKey:measuredPath],OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    require(CGSizeEqualToSize(answer(app.testDelegate,selector,app,app.testLayout,measuredPath),CGSizeMake(80,99)), @"measured answer overrides app seed");
    require(!UICInstallSizeHook(app), @"app wrapper not installed twice");
    require([app.testDelegate methodForSelector:selector] == (IMP)answer, @"wrapper remains identical");
    SizeHookCollection *inheritedApp=collection([DerivedAppSizeDelegate new]);
    require(!UICInstallSizeHook(inheritedApp), @"inherited app wrapper reused");
    require(inheritedApp.testLayout.flagsRefreshes==1, @"inherited app layout flags refreshed");
    require(CGSizeEqualToSize(answer(inheritedApp.testDelegate,selector,inheritedApp,inheritedApp.testLayout,measuredPath),CGSizeMake(31,47)), @"inherited original answer preserved without estimates");
    SizeHookCollection *overrideApp=collection([OverrideAppSizeDelegate new]);
    require(UICInstallSizeHook(overrideApp), @"override gets its own wrapper");
    CGSize (*overrideAnswer)(id,SEL,id,id,id)=(void *)[overrideApp.testDelegate methodForSelector:selector];
    require(CGSizeEqualToSize(overrideAnswer(overrideApp.testDelegate,selector,overrideApp,overrideApp.testLayout,measuredPath),CGSizeMake(33,50)), @"super-calling override preserved without estimates");
    UICEstimatedItemSizeSetter(overrideApp.testLayout,NULL,CGSizeMake(50,50));
    require(CGSizeEqualToSize(overrideAnswer(overrideApp.testDelegate,selector,overrideApp,overrideApp.testLayout,measuredPath),CGSizeMake(33,50)), @"super-calling override supplies estimate seed");
    SizeHookCollection *proxy = collection([ForwardingSizeDelegate new]);
    require(!UICInstallSizeHook(proxy), @"forwarding delegate not modified");
    require(class_getInstanceMethod([ForwardingSizeDelegate class], selector) == NULL, @"forwarding remains available");
    CancelSource *source=[CancelSource new];
    UICSetPrefetchDataSource(first, NULL, source);
    NSArray *paths=@[[NSIndexPath indexPathForItem:8 inSection:0], [NSIndexPath indexPathForItem:9 inSection:0]];
    objc_setAssociatedObject(first, &UICPrefetchSetKey, [NSMutableSet setWithArray:paths], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UICSetPrefetchingEnabled(first, NULL, NO);
    require(source.calls==1 && [source.cancelled isEqual:paths], @"disable cancels outstanding paths exactly once despite reentrancy");
    require(!UICIsPrefetchingEnabled(first,NULL), @"disable state updated before callback");
    UICSetPrefetchingEnabled(first,NULL,NO);
    require(source.calls==1, @"repeated disable does not cancel twice");
    UICSetPrefetchingEnabled(first,NULL,YES);
    objc_setAssociatedObject(first, &UICPrefetchSetKey, [NSMutableSet setWithArray:paths], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CancelSource *replacement=[CancelSource new];
    UICSetPrefetchDataSource(first,NULL,replacement);
    require(source.calls==1 && replacement.calls==0, @"replacement itself does not cancel");
    UICSetPrefetchingEnabled(first,NULL,NO);
    require(source.calls==1 && replacement.calls==1 && [replacement.cancelled isEqual:paths], @"disable delivers old outstanding paths to current source");
    puts("PASS: shared/inherited shims refresh each layout; app/forwarding sizing preserved; native IMPs unchanged; disabling prefetch cancels outstanding paths");
} return 0; }
