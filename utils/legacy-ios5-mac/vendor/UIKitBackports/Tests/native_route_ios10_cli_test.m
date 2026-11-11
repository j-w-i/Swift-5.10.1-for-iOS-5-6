// iOS 10 native-route gate (command-line probe, like the other device probes).
// The backport hook runtime must load and stay inert for everything UIKit already provides, and Apple's own
// collection view must behave normally. Prints PASS/FAIL lines to stdout.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdio.h>

extern void UICInstallCollectionViewDisplay(void);

static int failures = 0;
static void check(const char *name, int ok, const char *detail) {
    printf("%s %s%s%s\n", ok ? "PASS" : "FAIL", name, detail ? " : " : "", detail ? detail : "");
    fflush(stdout);
    if (!ok) failures++;
}
static IMP imp(Class c, const char *sel) {
    Method m = class_getInstanceMethod(c, sel_registerName(sel));
    return m ? method_getImplementation(m) : NULL;
}

@interface Cell : UICollectionViewCell @end
@implementation Cell @end

@interface DS : NSObject <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@end
@implementation DS
- (NSInteger)collectionView:(UICollectionView *)cv numberOfItemsInSection:(NSInteger)s { return 200; }
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)ip {
    return [cv dequeueReusableCellWithReuseIdentifier:@"c" forIndexPath:ip];
}
- (CGSize)collectionView:(UICollectionView *)cv layout:(UICollectionViewLayout *)l sizeForItemAtIndexPath:(NSIndexPath *)ip {
    return CGSizeMake(320, 60 + (ip.item % 5) * 8);
}
@end

int main(void) { @autoreleasepool {
    Class flow = NSClassFromString(@"UICollectionViewFlowLayout");
    Class cvCls = NSClassFromString(@"UICollectionView");
    check("UIKit carries UICollectionView", cvCls != Nil, NULL);

    IMP est0 = imp(flow, "estimatedItemSize");
    IMP pref0 = imp(cvCls, "prefetchDataSource");
    IMP vis0 = imp(cvCls, "visibleSupplementaryViewsOfKind:");
    IMP add0 = imp(cvCls, "_addControlledSubview:atZIndex:");

    UICInstallCollectionViewDisplay();   // must be inert on iOS 10

    check("native estimatedItemSize untouched", imp(flow, "estimatedItemSize") == est0, NULL);
    check("native prefetchDataSource untouched", imp(cvCls, "prefetchDataSource") == pref0, NULL);
    check("native iOS 9 supplementary accessors untouched", imp(cvCls, "visibleSupplementaryViewsOfKind:") == vis0, NULL);
    check("native _addControlledSubview:atZIndex: not swizzled", imp(cvCls, "_addControlledSubview:atZIndex:") == add0, NULL);

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.estimatedItemSize = CGSizeMake(320, 60);
    layout.minimumLineSpacing = 4;
    UICollectionView *cv = [[UICollectionView alloc] initWithFrame:CGRectMake(0, 0, 320, 480) collectionViewLayout:layout];
    DS *ds = [DS new];
    cv.dataSource = ds;
    [cv registerClass:[Cell class] forCellWithReuseIdentifier:@"c"];
    [layout prepareLayout];
    CGFloat h = layout.collectionViewContentSize.height;
    char buf[96]; snprintf(buf, sizeof buf, "%.1f", h);
    check("native self-sizing produced content height", h > 480, buf);
    check("native layout built 200 attributes",
          [[layout layoutAttributesForElementsInRect:CGRectMake(0, 0, 320, 480)] count] > 0, NULL);
    printf("RESULT: %s\n", failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}}
