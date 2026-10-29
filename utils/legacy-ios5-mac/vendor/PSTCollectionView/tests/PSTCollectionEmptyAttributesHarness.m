// Focused differential regression: layout attributes disappear without data changes.
// Simulator-only; deliberately uses public APIs and does not patch either runtime.
#import <UIKit/UIKit.h>
#import "PSTCollectionView.h"

@interface EmptyMetrics : NSObject
@property NSUInteger created, requested, ended, prepared;
@end
@implementation EmptyMetrics
@end
static EmptyMetrics *currentMetrics;

// Identical layout/data-source/cell behavior for both engines. Three stable items,
// constant content size, no reload/batch update/scroll/animation during transition.
#define DEFINE_ENGINE(PREFIX, CV, LAYOUT, ATTR, CELL, DS, DELEGATE) \
@interface PREFIX##Cell : CELL \
@property (nonatomic, strong) EmptyMetrics *metrics; \
@end \
@implementation PREFIX##Cell \
- (instancetype)initWithFrame:(CGRect)frame { \
    if ((self = [super initWithFrame:frame])) { self.metrics = currentMetrics; self.metrics.created++; } \
    return self; \
} \
- (void)prepareForReuse { [super prepareForReuse]; self.metrics.prepared++; } \
@end \
@interface PREFIX##Layout : LAYOUT \
@property BOOL empty; \
@property NSUInteger queries; \
@end \
@implementation PREFIX##Layout \
- (CGSize)collectionViewContentSize { return CGSizeMake(240, 240); } \
- (ATTR *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)path { \
    if (self.empty) return nil; \
    ATTR *a = [ATTR layoutAttributesForCellWithIndexPath:path]; \
    a.frame = CGRectMake(10, 10 + path.item * 60, 100, 50); return a; \
} \
- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect { \
    self.queries++; \
    if (self.empty) return @[]; \
    NSMutableArray *result = [NSMutableArray array]; \
    for (NSInteger i = 0; i < 3; i++) { \
        ATTR *a = [self layoutAttributesForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]]; \
        if (CGRectIntersectsRect(rect, a.frame)) [result addObject:a]; \
    } \
    return result; \
} \
@end \
@interface PREFIX##Source : NSObject <DS, DELEGATE> \
@property (nonatomic, strong) EmptyMetrics *metrics; \
@end \
@implementation PREFIX##Source \
- (NSInteger)collectionView:(CV *)view numberOfItemsInSection:(NSInteger)section { return 3; } \
- (CELL *)collectionView:(CV *)view cellForItemAtIndexPath:(NSIndexPath *)path { \
    self.metrics.requested++; \
    CELL *cell = [view dequeueReusableCellWithReuseIdentifier:@"cell" forIndexPath:path]; \
    cell.tag = path.item + 1; return cell; \
} \
- (void)collectionView:(CV *)view didEndDisplayingCell:(CELL *)cell forItemAtIndexPath:(NSIndexPath *)path { \
    self.metrics.ended++; \
} \
@end
DEFINE_ENGINE(NativeEmpty, UICollectionView, UICollectionViewLayout, UICollectionViewLayoutAttributes, UICollectionViewCell, UICollectionViewDataSource, UICollectionViewDelegate)
DEFINE_ENGINE(PSTEmpty, PSTCollectionView, PSTCollectionViewLayout, PSTCollectionViewLayoutAttributes, PSTCollectionViewCell, PSTCollectionViewDataSource, PSTCollectionViewDelegate)

static void CollectCellSubviews(UIView *view, Class cellClass, BOOL ancestorHidden, NSMutableArray *cells) {
    for (UIView *child in view.subviews) {
        BOOL hidden = ancestorHidden || child.hidden || child.alpha == 0;
        if ([child isKindOfClass:cellClass]) {
            [cells addObject:@{@"tag": @(child.tag), @"hidden": @(child.hidden),
                @"alpha": @(child.alpha), @"effectivelyHidden": @(hidden)}];
        }
        CollectCellSubviews(child, cellClass, hidden, cells);
    }
}
static NSDictionary *Snapshot(NSString *step, id view, Class cellClass, EmptyMetrics *m, NSUInteger queries) {
    NSMutableArray *tags = [NSMutableArray array];
    for (UIView *cell in [view visibleCells]) [tags addObject:@(cell.tag)];
    [tags sortUsingSelector:@selector(compare:)];
    NSMutableArray *subviews = [NSMutableArray array];
    CollectCellSubviews(view, cellClass, NO, subviews);
    [subviews sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"tag"] compare:b[@"tag"]]; }];
    NSUInteger displayed = 0;
    for (NSDictionary *cell in subviews) if (![cell[@"effectivelyHidden"] boolValue]) displayed++;
    return @{ @"step": step, @"visible": tags, @"cellSubviews": @(subviews.count),
              @"cellSubviewDetails": subviews, @"displayedCellSubviews": @(displayed),
              @"created": @(m.created), @"requested": @(m.requested), @"ended": @(m.ended),
              @"prepared": @(m.prepared), @"attributeQueries": @(queries) };
}
static void Layout(UIView *view) { [view setNeedsLayout]; [view layoutIfNeeded]; }

#define RUN_ENGINE(PREFIX, CV) \
static NSArray *Run##PREFIX(void) { \
    EmptyMetrics *m = [EmptyMetrics new]; currentMetrics = m; \
    PREFIX##Layout *layout = [PREFIX##Layout new]; \
    PREFIX##Source *source = [PREFIX##Source new]; source.metrics = m; \
    CV *view = [[CV alloc] initWithFrame:CGRectMake(0, 0, 240, 240) collectionViewLayout:layout]; \
    view.dataSource = source; view.delegate = source; \
    [view registerClass:PREFIX##Cell.class forCellWithReuseIdentifier:@"cell"]; \
    NSMutableArray *steps = [NSMutableArray array]; \
    Layout(view); \
    [steps addObject:Snapshot(@"initial", view, PREFIX##Cell.class, m, layout.queries)]; \
    layout.empty = YES; [layout invalidateLayout]; Layout(view); \
    [steps addObject:Snapshot(@"empty-invalidated", view, PREFIX##Cell.class, m, layout.queries)]; \
    for (NSUInteger i = 1; i <= 3; i++) { \
        Layout(view); \
        [steps addObject:Snapshot([NSString stringWithFormat:@"empty-repeat-%lu", (unsigned long)i], view, PREFIX##Cell.class, m, layout.queries)]; \
    } \
    layout.empty = NO; [layout invalidateLayout]; Layout(view); \
    [steps addObject:Snapshot(@"restored", view, PREFIX##Cell.class, m, layout.queries)]; \
    Layout(view); \
    [steps addObject:Snapshot(@"restored-repeat", view, PREFIX##Cell.class, m, layout.queries)]; \
    view.delegate = nil; view.dataSource = nil; currentMetrics = nil; \
    return steps; \
}
RUN_ENGINE(NativeEmpty, UICollectionView)
RUN_ENGINE(PSTEmpty, PSTCollectionView)

static void Check(BOOL condition, NSString *message, NSMutableArray *failures) {
    if (!condition) { [failures addObject:message]; fprintf(stderr, "FAIL: %s\n", message.UTF8String); }
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: harness NEW-result.json\n"); return 64; }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return 73;
        [UIView setAnimationsEnabled:NO];
        NSArray *native = RunNativeEmpty();
        NSArray *pst = RunPSTEmpty();
        NSMutableArray *failures = [NSMutableArray array];
        // Verify native is a useful oracle, not an all-empty headless false pass.
        Check([native[0][@"visible"] isEqual:@[@1,@2,@3]], @"native initially displays all three cells", failures);
        Check([native[0][@"cellSubviews"] unsignedIntegerValue] == 3, @"native initially attaches three actual cells", failures);
        Check([native[1][@"visible"] count] == 0,
              @"native reports no visible cells after empty-attributes invalidation", failures);
        // Native may keep hidden reusable cells attached; record actual hierarchy
        // separately instead of asserting a private caching policy.
        Check([native[1][@"displayedCellSubviews"] unsignedIntegerValue] == 0,
              @"native has no displayed cell subviews after invalidation", failures);
        Check([native[1][@"ended"] unsignedIntegerValue] == 3, @"native emits three end-display callbacks", failures);
        Check([native[5][@"visible"] isEqual:@[@1,@2,@3]], @"native restores all three cells", failures);
        Check([native[5][@"prepared"] unsignedIntegerValue] >= 3, @"native prepares cells for reuse by restoration", failures);
        Check([native[1][@"attributeQueries"] unsignedIntegerValue] > [native[0][@"attributeQueries"] unsignedIntegerValue],
              @"native re-queries layout after invalidation", failures);
        Check([pst[1][@"attributeQueries"] unsignedIntegerValue] > [pst[0][@"attributeQueries"] unsignedIntegerValue],
              @"PST re-queries layout after invalidation", failures);
        for (NSUInteger i = 0; i < native.count; i++) {
            // Reuse callback timing is observable API behavior, not just a final
            // count: native prepares on dequeue, never merely on end-display.
            for (NSString *key in @[@"visible", @"displayedCellSubviews", @"created", @"requested", @"ended", @"prepared"]) {
                Check([native[i][key] isEqual:pst[i][key]],
                      [NSString stringWithFormat:@"%@: %@ native=%@ PST=%@", native[i][@"step"], key, native[i][key], pst[i][key]], failures);
            }
        }
        for (NSUInteger i = 5; i < native.count; i++) {
            Check([native[i][@"prepared"] isEqual:pst[i][@"prepared"]],
                  [NSString stringWithFormat:@"%@: reuse count native=%@ PST=%@", native[i][@"step"], native[i][@"prepared"], pst[i][@"prepared"]], failures);
        }
        NSDictionary *payload = @{ @"format": @"pst-empty-attributes-v1", @"nativeSystemVersion": UIDevice.currentDevice.systemVersion,
            @"nativeOSVersion": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"simulatorUDID": NSProcessInfo.processInfo.environment[@"SIMULATOR_UDID"] ?: @"unknown",
            @"native": native, @"pst": pst, @"failures": failures, @"passed": @(failures.count == 0) };
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
        if (!data || ![data writeToFile:path options:NSDataWritingWithoutOverwriting error:&error]) {
            fprintf(stderr, "cannot write result: %s\n", error.description.UTF8String); return 74;
        }
        fprintf(stderr, "%s: native iOS %s (%s); %lu comparison failures\n", failures.count ? "RED" : "PASS",
                UIDevice.currentDevice.systemVersion.UTF8String, NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String,
                (unsigned long)failures.count);
        return failures.count ? 1 : 0;
    }
}
