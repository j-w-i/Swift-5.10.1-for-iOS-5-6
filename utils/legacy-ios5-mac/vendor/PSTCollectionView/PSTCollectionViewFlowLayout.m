//
//  PSTCollectionViewFlowLayout.m
//  PSPDFKit
//
//  Copyright (c) 2012-2013 Peter Steinberger. All rights reserved.
//

#import "PSTCollectionViewFlowLayout.h"
#import "PSTCollectionView.h"
#import "PSTGridLayoutItem.h"
#import "PSTGridLayoutInfo.h"
#import "PSTGridLayoutRow.h"
#import "PSTGridLayoutSection.h"
#import <objc/runtime.h>

#import "PSTCollectionViewStats.h"
#include <math.h>

NSString *const PSTCollectionElementKindSectionHeader = @"UICollectionElementKindSectionHeader";
NSString *const PSTCollectionElementKindSectionFooter = @"UICollectionElementKindSectionFooter";

// this is not exposed in UICollectionViewFlowLayout
NSString *const PSTFlowLayoutCommonRowHorizontalAlignmentKey = @"UIFlowLayoutCommonRowHorizontalAlignmentKey";
NSString *const PSTFlowLayoutLastRowHorizontalAlignmentKey = @"UIFlowLayoutLastRowHorizontalAlignmentKey";
NSString *const PSTFlowLayoutRowVerticalAlignmentKey = @"UIFlowLayoutRowVerticalAlignmentKey";

// Proposal for items no cell has reported on. UIKit proposes the running mean of the reported sizes, and after a
// preferred-size invalidation it applies the new mean from one row before the earliest invalidated item onward,
// keeping the earlier estimates. That is kept as a few breakpoints (first item, size), not a value per item.
typedef struct { NSInteger section, item; CGSize size; } PSTProposalRun;
static BOOL PSTProposalRunBefore(PSTProposalRun r, NSInteger section, NSInteger item) {
    return r.section < section || (r.section == section && r.item < item);
}
// Self-sizing origins are laid out on pixel boundaries and the content size in whole points; preferred sizes
// stay fractional.
static CGRect PSTPixelOrigin(CGRect r, CGFloat scale) {
    r.origin.x = round(r.origin.x * scale) / scale;
    r.origin.y = round(r.origin.y * scale) / scale;
    return r;
}

@implementation PSTCollectionViewFlowLayout {
    NSMutableData *_pstProposalRuns;
    NSUInteger _pstProposalRunCount;
    NSIndexPath *_pstEarliestChangedPath;        // earliest path whose preferred size changed since the last batch
    // class needs to have same iVar layout as UICollectionViewLayout
    struct {
        unsigned int delegateSizeForItem : 1;
        unsigned int delegateReferenceSizeForHeader : 1;
        unsigned int delegateReferenceSizeForFooter : 1;
        unsigned int delegateInsetForSection : 1;
        unsigned int delegateInteritemSpacingForSection : 1;
        unsigned int delegateLineSpacingForSection : 1;
        unsigned int delegateAlignmentOptions : 1;
        unsigned int keepDelegateInfoWhileInvalidating : 1;
        unsigned int keepAllDataWhileInvalidating : 1;
        unsigned int layoutDataIsValid : 1;
        unsigned int delegateInfoIsValid : 1;
    }_gridLayoutFlags;
    CGFloat _interitemSpacing;
    CGFloat _lineSpacing;
    CGSize _itemSize;
    CGSize _estimatedItemSize;
    NSMutableDictionary *_pstMeasuredItemSizes;    // NSIndexPath -> NSValue(CGSize): sizes the cells reported
    NSMutableDictionary *_pstStableMeasuredFrames; // NSIndexPath -> CGRect: confirmed proposal frame
    BOOL _pstPreservingStableMeasurements;        // internal size invalidation, not an app invalidation
    CGSize _pstMeasuredSizeSum;                    // sum and count of the cell-reported sizes: unmeasured
    NSUInteger _pstMeasuredSizeCount;              // running-mean proposals; stepped UIKit cache still differs
    CGSize _pstProposalAtLayout;                   // the mean frozen for the current layout pass
    CGSize _pstProposalAtLayout0;                  // the estimate itself, for sections nothing has been learned in
    CGSize _headerReferenceSize;
    CGSize _footerReferenceSize;
    UIEdgeInsets _sectionInset;
    PSTGridLayoutInfo *_data;
    CGSize _currentLayoutSize;
    NSMutableDictionary *_insertedItemsAttributesDict;
    NSMutableDictionary *_insertedSectionHeadersAttributesDict;
    NSMutableDictionary *_insertedSectionFootersAttributesDict;
    NSMutableDictionary *_deletedItemsAttributesDict;
    NSMutableDictionary *_deletedSectionHeadersAttributesDict;
    NSMutableDictionary *_deletedSectionFootersAttributesDict;
    PSTCollectionViewScrollDirection _scrollDirection;
    NSDictionary *_rowAlignmentsOptionsDictionary;
    CGRect _visibleBounds;
    // Prepared-generation token.  invalidateLayout only marks the layout dirty;
    // prepareLayout rebuilds every section/row only when one of these inputs
    // actually changed.  Dynamic delegate geometry can not be validated without
    // rebuilding, so it always forces a rebuild.
    CGSize _preparedBoundsSize;
    CGSize _preparedItemSize;
    CGSize _preparedHeaderReferenceSize;
    CGSize _preparedFooterReferenceSize;
    CGFloat _preparedLineSpacing;
    CGFloat _preparedInteritemSpacing;
    UIEdgeInsets _preparedSectionInset;
    PSTCollectionViewScrollDirection _preparedScrollDirection;
    NSDictionary *_preparedRowAlignmentsOptionsDictionary;
    NSMutableArray *_preparedSectionItemCounts;
    BOOL _preparedLayoutIsReusable;
    BOOL _needsPrepareLayout;
    BOOL _preserveGeometryForContext;
    BOOL _contextRequiresMetrics;
    char filler[200]; // [HACK] Our class needs to be larger than Apple's class for the superclass change to work.
}

@synthesize rowAlignmentOptions = _rowAlignmentsOptionsDictionary;
@synthesize minimumLineSpacing = _lineSpacing;
@synthesize minimumInteritemSpacing = _interitemSpacing;

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSObject

- (void)commonInit {
    _itemSize = CGSizeMake(50.f, 50.f);
    _lineSpacing = 10.f;
    _interitemSpacing = 10.f;
    _sectionInset = UIEdgeInsetsZero;
    _scrollDirection = PSTCollectionViewScrollDirectionVertical;
    _headerReferenceSize = CGSizeZero;
    _footerReferenceSize = CGSizeZero;
}

- (id)init {
    if ((self = [super init])) {
        [self commonInit];

        // set default values for row alignment.
        _rowAlignmentsOptionsDictionary = @{
                PSTFlowLayoutCommonRowHorizontalAlignmentKey : @(PSTFlowLayoutHorizontalAlignmentJustify),
                PSTFlowLayoutLastRowHorizontalAlignmentKey : @(PSTFlowLayoutHorizontalAlignmentJustify),
                // TODO: those values are some enum. find out what that is.
                PSTFlowLayoutRowVerticalAlignmentKey : @(1),
        };
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)decoder {
    if ((self = [super initWithCoder:decoder])) {
        [self commonInit];

        // Some properties are not set if they're default (like minimumInteritemSpacing == 10)
        if ([decoder containsValueForKey:@"UIItemSize"])
            self.itemSize = [decoder decodeCGSizeForKey:@"UIItemSize"];
        if ([decoder containsValueForKey:@"UIInteritemSpacing"])
            self.minimumInteritemSpacing = [decoder decodeFloatForKey:@"UIInteritemSpacing"];
        if ([decoder containsValueForKey:@"UILineSpacing"])
            self.minimumLineSpacing = [decoder decodeFloatForKey:@"UILineSpacing"];
        if ([decoder containsValueForKey:@"UIFooterReferenceSize"])
            self.footerReferenceSize = [decoder decodeCGSizeForKey:@"UIFooterReferenceSize"];
        if ([decoder containsValueForKey:@"UIHeaderReferenceSize"])
            self.headerReferenceSize = [decoder decodeCGSizeForKey:@"UIHeaderReferenceSize"];
        if ([decoder containsValueForKey:@"UISectionInset"])
            self.sectionInset = [decoder decodeUIEdgeInsetsForKey:@"UISectionInset"];
        if ([decoder containsValueForKey:@"UIScrollDirection"])
            self.scrollDirection = [decoder decodeIntegerForKey:@"UIScrollDirection"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [super encodeWithCoder:coder];
    [coder encodeCGSize:self.itemSize forKey:@"UIItemSize"];
    [coder encodeFloat:(float)self.minimumInteritemSpacing forKey:@"UIInteritemSpacing"];
    [coder encodeFloat:(float)self.minimumLineSpacing forKey:@"UILineSpacing"];
    [coder encodeCGSize:self.footerReferenceSize forKey:@"UIFooterReferenceSize"];
    [coder encodeCGSize:self.headerReferenceSize forKey:@"UIHeaderReferenceSize"];
    [coder encodeUIEdgeInsets:self.sectionInset forKey:@"UISectionInset"];
    [coder encodeInteger:self.scrollDirection forKey:@"UIScrollDirection"];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - PSTCollectionViewLayout

static char kPSTCachedItemRectsKey;

- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect {
    // Apple calls _layoutAttributesForItemsInRect
    if (!_data || _needsPrepareLayout) [self prepareLayout];

    // Packed (self-sizing) origins are rounded to pixels after layout, so rows that only touch the rect by less than a
    // pixel before rounding are still searched.
    const CGFloat pstScale = [UIScreen mainScreen].scale;
    BOOL pstAnyPacked = NO;
    for (PSTGridLayoutSection *s in _data.sections) if (s.packed) { pstAnyPacked = YES; break; }
    const CGRect pstSearch = pstAnyPacked ? CGRectInset(rect, -1 / pstScale, -1 / pstScale) : rect;
    NSMutableArray *layoutAttributesArray = [NSMutableArray array];
    NSUInteger pstSectionCursor = 0;
    for (PSTGridLayoutSection *section in _data.sections) {
        NSUInteger pstSectionIndex = pstSectionCursor++;
        if (CGRectIntersectsRect(section.frame, pstSearch)) {

            // if we have fixed size, calculate item frames only once.
            // this also uses the default PSTFlowLayoutCommonRowHorizontalAlignmentKey alignment
            // for the last row. (we want this effect!)
            NSMutableDictionary *rectCache = objc_getAssociatedObject(self, &kPSTCachedItemRectsKey);
            NSUInteger sectionIndex = pstSectionIndex;

            CGRect normalizedHeaderFrame = section.headerFrame;
            normalizedHeaderFrame.origin.x += section.frame.origin.x;
            normalizedHeaderFrame.origin.y += section.frame.origin.y;
            if (!CGRectIsEmpty(normalizedHeaderFrame) && CGRectIntersectsRect(normalizedHeaderFrame, rect)) {
                PSTCollectionViewLayoutAttributes *layoutAttributes = [[self.class layoutAttributesClass] layoutAttributesForSupplementaryViewOfKind:PSTCollectionElementKindSectionHeader withIndexPath:[NSIndexPath indexPathForRow:0 inSection:(NSInteger)sectionIndex]];
                layoutAttributes.frame = normalizedHeaderFrame;
                [layoutAttributesArray addObject:layoutAttributes];
            }

            NSArray *itemRects = [rectCache objectForKey:@(sectionIndex)];
            if (!itemRects && !section.packed && section.fixedItemSize && [section rowCount]) {
                itemRects = [[section rowAtIndex:0] itemRects];
                if (itemRects) [rectCache setObject:itemRects forKey:@(sectionIndex)];
            }

            // Rows are laid out in increasing order along the scroll axis, so only a window of
            // them can intersect the rect. Binary search for the first row whose far edge
            // reaches the rect and stop at the first row that starts beyond it, instead of
            // testing every row of the section on every scroll step.
            NSUInteger pstRowCount = (NSUInteger)[section rowCount];
            BOOL pstHorizontal = _data.horizontal;
            CGFloat pstRectMin = pstHorizontal ? CGRectGetMinX(pstSearch) : CGRectGetMinY(pstSearch);
            CGFloat pstRectMax = pstHorizontal ? CGRectGetMaxX(pstSearch) : CGRectGetMaxY(pstSearch);
            CGFloat pstSectionOrigin = pstHorizontal ? section.frame.origin.x : section.frame.origin.y;
            NSUInteger pstLow = 0, pstHigh = pstRowCount;
            while (pstLow < pstHigh) {
                NSUInteger mid = pstLow + (pstHigh - pstLow) / 2;
                CGRect midFrame = [section rowFrameAtIndex:(NSInteger)mid];
                CGFloat far = pstSectionOrigin + (pstHorizontal ? CGRectGetMaxX(midFrame) : CGRectGetMaxY(midFrame));
                if (far < pstRectMin) pstLow = mid + 1; else pstHigh = mid;
            }
            for (NSUInteger pstRowIndex = pstLow; pstRowIndex < pstRowCount; pstRowIndex++) {
                PSTGridLayoutRow *row = section.packed ? nil : [section rowAtIndex:(NSInteger)pstRowIndex];
                CGRect normalizedRowFrame = [section rowFrameAtIndex:(NSInteger)pstRowIndex];

                normalizedRowFrame.origin.x += section.frame.origin.x;
                normalizedRowFrame.origin.y += section.frame.origin.y;

                if ((pstHorizontal ? CGRectGetMinX(normalizedRowFrame) : CGRectGetMinY(normalizedRowFrame)) > pstRectMax) break;
                if (CGRectIntersectsRect(normalizedRowFrame, pstSearch)) {
                    // TODO be more fine-grained for items

                    const BOOL pstPacked = section.packed;
                    const NSInteger pstRowItemCount = pstPacked ? [section packedItemCountOfRow:(NSInteger)pstRowIndex] : row.itemCount;
                    for (NSInteger itemIndex = 0; itemIndex < pstRowItemCount; itemIndex++) {
                        PSTCollectionViewLayoutAttributes *layoutAttributes;
                        NSUInteger sectionItemIndex;
                        CGRect itemFrame;
                        if (pstPacked) {
                            sectionItemIndex = (NSUInteger)([section packedFirstItemOfRow:(NSInteger)pstRowIndex] + itemIndex);
                            itemFrame = [section packedItemFrameAtIndex:(NSInteger)sectionItemIndex];
                        } else if (row.fixedItemSize) {
                            itemFrame = [[itemRects objectAtIndex:(NSUInteger)itemIndex] CGRectValue];
                            // The row's position, not row.index: a compact fixed-size section shares one row object
                            // between all of its complete rows.
                            sectionItemIndex = (NSUInteger)((NSInteger)pstRowIndex * section.itemsByRowCount + itemIndex);
                        }else {
                            PSTGridLayoutItem *item = [row.items objectAtIndex:(NSUInteger)itemIndex];
                            sectionItemIndex = (NSUInteger)(row.firstItemIndex + itemIndex);
                            itemFrame = item.itemFrame;
                        }

                        CGRect normalisedItemFrame = CGRectMake(normalizedRowFrame.origin.x + itemFrame.origin.x, normalizedRowFrame.origin.y + itemFrame.origin.y, itemFrame.size.width, itemFrame.size.height);
                        if (pstPacked) normalisedItemFrame = PSTPixelOrigin(normalisedItemFrame, pstScale);

                        if (CGRectIntersectsRect(normalisedItemFrame, rect)) {
                            layoutAttributes = [[self.class layoutAttributesClass] layoutAttributesForCellWithIndexPath:[NSIndexPath indexPathForRow:(NSInteger)sectionItemIndex inSection:(NSInteger)sectionIndex]];
                            layoutAttributes.frame = normalisedItemFrame;
                            [layoutAttributesArray addObject:layoutAttributes];
                        }
                    }
                }
            }

            CGRect normalizedFooterFrame = section.footerFrame;
            normalizedFooterFrame.origin.x += section.frame.origin.x;
            normalizedFooterFrame.origin.y += section.frame.origin.y;
            if (!CGRectIsEmpty(normalizedFooterFrame) && CGRectIntersectsRect(normalizedFooterFrame, rect)) {
                PSTCollectionViewLayoutAttributes *layoutAttributes = [[self.class layoutAttributesClass] layoutAttributesForSupplementaryViewOfKind:PSTCollectionElementKindSectionFooter withIndexPath:[NSIndexPath indexPathForRow:0 inSection:(NSInteger)sectionIndex]];
                layoutAttributes.frame = normalizedFooterFrame;
                [layoutAttributesArray addObject:layoutAttributes];
            }
        }
    }
    return layoutAttributesArray;
}

- (PSTCollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    PSTCollectionViewStatsCountersStorage[PSTStatItemDerivations]++;
    if (!_data || _needsPrepareLayout) [self prepareLayout];

    PSTGridLayoutSection *section = [_data.sections objectAtIndex:(NSUInteger)indexPath.section];
    PSTGridLayoutRow *row = nil;
    CGRect itemFrame = CGRectZero;

    NSInteger pstRowNumber = 0;
    if (section.packed) {
        if (indexPath.row >= 0 && indexPath.row < section.itemsCount) {
            pstRowNumber = [section packedRowOfItem:indexPath.row];
            itemFrame = [section packedItemFrameAtIndex:indexPath.row];
        }
        PSTCollectionViewLayoutAttributes *packedAttributes = [[self.class layoutAttributesClass] layoutAttributesForCellWithIndexPath:indexPath];
        CGRect packedRow = [section rowCount] > pstRowNumber ? [section rowFrameAtIndex:pstRowNumber] : CGRectZero;
        packedRow.origin.x += section.frame.origin.x;
        packedRow.origin.y += section.frame.origin.y;
        packedAttributes.frame = PSTPixelOrigin(CGRectMake(packedRow.origin.x + itemFrame.origin.x, packedRow.origin.y + itemFrame.origin.y, itemFrame.size.width, itemFrame.size.height), [UIScreen mainScreen].scale);
        return packedAttributes;
    }
    if (section.fixedItemSize && section.itemsByRowCount > 0 && indexPath.row / section.itemsByRowCount < [section rowCount]) {
        pstRowNumber = indexPath.row / section.itemsByRowCount;
        row = [section rowAtIndex:pstRowNumber];
        NSUInteger itemIndex = (NSUInteger)(indexPath.row % section.itemsByRowCount);
        NSArray *itemRects = [row itemRects];
        itemFrame = [[itemRects objectAtIndex:itemIndex] CGRectValue];
    }else if (indexPath.row < (NSInteger)section.items.count) {
        PSTGridLayoutItem *item = [section.items objectAtIndex:(NSUInteger)indexPath.row];
        row = item.rowObject;
        itemFrame = item.itemFrame;
    }

    PSTCollectionViewLayoutAttributes *layoutAttributes = [[self.class layoutAttributesClass] layoutAttributesForCellWithIndexPath:indexPath];

    // calculate item rect
    CGRect normalizedRowFrame = (section.fixedItemSize && [section rowCount] > pstRowNumber && row == [section rowAtIndex:pstRowNumber]) ? [section rowFrameAtIndex:pstRowNumber] : row.rowFrame;
    normalizedRowFrame.origin.x += section.frame.origin.x;
    normalizedRowFrame.origin.y += section.frame.origin.y;
    layoutAttributes.frame = CGRectMake(normalizedRowFrame.origin.x + itemFrame.origin.x, normalizedRowFrame.origin.y + itemFrame.origin.y, itemFrame.size.width, itemFrame.size.height);

    return layoutAttributes;
}

- (PSTCollectionViewLayoutAttributes *)layoutAttributesForSupplementaryViewOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    PSTCollectionViewStatsCountersStorage[PSTStatItemDerivations]++;
    if (!_data || _needsPrepareLayout) [self prepareLayout];

    NSUInteger sectionIndex = (NSUInteger)indexPath.section;
    PSTCollectionViewLayoutAttributes *layoutAttributes = nil;

    if (sectionIndex < _data.sections.count) {
        PSTGridLayoutSection *section = [_data.sections objectAtIndex:sectionIndex];

        CGRect normalizedFrame = CGRectZero;
        if ([kind isEqualToString:PSTCollectionElementKindSectionHeader]) {
            normalizedFrame = section.headerFrame;
        }
        else if ([kind isEqualToString:PSTCollectionElementKindSectionFooter]) {
            normalizedFrame = section.footerFrame;
        }

        if (!CGRectIsEmpty(normalizedFrame)) {
            normalizedFrame.origin.x += section.frame.origin.x;
            normalizedFrame.origin.y += section.frame.origin.y;

            layoutAttributes = [[self.class layoutAttributesClass] layoutAttributesForSupplementaryViewOfKind:kind withIndexPath:[NSIndexPath indexPathForRow:0 inSection:(NSInteger)sectionIndex]];
            layoutAttributes.frame = normalizedFrame;
        }
    }
    return layoutAttributes;
}

- (PSTCollectionViewLayoutAttributes *)layoutAttributesForDecorationViewWithReuseIdentifier:(NSString *)identifier atIndexPath:(NSIndexPath *)indexPath {
    PSTCollectionViewStatsCountersStorage[PSTStatItemDerivations]++;
    return nil;
}

- (CGSize)collectionViewContentSize {
    if (!_data || _needsPrepareLayout) [self prepareLayout];

    // Observed against UIKit: a self-sizing layout that scrolls vertically reports a whole-point content height;
    // one that scrolls horizontally keeps the fractional width.
    CGSize result = _data.contentSize;
    BOOL anyPacked = NO;
    for (PSTGridLayoutSection *s in _data.sections) if (s.packed) { anyPacked = YES; break; }
    if (anyPacked && !_data.horizontal) result.height = round(result.height);
    return result;
}

- (void)setSectionInset:(UIEdgeInsets)sectionInset {
    if (!UIEdgeInsetsEqualToEdgeInsets(sectionInset, _sectionInset)) {
        _sectionInset = sectionInset;
        [self invalidateLayout];
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Invalidating the Layout

- (void)invalidateLayoutWithContext:(PSTCollectionViewLayoutInvalidationContext *)context {
    if (![context isKindOfClass:[PSTCollectionViewFlowLayoutInvalidationContext class]]) {
        [NSException raise:NSInvalidArgumentException format:@"Flow layout requires a flow-layout invalidation context"];
    }
    PSTCollectionViewFlowLayoutInvalidationContext *flowContext = (id)context;
    BOOL full = context.invalidateEverything || context.invalidateDataSourceCounts;
    BOOL metrics = full || (flowContext.invalidateFlowLayoutAttributes && flowContext.invalidateFlowLayoutDelegateMetrics);
    // Contexts coalesce until preparation; a weaker later context cannot cancel a pending metrics rebuild.
    _contextRequiresMetrics = _contextRequiresMetrics || metrics;
    _preserveGeometryForContext = !_contextRequiresMetrics &&
        (!_needsPrepareLayout || _preserveGeometryForContext) && _data != nil;
    if (metrics) {
        _preparedLayoutIsReusable = NO;
        [_pstStableMeasuredFrames removeAllObjects];
        [self pstClearProposalRuns];
    }
    _needsPrepareLayout = YES;
    [super invalidateLayoutWithContext:context];
}

- (void)invalidateLayout {
    _preserveGeometryForContext = NO;
    // Explicit app invalidation permits content-driven sizes to change. Internal
    // measurement invalidations retain confirmations for unchanged proposal frames.
    if (!_pstPreservingStableMeasurements) {
        [_pstStableMeasuredFrames removeAllObjects];
        [self pstClearProposalRuns];
    }
    [super invalidateLayout];
    objc_setAssociatedObject(self, &kPSTCachedItemRectsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Keep _data: prepareLayout will verify the prepared-generation token and
    // only rebuild when a geometry input really changed.
    _needsPrepareLayout = YES;
}

- (BOOL)shouldInvalidateLayoutForBoundsChange:(CGRect)newBounds {
    // we need to recalculate on width changes
    if ((_visibleBounds.size.width != newBounds.size.width && self.scrollDirection == PSTCollectionViewScrollDirectionVertical) || (_visibleBounds.size.height != newBounds.size.height && self.scrollDirection == PSTCollectionViewScrollDirectionHorizontal)) {
        _visibleBounds = self.collectionView.bounds;
        return YES;
    }
    return NO;
}

// return a point at which to rest after scrolling - for layouts that want snap-to-point scrolling behavior
- (CGPoint)targetContentOffsetForProposedContentOffset:(CGPoint)proposedContentOffset withScrollingVelocity:(CGPoint)velocity {
    return proposedContentOffset;
}

- (void)prepareLayout {
    _needsPrepareLayout = NO;
    _contextRequiresMetrics = NO;
    if (_preserveGeometryForContext) {
        _preserveGeometryForContext = NO;
        _visibleBounds = self.collectionView.bounds;
        return;
    }

    if ([self canReusePreparedLayout]) {
        // Same bounds/item size/insets/spacings/section item counts: the existing
        // rows and sections are still correct.  Refresh only the cached bounds.
        PSTCollectionViewStatsCountersStorage[PSTStatLayoutPreparationReuses]++;
        _visibleBounds = self.collectionView.bounds;
        return;
    }

    PSTCollectionViewStatsCountersStorage[PSTStatLayoutPreparations]++;
    // custom ivars
    objc_setAssociatedObject(self, &kPSTCachedItemRectsKey, [NSMutableDictionary dictionary], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    _data = [PSTGridLayoutInfo new]; // clear old layout data
    _data.horizontal = self.scrollDirection == PSTCollectionViewScrollDirectionHorizontal;
    _data.selfSizing = [self pstUsesSelfSizing];
    _visibleBounds = self.collectionView.bounds;
    CGSize collectionViewSize = _visibleBounds.size;
    _data.dimension = _data.horizontal ? collectionViewSize.height : collectionViewSize.width;
    _data.rowAlignmentOptions = _rowAlignmentsOptionsDictionary;
    [self fetchItemsInfo];
    [self recordPreparedGeometry];
}

// Dynamic delegate geometry (per-item sizes, per-section insets/spacings and
// header/footer sizes) can change without any local property changing, so the
// prepared layout can not be validated cheaply and is always rebuilt.
- (CGSize)estimatedItemSize { return _estimatedItemSize; }
- (void)setEstimatedItemSize:(CGSize)size {
    if (CGSizeEqualToSize(size, _estimatedItemSize)) return;
    _estimatedItemSize = size;
    [self pstResetMeasuredSizes];
    [self invalidateLayout];
}

- (BOOL)pstUsesSelfSizing {
    return _estimatedItemSize.width > 0 && _estimatedItemSize.height > 0;
}

- (void)pstResetMeasuredSizes {
    [_pstMeasuredItemSizes removeAllObjects];
    [_pstStableMeasuredFrames removeAllObjects];
    _pstMeasuredSizeSum = CGSizeZero; _pstMeasuredSizeCount = 0;
    [self pstClearProposalRuns];
}

- (void)pstClearProposalRuns {
    [_pstProposalRuns setLength:0]; _pstProposalRunCount = 0; _pstEarliestChangedPath = nil;
}

- (CGSize)pstProposalAtSection:(NSInteger)section item:(NSInteger)item {
    if (!_pstProposalRunCount) return _pstProposalAtLayout;
    const PSTProposalRun *runs = _pstProposalRuns.bytes;
    NSUInteger lo = 0, hi = _pstProposalRunCount;     // last run starting at or before (section, item)
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        if (PSTProposalRunBefore(runs[mid], section, item) || (runs[mid].section == section && runs[mid].item == item)) lo = mid + 1;
        else hi = mid;
    }
    // A learned size applies only inside the section it was learned in; a section none of whose items have
    // changed yet keeps the original estimate, as UIKit does (it lays sections out lazily).
    if (lo && runs[lo - 1].section == section) return runs[lo - 1].size;
    return _pstProposalAtLayout0;
}

/// Called once per preferred-size invalidation batch: applies the current mean from one row before the
/// earliest changed item. Rows are taken from the layout built for the batch that just measured.
- (void)pstApplyProposalForChangedItems {
    NSIndexPath *path = _pstEarliestChangedPath; _pstEarliestChangedPath = nil;
    if (!path || !_pstMeasuredSizeCount || [self pstDelegateProvidesSizes]) return;
    NSInteger section = path.section, item = path.row, first = 0;
    if (section >= 0 && section < (NSInteger)_data.sections.count) {
        PSTGridLayoutSection *s = [_data.sections objectAtIndex:(NSUInteger)section];
        if (s.packed && item >= 0 && item < s.itemsCount) {
            NSInteger previous = MAX(0, [s packedRowOfItem:item] - 1);
            first = [s packedFirstItemOfRow:previous];
        }
    }
    if (!_pstProposalRuns) _pstProposalRuns = [NSMutableData data];
    if (!_pstProposalRunCount) {
        PSTProposalRun seed = {0, 0, _pstProposalAtLayout};
        [_pstProposalRuns appendBytes:&seed length:sizeof seed]; _pstProposalRunCount = 1;
    }
    CGSize mean = CGSizeMake(_pstMeasuredSizeSum.width / (CGFloat)_pstMeasuredSizeCount, _pstMeasuredSizeSum.height / (CGFloat)_pstMeasuredSizeCount);
    const PSTProposalRun *runs = _pstProposalRuns.bytes;
    NSUInteger keep = 0;
    while (keep < _pstProposalRunCount && PSTProposalRunBefore(runs[keep], section, first)) keep++;
    BOOL coalesce = keep && CGSizeEqualToSize(runs[keep - 1].size, mean);
    [_pstProposalRuns setLength:keep * sizeof(PSTProposalRun)];
    _pstProposalRunCount = keep;
    if (!coalesce) {
        PSTProposalRun next = {section, first, mean};
        [_pstProposalRuns appendBytes:&next length:sizeof next]; _pstProposalRunCount++;
    }
}

/// The layout's current size for an item: what its cell last reported, else the estimate.
- (CGSize)pstSizeForSelfSizingItemAtIndexPath:(NSIndexPath *)indexPath {
    NSValue *measured = [_pstMeasuredItemSizes objectForKey:indexPath];
    if (measured) return [measured CGSizeValue];
    id<PSTCollectionViewDelegateFlowLayout> delegate = (id)self.collectionView.delegate;
    if ([delegate respondsToSelector:@selector(collectionView:layout:sizeForItemAtIndexPath:)]) {
        // Native flow layout treats the app's size as the initial proposal, not
        // as an opt-out from preferredLayoutAttributesFitting when estimates exist.
        CGSize seed = [delegate collectionView:self.collectionView layout:self sizeForItemAtIndexPath:indexPath];
        if (!_pstMeasuredItemSizes) _pstMeasuredItemSizes = [NSMutableDictionary dictionary];
        [_pstMeasuredItemSizes setObject:[NSValue valueWithCGSize:seed] forKey:indexPath];
        return seed;
    }
    if (_pstMeasuredSizeCount) return [self pstProposalAtSection:indexPath.section item:indexPath.row];
    return [self pstUnmeasuredProposal];
}

/// The size proposed for an item no cell has reported on, and no delegate sized.
- (CGSize)pstUnmeasuredProposal {
    // automaticSize is a sentinel, not a geometric size. Native UIKit proposes 50x50
    // on both axes, independently of itemSize; retain the sentinel in the public getter.
    if (CGSizeEqualToSize(_estimatedItemSize, CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)))
        return CGSizeMake(50, 50);
    // A running mean matches the first-layout unmeasured proposal. UIKit preserves
    // different proposal ranges during stepped scrolling; that cache policy is not
    // reproduced yet. Freeze this mean per rebuild so one pass is consistent.
    if (_pstMeasuredSizeCount) return _pstProposalAtLayout;
    return _estimatedItemSize;
}

/// Records a cell's preferred size. Returns YES when it differs from the size currently laid out
/// (the layout is then invalidated and rebuilt with it). A size equal to the laid out one is marked
/// stable for that proposal frame, until explicit invalidation or cell reconfiguration.
+ (Class)invalidationContextClass { return [PSTCollectionViewFlowLayoutInvalidationContext class]; }

- (BOOL)shouldInvalidateLayoutForPreferredLayoutAttributes:(PSTCollectionViewLayoutAttributes *)preferredAttributes withOriginalAttributes:(PSTCollectionViewLayoutAttributes *)originalAttributes {
    return [self pstUsesSelfSizing] && !CGSizeEqualToSize(preferredAttributes.size, originalAttributes.size);
}

- (BOOL)pstRecordPreferredSize:(CGSize)size forItemAtIndexPath:(NSIndexPath *)indexPath proposedFrame:(CGRect)frame {
    if (!_pstMeasuredItemSizes) _pstMeasuredItemSizes = [NSMutableDictionary dictionary];
    if (!_pstStableMeasuredFrames) _pstStableMeasuredFrames = [NSMutableDictionary dictionary];
    CGSize current = [self pstSizeForSelfSizingItemAtIndexPath:indexPath];
    if (CGSizeEqualToSize(size, current)) {
        BOOL wasMeasured3 = [_pstMeasuredItemSizes objectForKey:indexPath] != nil;
        CGSize old3 = wasMeasured3 ? [[_pstMeasuredItemSizes objectForKey:indexPath] CGSizeValue] : CGSizeZero;
        [_pstStableMeasuredFrames setObject:[NSValue valueWithCGRect:frame] forKey:indexPath];
        // A first report equal to the proposal leaves the item an estimate, as UIKit does; only a report that
        // differs from its proposal is retained and feeds the mean. A delegate seed is stored as a measurement
        // but is not a cell report.
        if (wasMeasured3 || [self pstDelegateProvidesSizes]) {
            [_pstMeasuredItemSizes setObject:[NSValue valueWithCGSize:size] forKey:indexPath];
            if (![self pstDelegateProvidesSizes]) [self pstAccumulateMeasuredSize:size replacing:&old3];
        }
        return NO;
    }
    BOOL wasMeasured = [_pstMeasuredItemSizes objectForKey:indexPath] != nil;
    CGSize old = wasMeasured ? [[_pstMeasuredItemSizes objectForKey:indexPath] CGSizeValue] : CGSizeZero;
    [_pstMeasuredItemSizes setObject:[NSValue valueWithCGSize:size] forKey:indexPath];
    [_pstStableMeasuredFrames removeObjectForKey:indexPath];
    [self pstAccumulateMeasuredSize:size replacing:wasMeasured ? &old : NULL];
    if (!_pstEarliestChangedPath || [indexPath compare:_pstEarliestChangedPath] == NSOrderedAscending) _pstEarliestChangedPath = indexPath;
    return YES;
}

- (void)pstAccumulateMeasuredSize:(CGSize)size replacing:(const CGSize *)old {
    if (old) { _pstMeasuredSizeSum.width -= old->width; _pstMeasuredSizeSum.height -= old->height; }
    else _pstMeasuredSizeCount++;
    _pstMeasuredSizeSum.width += size.width; _pstMeasuredSizeSum.height += size.height;
}

- (BOOL)pstDelegateProvidesSizes {
    return [self.collectionView.delegate respondsToSelector:@selector(collectionView:layout:sizeForItemAtIndexPath:)];
}

- (BOOL)pstHasStableMeasuredSizeForItemAtIndexPath:(NSIndexPath *)indexPath proposedFrame:(CGRect)frame {
    NSValue *confirmed = [_pstStableMeasuredFrames objectForKey:indexPath];
    // An item that never changed from its estimate has no retained size to compare; its confirmation stands.
    return confirmed && (![_pstMeasuredItemSizes objectForKey:indexPath] || CGRectEqualToRect([confirmed CGRectValue], frame));
}

- (void)pstForgetStableMeasurementForItemAtIndexPath:(NSIndexPath *)indexPath {
    // A newly configured/reused cell may have different content even at the same path.
    [_pstStableMeasuredFrames removeObjectForKey:indexPath];
}

- (void)pstInvalidateForPreferredSizeChanges {
    [self pstApplyProposalForChangedItems];
    BOOL previous = _pstPreservingStableMeasurements;
    _pstPreservingStableMeasurements = YES;
    @try { [self invalidateLayout]; } // preserve subclass invalidation overrides
    @finally { _pstPreservingStableMeasurements = previous; }
}

- (BOOL)hasDynamicDelegateGeometry {
    id<PSTCollectionViewDelegateFlowLayout> flowDataSource = (id<PSTCollectionViewDelegateFlowLayout>)self.collectionView.delegate;
    return [self pstUsesSelfSizing] ||
           [flowDataSource respondsToSelector:@selector(collectionView:layout:sizeForItemAtIndexPath:)] ||
           [flowDataSource respondsToSelector:@selector(collectionView:layout:insetForSectionAtIndex:)] ||
           [flowDataSource respondsToSelector:@selector(collectionView:layout:minimumLineSpacingForSectionAtIndex:)] ||
           [flowDataSource respondsToSelector:@selector(collectionView:layout:minimumInteritemSpacingForSectionAtIndex:)] ||
           [flowDataSource respondsToSelector:@selector(collectionView:layout:referenceSizeForHeaderInSection:)] ||
           [flowDataSource respondsToSelector:@selector(collectionView:layout:referenceSizeForFooterInSection:)];
}

- (void)recordPreparedGeometry {
    _preparedBoundsSize = _visibleBounds.size;
    _preparedItemSize = _itemSize;
    _preparedHeaderReferenceSize = _headerReferenceSize;
    _preparedFooterReferenceSize = _footerReferenceSize;
    _preparedLineSpacing = _lineSpacing;
    _preparedInteritemSpacing = _interitemSpacing;
    _preparedSectionInset = _sectionInset;
    _preparedScrollDirection = _scrollDirection;
    _preparedRowAlignmentsOptionsDictionary = [_rowAlignmentsOptionsDictionary copy];

    PSTCollectionView *collectionView = self.collectionView;
    NSInteger sectionCount = [collectionView numberOfSections];
    if (!_preparedSectionItemCounts) {
        _preparedSectionItemCounts = [NSMutableArray arrayWithCapacity:(NSUInteger)sectionCount];
    } else {
        [_preparedSectionItemCounts removeAllObjects];
    }
    for (NSInteger section = 0; section < sectionCount; section++) {
        [_preparedSectionItemCounts addObject:@([collectionView numberOfItemsInSection:section])];
    }
    _preparedLayoutIsReusable = YES;
}

- (BOOL)canReusePreparedLayout {
    if (!_preparedLayoutIsReusable || !_data) {
        return NO;
    }
    // Evaluated live: assigning a delegate that provides per-item geometry must
    // force a rebuild even though no local property changed.
    if ([self hasDynamicDelegateGeometry]) {
        return NO;
    }
    PSTCollectionView *collectionView = self.collectionView;
    if (!collectionView) {
        return NO;
    }
    if (!CGSizeEqualToSize(collectionView.bounds.size, _preparedBoundsSize)) return NO;
    if (!CGSizeEqualToSize(_itemSize, _preparedItemSize)) return NO;
    if (!CGSizeEqualToSize(_headerReferenceSize, _preparedHeaderReferenceSize)) return NO;
    if (!CGSizeEqualToSize(_footerReferenceSize, _preparedFooterReferenceSize)) return NO;
    if (_lineSpacing != _preparedLineSpacing) return NO;
    if (_interitemSpacing != _preparedInteritemSpacing) return NO;
    if (!UIEdgeInsetsEqualToEdgeInsets(_sectionInset, _preparedSectionInset)) return NO;
    if (_scrollDirection != _preparedScrollDirection) return NO;
    if (_rowAlignmentsOptionsDictionary != _preparedRowAlignmentsOptionsDictionary &&
        ![_rowAlignmentsOptionsDictionary isEqual:_preparedRowAlignmentsOptionsDictionary]) {
        return NO;
    }
    NSInteger sectionCount = [collectionView numberOfSections];
    if (sectionCount != (NSInteger)_preparedSectionItemCounts.count) return NO;
    for (NSInteger section = 0; section < sectionCount; section++) {
        if ([collectionView numberOfItemsInSection:section] != [[_preparedSectionItemCounts objectAtIndex:(NSUInteger)section] integerValue]) {
            return NO;
        }
    }
    return YES;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Private

- (void)fetchItemsInfo {
    // Freeze the mean of reported sizes for this rebuild (see pstSizeForSelfSizing...).
    if (_pstMeasuredSizeCount) _pstProposalAtLayout = CGSizeMake(_pstMeasuredSizeSum.width / (CGFloat)_pstMeasuredSizeCount, _pstMeasuredSizeSum.height / (CGFloat)_pstMeasuredSizeCount);
    else _pstProposalAtLayout = CGSizeEqualToSize(_estimatedItemSize, CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)) ? CGSizeMake(50, 50) : _estimatedItemSize;
    _pstProposalAtLayout0 = CGSizeEqualToSize(_estimatedItemSize, CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)) ? CGSizeMake(50, 50) : _estimatedItemSize;
    [self getSizingInfos];
    [self updateItemsLayout];
}

// get size of all items (if delegate is implemented)
- (void)getSizingInfos {
    NSAssert(_data.sections.count == 0, @"Grid layout is already populated?");

    id<PSTCollectionViewDelegateFlowLayout> flowDataSource = (id<PSTCollectionViewDelegateFlowLayout>)self.collectionView.delegate;

    BOOL implementsSizeDelegate = [flowDataSource respondsToSelector:@selector(collectionView:layout:sizeForItemAtIndexPath:)];
    BOOL implementsHeaderReferenceDelegate = [flowDataSource respondsToSelector:@selector(collectionView:layout:referenceSizeForHeaderInSection:)];
    BOOL implementsFooterReferenceDelegate = [flowDataSource respondsToSelector:@selector(collectionView:layout:referenceSizeForFooterInSection:)];

    NSInteger numberOfSections = [self.collectionView numberOfSections];
    for (NSInteger section = 0; section < numberOfSections; section++) {
        PSTGridLayoutSection *layoutSection = [_data addSection];
        layoutSection.verticalInterstice = _data.horizontal ? self.minimumInteritemSpacing : self.minimumLineSpacing;
        layoutSection.horizontalInterstice = !_data.horizontal ? self.minimumInteritemSpacing : self.minimumLineSpacing;

        if ([flowDataSource respondsToSelector:@selector(collectionView:layout:insetForSectionAtIndex:)]) {
            layoutSection.sectionMargins = [flowDataSource collectionView:self.collectionView layout:self insetForSectionAtIndex:section];
        }else {
            layoutSection.sectionMargins = self.sectionInset;
        }

        if ([flowDataSource respondsToSelector:@selector(collectionView:layout:minimumLineSpacingForSectionAtIndex:)]) {
            CGFloat minimumLineSpacing = [flowDataSource collectionView:self.collectionView layout:self minimumLineSpacingForSectionAtIndex:section];
            if (_data.horizontal) {
                layoutSection.horizontalInterstice = minimumLineSpacing;
            }else {
                layoutSection.verticalInterstice = minimumLineSpacing;
            }
        }

        if ([flowDataSource respondsToSelector:@selector(collectionView:layout:minimumInteritemSpacingForSectionAtIndex:)]) {
            CGFloat minimumInterimSpacing = [flowDataSource collectionView:self.collectionView layout:self minimumInteritemSpacingForSectionAtIndex:section];
            if (_data.horizontal) {
                layoutSection.verticalInterstice = minimumInterimSpacing;
            }else {
                layoutSection.horizontalInterstice = minimumInterimSpacing;
            }
        }

        CGSize headerReferenceSize;
        if (implementsHeaderReferenceDelegate) {
            headerReferenceSize = [flowDataSource collectionView:self.collectionView layout:self referenceSizeForHeaderInSection:section];
        }else {
            headerReferenceSize = self.headerReferenceSize;
        }
        layoutSection.headerDimension = _data.horizontal ? headerReferenceSize.width : headerReferenceSize.height;

        CGSize footerReferenceSize;
        if (implementsFooterReferenceDelegate) {
            footerReferenceSize = [flowDataSource collectionView:self.collectionView layout:self referenceSizeForFooterInSection:section];
        }else {
            footerReferenceSize = self.footerReferenceSize;
        }
        layoutSection.footerDimension = _data.horizontal ? footerReferenceSize.width : footerReferenceSize.height;

        NSInteger numberOfItems = [self.collectionView numberOfItemsInSection:section];

        // self-sizing: every item carries the size its cell reported (or the estimate)
        if ([self pstUsesSelfSizing]) {
            // Packed storage: sizes live in one flat buffer instead of an item object per item.
            CGSize *sizes = [layoutSection preparePackedItems:numberOfItems];
            if (implementsSizeDelegate) {
                // The app's size is each item's seed, and the lookup records it, so every item is visited.
                for (NSInteger item = 0; item < numberOfItems; item++) {
                    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:item inSection:(NSInteger)section];
                    sizes[item] = [self pstSizeForSelfSizingItemAtIndexPath:indexPath];
                }
            } else {
                // Without a size delegate only measured items differ from the common proposal, and few of
                // them ever are. Fill every item with the proposal, then apply the measured sizes by walking
                // the measurements instead of building an index path per item.
                CGSize proposal = [self pstUnmeasuredProposal];
                if (_pstMeasuredSizeCount && _pstProposalRunCount) {
                    for (NSInteger item = 0; item < numberOfItems; item++) sizes[item] = [self pstProposalAtSection:(NSInteger)section item:item];
                } else {
                    for (NSInteger item = 0; item < numberOfItems; item++) sizes[item] = proposal;
                }
                if (_pstMeasuredItemSizes.count) {
                    [_pstMeasuredItemSizes enumerateKeysAndObjectsUsingBlock:^(NSIndexPath *path, NSValue *size, BOOL *stop) {
                        if (path.section == (NSInteger)section && path.row >= 0 && path.row < numberOfItems)
                            sizes[path.row] = [size CGSizeValue];
                    }];
                }
            }
        } else
        // if delegate implements size delegate, query it for all items
        if (implementsSizeDelegate) {
            for (NSInteger item = 0; item < numberOfItems; item++) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:item inSection:(NSInteger)section];
                CGSize itemSize = implementsSizeDelegate ? [flowDataSource collectionView:self.collectionView layout:self sizeForItemAtIndexPath:indexPath] : self.itemSize;

                PSTGridLayoutItem *layoutItem = [layoutSection addItem];
                layoutItem.itemFrame = (CGRect){.size=itemSize};
            }
            // if not, go the fast path
        }else {
            layoutSection.fixedItemSize = YES;
            layoutSection.itemSize = self.itemSize;
            layoutSection.itemsCount = numberOfItems;
        }
    }
}

- (void)updateItemsLayout {
    CGSize contentSize = CGSizeZero;
    for (PSTGridLayoutSection *section in _data.sections) {
        [section computeLayout];

        // update section offset to make frame absolute (section only calculates relative)
        CGRect sectionFrame = section.frame;
        if (_data.horizontal) {
            sectionFrame.origin.x += contentSize.width;
            contentSize.width += section.frame.size.width + section.frame.origin.x;
            contentSize.height = MAX(contentSize.height, sectionFrame.size.height + section.frame.origin.y + section.sectionMargins.top + section.sectionMargins.bottom);
        }else {
            sectionFrame.origin.y += contentSize.height;
            contentSize.height += sectionFrame.size.height + section.frame.origin.y;
            contentSize.width = MAX(contentSize.width, sectionFrame.size.width + section.frame.origin.x + section.sectionMargins.left + section.sectionMargins.right);
        }
        section.frame = sectionFrame;
    }
    // The non-scrolling axis still spans the viewport when an incomplete column
    // occupies less space. This matters for self-sizing columns, whose measured
    // union can be much shorter than the available height.
    // UIKit sizes the non-scrolling axis to the viewport, whatever the items or insets add up to: narrower items,
    // wider items and inset sections all leave it unchanged.
    if (_data.sections.count) {
        if (_data.horizontal) contentSize.height = _data.dimension;
        else contentSize.width = _data.dimension;
    }
    _data.contentSize = contentSize;
}

@end
