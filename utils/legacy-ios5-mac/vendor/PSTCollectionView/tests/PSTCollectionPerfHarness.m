//
//  PSTCollectionPerfHarness.m
//
//  Deterministic behavioural + counter harness for the vendored PST collection
//  runtime.  It is compiled for the iOS simulator (host toolchain) from the same
//  Objective-C sources that are built for armv7 iOS 5, then executed with
//  `simctl spawn`.  Nothing here is part of the shipped archive: the runtime
//  build only compiles *.m at the vendor root, so this tests/ directory is
//  ignored by build-collection-runtime.sh.
//
//  Usage:
//    harness record OUT.json
//    harness check GOLDEN.json OUT.json
//
//  The "scenarios" section is geometry-only (visible cells, frames, content size
//  and offset) and is byte-compared between the unmodified and modified runtime.
//  The "counters" section is informational and printed by the runner.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "PSTCollectionView.h"

#if __has_include("PSTCollectionViewStats.h")
#import "PSTCollectionViewStats.h"
#define PST_HARNESS_HAVE_STATS 1
#else
#define PST_HARNESS_HAVE_STATS 0
#endif

static NSString *const kHarnessCellIdentifier = @"harness-cell";

#pragma mark - Data source

@interface HarnessDataSource : NSObject <PSTCollectionViewDataSource>
@property (nonatomic, strong) NSMutableArray<NSNumber *> *sectionCounts;
@end

@implementation HarnessDataSource

- (NSInteger)numberOfSectionsInCollectionView:(PSTCollectionView *)collectionView {
    return (NSInteger)self.sectionCounts.count;
}

- (NSInteger)collectionView:(PSTCollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return [self.sectionCounts[(NSUInteger)section] integerValue];
}

- (PSTCollectionViewCell *)collectionView:(PSTCollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    PSTCollectionViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kHarnessCellIdentifier forIndexPath:indexPath];
    // Mirror what a real data source does: content is a pure function of the
    // index path, so reuse order can not change the rendered result.
    cell.tag = indexPath.section * 100000 + indexPath.row;
    return cell;
}

@end

#pragma mark - JSON helpers

static NSDictionary *PointJSON(CGPoint point) {
    return @{@"x" : @(point.x), @"y" : @(point.y)};
}

static NSDictionary *SizeJSON(CGSize size) {
    return @{@"w" : @(size.width), @"h" : @(size.height)};
}

static NSArray *SortedVisibleCellsJSON(PSTCollectionView *collectionView) {
    NSMutableArray *entries = [NSMutableArray array];
    for (PSTCollectionViewCell *cell in collectionView.visibleCells) {
        NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
        if (!indexPath) {
            indexPath = cell.layoutAttributes.indexPath;
        }
        if (!indexPath) continue;
        [entries addObject:@{
            @"section" : @(indexPath.section),
            @"row" : @(indexPath.row),
            @"center" : PointJSON(cell.center),
            @"size" : SizeJSON(cell.bounds.size),
            @"zPosition" : @(cell.layer.zPosition),
            @"alpha" : @(cell.alpha),
            @"hidden" : @(cell.hidden),
        }];
    }
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult section = [a[@"section"] compare:b[@"section"]];
        if (section != NSOrderedSame) return section;
        return [a[@"row"] compare:b[@"row"]];
    }];
    return entries;
}

// Snapshot of the geometry that must not change.
static NSDictionary *SnapshotJSON(PSTCollectionView *collectionView) {
    return @{
        @"contentSize" : SizeJSON(collectionView.contentSize),
        @"contentOffset" : PointJSON(collectionView.contentOffset),
        @"bounds" : SizeJSON(collectionView.bounds.size),
        @"sections" : @([collectionView numberOfSections]),
        @"visible" : SortedVisibleCellsJSON(collectionView),
    };
}

#pragma mark - Scenario building blocks

static PSTCollectionViewFlowLayout *MakeFlowLayout(CGSize itemSize, UIEdgeInsets sectionInset, CGFloat lineSpacing, CGFloat interitemSpacing, CGSize headerSize, CGSize footerSize) {
    PSTCollectionViewFlowLayout *layout = [PSTCollectionViewFlowLayout new];
    layout.itemSize = itemSize;
    layout.sectionInset = sectionInset;
    layout.minimumLineSpacing = lineSpacing;
    layout.minimumInteritemSpacing = interitemSpacing;
    layout.headerReferenceSize = headerSize;
    layout.footerReferenceSize = footerSize;
    return layout;
}

static PSTCollectionView *MakeCollectionView(NSArray<NSNumber *> *counts, PSTCollectionViewFlowLayout *layout, CGSize boundsSize, HarnessDataSource **outDataSource) {
    HarnessDataSource *dataSource = [HarnessDataSource new];
    dataSource.sectionCounts = [counts mutableCopy];

    PSTCollectionView *collectionView = [[PSTCollectionView alloc] initWithFrame:CGRectMake(0, 0, boundsSize.width, boundsSize.height)
                                                              collectionViewLayout:layout];
    collectionView.dataSource = dataSource;
    [collectionView registerClass:PSTCollectionViewCell.class forCellWithReuseIdentifier:kHarnessCellIdentifier];
    if (outDataSource) *outDataSource = dataSource;
    return collectionView;
}

// One full layout pass, as CoreAnimation would drive it.
static void LayoutPass(PSTCollectionView *collectionView) {
    [collectionView setNeedsLayout];
    [collectionView layoutIfNeeded];
}

#pragma mark - Scenario runner

@interface HarnessRecorder : NSObject
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *scenarios;
@end

@implementation HarnessRecorder

- (instancetype)init {
    if ((self = [super init])) {
        _scenarios = [NSMutableArray array];
    }
    return self;
}

- (NSMutableArray<NSDictionary *> *)beginScenario:(NSString *)name {
    NSMutableArray *steps = [NSMutableArray array];
    [self.scenarios addObject:@{@"name" : name, @"steps" : steps}];
#if PST_HARNESS_HAVE_STATS
    PSTCollectionViewStatsReset();
#endif
    return steps;
}

- (void)addStep:(NSMutableArray<NSDictionary *> *)steps label:(NSString *)label collectionView:(PSTCollectionView *)collectionView {
    [steps addObject:@{@"label" : label, @"snapshot" : SnapshotJSON(collectionView)}];
}

- (void)endScenario:(NSMutableArray<NSDictionary *> *)steps counters:(NSMutableDictionary *)counters {
    (void)steps;
#if PST_HARNESS_HAVE_STATS
    PSTCollectionViewStatsCounters stats = PSTCollectionViewStatsRead();
    NSString *name = self.scenarios.lastObject[@"name"];
    counters[name] = @{
        @"passes" : @(stats.passes),
        @"passesSkipped" : @(stats.passesSkipped),
        @"visibleCellsCreated" : @(stats.visibleCellsCreated),
        @"attributesComputed" : @(stats.attributesComputed),
        @"elementScans" : @(stats.elementScans),
        @"itemDerivations" : @(stats.itemDerivations),
        @"itemDerivationsCached" : @(stats.itemDerivationsCached),
        @"layoutPreparations" : @(stats.layoutPreparations),
        @"layoutPreparationReuses" : @(stats.layoutPreparationReuses),
        @"itemCountScanSteps" : @(stats.itemCountScanSteps),
        @"dataValidations" : @(stats.dataValidations),
        @"dataRefilters" : @(stats.dataRefilters),
        @"visibleAttributeApplications" : @(stats.visibleAttributeApplications),
        @"layoutPassNanoseconds" : @(stats.layoutPassNanoseconds),
        @"layoutAttributeDiffs" : @(stats.layoutAttributeDiffs),
    };
#else
    (void)counters;
#endif
}

@end

#pragma mark - Scenarios

static void RunScenarios(NSArray<NSNumber *> *counts,
                         PSTCollectionViewFlowLayout *layout,
                         CGSize boundsSize,
                         NSString *name,
                         HarnessRecorder *recorder,
                         NSMutableDictionary *counters,
                         void (^stepsBlock)(PSTCollectionView *, NSMutableArray *)) {
    HarnessDataSource *dataSource = nil;
    PSTCollectionView *cv = MakeCollectionView(counts, layout, boundsSize, &dataSource);
    NSMutableArray *steps = [recorder beginScenario:name];
    LayoutPass(cv);
    [recorder addStep:steps label:@"initial" collectionView:cv];
    stepsBlock(cv, steps);
    [recorder endScenario:steps counters:counters];
}

static void RunAllScenarios(HarnessRecorder *recorder, NSMutableDictionary *counters) {
    const CGSize kBounds = {320.f, 568.f};
    const UIEdgeInsets kInset = {5.f, 5.f, 5.f, 5.f};

    // 1. Initial layout of a tall grid.
    RunScenarios(@[@2000],
                 MakeFlowLayout(CGSizeMake(50, 50), kInset, 10, 10, CGSizeZero, CGSizeZero),
                 kBounds, @"initial", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {});

    // 2. Repeated layout passes with nothing changing (steady state).
    RunScenarios(@[@2000],
                 MakeFlowLayout(CGSizeMake(50, 50), kInset, 10, 10, CGSizeZero, CGSizeZero),
                 kBounds, @"steady-layout-x8", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     for (int i = 0; i < 8; i++) {
                         if (i == 0 || i == 7) {
                             LayoutPass(cv);
                             [steps addObject:@{@"label" : [NSString stringWithFormat:@"pass-%d", i], @"snapshot" : SnapshotJSON(cv)}];
                         } else {
                             LayoutPass(cv);
                         }
                     }
                 });

    // 3. Scrolling down and back up: the visible attribute set and cells churn.
    NSArray<NSNumber *> *offsets = @[@0, @37, @111, @260, @500, @750, @1000, @1500, @2000, @3000, @4200, @2500, @900, @0];
    RunScenarios(@[@2000],
                 MakeFlowLayout(CGSizeMake(50, 50), kInset, 10, 10, CGSizeZero, CGSizeZero),
                 kBounds, @"scroll", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     for (NSNumber *offset in offsets) {
                         cv.contentOffset = CGPointMake(0, offset.doubleValue);
                         LayoutPass(cv);
                         [steps addObject:@{@"label" : [NSString stringWithFormat:@"offset-%@", offset], @"snapshot" : SnapshotJSON(cv)}];
                     }
                 });

    // 4. Horizontal scrolling with a horizontal flow layout.
    RunScenarios(@[@400],
                 ({ PSTCollectionViewFlowLayout *l = MakeFlowLayout(CGSizeMake(40, 50), kInset, 8, 12, CGSizeZero, CGSizeZero);
                    l.scrollDirection = PSTCollectionViewScrollDirectionHorizontal; l; }),
                 kBounds, @"scroll-horizontal", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     for (NSNumber *offset in @[@0, @123, @456, @890, @1500, @0]) {
                         cv.contentOffset = CGPointMake(offset.doubleValue, 0);
                         LayoutPass(cv);
                         [steps addObject:@{@"label" : [NSString stringWithFormat:@"offset-%@", offset], @"snapshot" : SnapshotJSON(cv)}];
                     }
                 });

    // 5. Reload with unchanged data.
    RunScenarios(@[@500],
                 MakeFlowLayout(CGSizeMake(50, 50), kInset, 10, 10, CGSizeZero, CGSizeZero),
                 kBounds, @"reload-same-data", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     [cv reloadData];
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"after-reload" collectionView:cv];
                     [cv reloadData];
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"after-second-reload" collectionView:cv];
                 });

    // 6. Insert / delete / reload rows through the update machinery.
    RunScenarios(@[@200],
                 MakeFlowLayout(CGSizeMake(50, 50), kInset, 10, 10, CGSizeZero, CGSizeZero),
                 kBounds, @"batch-updates", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     HarnessDataSource *dataSource = (HarnessDataSource *)cv.dataSource;
                     cv.contentOffset = CGPointMake(0, 400);
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"before-updates" collectionView:cv];

                     [cv performBatchUpdates:^{
                         NSMutableArray *inserts = [NSMutableArray array];
                         for (NSInteger row = 200; row < 205; row++) {
                             [dataSource.sectionCounts replaceObjectAtIndex:0 withObject:@([dataSource.sectionCounts[0] integerValue] + 1)];
                             [inserts addObject:[NSIndexPath indexPathForRow:row inSection:0]];
                         }
                         [cv insertItemsAtIndexPaths:inserts];
                     } completion:nil];
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"after-insert" collectionView:cv];

                     [cv performBatchUpdates:^{
                         NSMutableArray *deletes = [NSMutableArray array];
                         for (NSInteger row = 0; row < 5; row++) {
                             [dataSource.sectionCounts replaceObjectAtIndex:0 withObject:@([dataSource.sectionCounts[0] integerValue] - 1)];
                             [deletes addObject:[NSIndexPath indexPathForRow:row inSection:0]];
                         }
                         [cv deleteItemsAtIndexPaths:deletes];
                     } completion:nil];
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"after-delete" collectionView:cv];

                     [cv performBatchUpdates:^{
                         [cv reloadItemsAtIndexPaths:@[[NSIndexPath indexPathForRow:20 inSection:0],
                                                       [NSIndexPath indexPathForRow:21 inSection:0]]];
                     } completion:nil];
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"after-reload-items" collectionView:cv];
                 });

    // 7. Item size change: the geometry must be rebuilt from scratch.
    RunScenarios(@[@600],
                 MakeFlowLayout(CGSizeMake(50, 50), kInset, 10, 10, CGSizeZero, CGSizeZero),
                 kBounds, @"item-size-change", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     PSTCollectionViewFlowLayout *layout = (PSTCollectionViewFlowLayout *)cv.collectionViewLayout;
                     cv.contentOffset = CGPointMake(0, 300);
                     LayoutPass(cv);
                     layout.itemSize = CGSizeMake(80, 40);
                     [layout invalidateLayout];
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"after-item-size" collectionView:cv];
                     layout.itemSize = CGSizeMake(50, 50);
                     [layout invalidateLayout];
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"restored-item-size" collectionView:cv];
                 });

    // 8. Section inset change (the setter invalidates the layout itself).
    RunScenarios(@[@600],
                 MakeFlowLayout(CGSizeMake(50, 50), kInset, 10, 10, CGSizeZero, CGSizeZero),
                 kBounds, @"section-inset-change", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     PSTCollectionViewFlowLayout *layout = (PSTCollectionViewFlowLayout *)cv.collectionViewLayout;
                     cv.contentOffset = CGPointMake(0, 600);
                     LayoutPass(cv);
                     layout.sectionInset = UIEdgeInsetsMake(24, 12, 24, 12);
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"after-inset" collectionView:cv];
                 });

    // 9. Multiple sections with headers and footers.
    RunScenarios(@[@100, @250, @50],
                 MakeFlowLayout(CGSizeMake(60, 40), kInset, 6, 6, CGSizeMake(0, 30), CGSizeMake(0, 20)),
                 kBounds, @"multi-section", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     for (NSNumber *offset in @[@0, @700, @1500, @2600]) {
                         cv.contentOffset = CGPointMake(0, offset.doubleValue);
                         LayoutPass(cv);
                         [steps addObject:@{@"label" : [NSString stringWithFormat:@"offset-%@", offset], @"snapshot" : SnapshotJSON(cv)}];
                     }
                 });

    // 10. Layout switch: exercises the diff/interchange path.
    RunScenarios(@[@800],
                 MakeFlowLayout(CGSizeMake(50, 50), kInset, 10, 10, CGSizeZero, CGSizeZero),
                 kBounds, @"layout-switch", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     cv.contentOffset = CGPointMake(0, 900);
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"before-switch" collectionView:cv];
                     PSTCollectionViewFlowLayout *second = MakeFlowLayout(CGSizeMake(30, 30), UIEdgeInsetsMake(8, 8, 8, 8), 4, 4, CGSizeZero, CGSizeZero);
                     [cv setCollectionViewLayout:second animated:NO];
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"after-switch" collectionView:cv];
                 });

    // 11. Bounds size change.
    RunScenarios(@[@800],
                 MakeFlowLayout(CGSizeMake(50, 50), kInset, 10, 10, CGSizeZero, CGSizeZero),
                 kBounds, @"bounds-change", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     cv.frame = CGRectMake(0, 0, 375, 667);
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"after-width-change" collectionView:cv];
                     cv.frame = CGRectMake(0, 0, 320, 480);
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"after-restore" collectionView:cv];
                 });

    // 12. Many sections: exercises the section-offset bookkeeping in the update
    //     machinery (global index <-> index path lookups for every item).
    NSMutableArray<NSNumber *> *manyCounts = [NSMutableArray array];
    for (NSInteger i = 0; i < 120; i++) {
        [manyCounts addObject:@(10 + (i % 7))];
    }
    RunScenarios(manyCounts,
                 MakeFlowLayout(CGSizeMake(50, 50), kInset, 10, 10, CGSizeMake(0, 24), CGSizeMake(0, 16)),
                 kBounds, @"many-sections-updates", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     HarnessDataSource *dataSource = (HarnessDataSource *)cv.dataSource;
                     cv.contentOffset = CGPointMake(0, 2200);
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"before-updates" collectionView:cv];

                     [cv performBatchUpdates:^{
                         NSMutableArray *inserts = [NSMutableArray array];
                         for (NSInteger row = 10; row < 13; row++) {
                             [dataSource.sectionCounts replaceObjectAtIndex:60 withObject:@([dataSource.sectionCounts[60] integerValue] + 1)];
                             [inserts addObject:[NSIndexPath indexPathForRow:row inSection:60]];
                         }
                         [cv insertItemsAtIndexPaths:inserts];

                         NSMutableArray *deletes = [NSMutableArray array];
                         for (NSInteger row = 0; row < 3; row++) {
                             [dataSource.sectionCounts replaceObjectAtIndex:30 withObject:@([dataSource.sectionCounts[30] integerValue] - 1)];
                             [deletes addObject:[NSIndexPath indexPathForRow:row inSection:30]];
                         }
                         [cv deleteItemsAtIndexPaths:deletes];

                         [cv reloadItemsAtIndexPaths:@[[NSIndexPath indexPathForRow:4 inSection:80],
                                                       [NSIndexPath indexPathForRow:5 inSection:80]]];
                     } completion:nil];
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"after-updates" collectionView:cv];

                     for (NSNumber *offset in @[@2600, @3400, @500]) {
                         cv.contentOffset = CGPointMake(0, offset.doubleValue);
                         LayoutPass(cv);
                         [steps addObject:@{@"label" : [NSString stringWithFormat:@"offset-%@", offset], @"snapshot" : SnapshotJSON(cv)}];
                     }
                 });

    // 13. Explicit invalidation with unchanged geometry: the flow layout must
    //     not rebuild every section/row just because invalidateLayout was called.
    RunScenarios(@[@2000],
                 MakeFlowLayout(CGSizeMake(50, 50), kInset, 10, 10, CGSizeZero, CGSizeZero),
                 kBounds, @"invalidate-no-change", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     PSTCollectionViewFlowLayout *layout = (PSTCollectionViewFlowLayout *)cv.collectionViewLayout;
                     cv.contentOffset = CGPointMake(0, 1200);
                     LayoutPass(cv);
                     [recorder addStep:steps label:@"before-invalidations" collectionView:cv];
                     for (int i = 0; i < 5; i++) {
                         [layout invalidateLayout];
                         LayoutPass(cv);
                     }
                     [recorder addStep:steps label:@"after-invalidations" collectionView:cv];
                 });

    // 14. Long scroll with a partially visible grid and cells entering/leaving.
    RunScenarios(@[@5000],
                 MakeFlowLayout(CGSizeMake(64, 44), UIEdgeInsetsMake(10, 10, 10, 10), 8, 8, CGSizeMake(0, 24), CGSizeZero),
                 kBounds, @"long-scroll", recorder, counters,
                 ^(PSTCollectionView *cv, NSMutableArray *steps) {
                     for (NSInteger i = 0; i <= 20; i++) {
                         cv.contentOffset = CGPointMake(0, (CGFloat)i * 731.0);
                         LayoutPass(cv);
                         if (i % 5 == 0 || i == 20) {
                             [steps addObject:@{@"label" : [NSString stringWithFormat:@"offset-%ld", (long)i], @"snapshot" : SnapshotJSON(cv)}];
                         }
                     }
                 });
}

#pragma mark - Main

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: %s record OUT.json | check GOLDEN.json OUT.json\n", argv[0]);
            return 64;
        }
        NSString *mode = [NSString stringWithUTF8String:argv[1]];
        NSString *goldenPath = nil;
        NSString *outPath = nil;
        if ([mode isEqualToString:@"record"]) {
            outPath = [NSString stringWithUTF8String:argv[2]];
        } else if ([mode isEqualToString:@"check"] && argc >= 4) {
            goldenPath = [NSString stringWithUTF8String:argv[2]];
            outPath = [NSString stringWithUTF8String:argv[3]];
        } else {
            fprintf(stderr, "usage: %s record OUT.json | check GOLDEN.json OUT.json\n", argv[0]);
            return 64;
        }

        HarnessRecorder *recorder = [HarnessRecorder new];
        NSMutableDictionary *counters = [NSMutableDictionary dictionary];
        RunAllScenarios(recorder, counters);

        NSDictionary *payload = @{
            @"format" : @"pst-collection-perf-v1",
            @"scenarios" : recorder.scenarios,
            @"counters" : counters,
        };
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                       options:(NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys)
                                                         error:&error];
        if (!data) {
            fprintf(stderr, "serialization failed: %s\n", error.localizedDescription.UTF8String);
            return 70;
        }
        if (![data writeToFile:outPath options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "write failed: %s\n", error.localizedDescription.UTF8String);
            return 70;
        }

        if ([mode isEqualToString:@"record"]) {
            fprintf(stderr, "recorded %lu scenarios to %s\n",
                    (unsigned long)recorder.scenarios.count, outPath.UTF8String);
            return 0;
        }

        NSData *goldenData = [NSData dataWithContentsOfFile:goldenPath];
        if (!goldenData) {
            fprintf(stderr, "cannot read golden file %s\n", goldenPath.UTF8String);
            return 66;
        }
        NSDictionary *golden = [NSJSONSerialization JSONObjectWithData:goldenData options:0 error:&error];
        if (!golden) {
            fprintf(stderr, "cannot parse golden file: %s\n", error.localizedDescription.UTF8String);
            return 66;
        }
        NSData *goldenGeometry = [NSJSONSerialization dataWithJSONObject:golden[@"scenarios"]
                                                                 options:(NSJSONWritingSortedKeys)
                                                                   error:&error];
        NSData *actualGeometry = [NSJSONSerialization dataWithJSONObject:recorder.scenarios
                                                                options:(NSJSONWritingSortedKeys)
                                                                  error:&error];
        if (!goldenGeometry || !actualGeometry) {
            fprintf(stderr, "comparison serialization failed\n");
            return 70;
        }
        if (![goldenGeometry isEqualToData:actualGeometry]) {
            fprintf(stderr, "FAIL: visible cells/frames/content geometry differs from golden file\n");
            fprintf(stderr, "golden: %s\n", goldenPath.UTF8String);
            return 1;
        }
        fprintf(stderr, "PASS: %lu scenarios match golden geometry (%s)\n",
                (unsigned long)recorder.scenarios.count, goldenPath.UTF8String);
        return 0;
    }
}
