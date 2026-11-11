//
//  PSTGridLayoutSection.m
//  PSPDFKit
//
//  Copyright (c) 2012-2013 Peter Steinberger. All rights reserved.
//

#import "PSTGridLayoutSection.h"
#import "PSTGridLayoutItem.h"
#import "PSTGridLayoutRow.h"
#import "PSTGridLayoutInfo.h"
#import "PSTCollectionViewFlowLayout.h"

@interface PSTGridLayoutSection () {
    NSMutableArray *_items;
    NSMutableArray *_rows;
    BOOL _isValid;
    // Compact fixed-size rows (see rowCount): row i starts at _fixedRowOrigins[i] along the scroll axis.
    CGFloat *_fixedRowOrigins;
    NSInteger _fixedRowCount;
    PSTGridLayoutRow *_fixedTemplateRow;
    PSTGridLayoutRow *_fixedLastRow;
    // Packed variable-size storage (see preparePackedItems:).
    BOOL _packed;
    NSInteger _packedCount;       // items
    CGSize *_packedSizes;         // size of each item, filled by the layout before computeLayout
    CGPoint *_packedOrigins;      // origin of each item relative to its row
    NSInteger _packedRowCount;
    NSInteger *_packedRowFirst;   // first item of each row; _packedRowFirst[_packedRowCount] == _packedCount
    CGFloat *_packedRowOrigin;    // origin of each row along the scroll axis
    NSInteger _packedLaidOutRows; // rows whose geometry is materialised (valid-range extension)
    CGSize _packedPrefixExtent;   // running extent after those rows, before any derived remainder
    NSInteger _packedTotalRows;   // rows in the section
    CGSize _packedRemainderEstimate; // size assumed for rows not yet materialised
    CGSize *_packedRowSize;       // size of each row
}
@property (nonatomic, strong) NSArray *items;
@property (nonatomic, strong) NSArray *rows;
@property (nonatomic, assign, readwrite) NSInteger commonRowAlignment;
@property (nonatomic, assign, readwrite) NSInteger lastRowAlignment;
@property (nonatomic, assign, readwrite) BOOL centersItemsAcrossRow;
@property (nonatomic, assign) CGFloat otherMargin;
@property (nonatomic, assign) CGFloat beginMargin;
@property (nonatomic, assign) CGFloat endMargin;
@property (nonatomic, assign) CGFloat actualGap;
@property (nonatomic, assign) CGFloat lastRowBeginMargin;
@property (nonatomic, assign) CGFloat lastRowEndMargin;
@property (nonatomic, assign) CGFloat lastRowActualGap;
@property (nonatomic, assign) BOOL lastRowIncomplete;
@property (nonatomic, assign) NSInteger itemsByRowCount;
@property (nonatomic, assign) NSInteger indexOfImcompleteRow;
@end

@implementation PSTGridLayoutSection

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSObject

- (id)init {
    if ((self = [super init])) {
        _items = [NSMutableArray new];
        _rows = [NSMutableArray new];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p itemCount:%ld frame:%@ rows:%@>", NSStringFromClass(self.class), self, (long)self.itemsCount, NSStringFromCGRect(self.frame), self.rows];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public

- (void)dealloc {
    free(_fixedRowOrigins);
    [self pstFreePacked];
}

- (void)pstFreePacked {
    free(_packedSizes); free(_packedOrigins); free(_packedRowFirst); free(_packedRowOrigin); free(_packedRowSize);
    _packedSizes = NULL; _packedOrigins = NULL; _packedRowFirst = NULL; _packedRowOrigin = NULL; _packedRowSize = NULL;
    _packedRowCount = 0;
}

- (void)invalidate {
    _isValid = NO;
    _packedRowCount = 0;                                  // packed item sizes survive; rows are recomputed
    self.rows = [NSMutableArray array];
    free(_fixedRowOrigins); _fixedRowOrigins = NULL;
    _fixedRowCount = 0; _fixedTemplateRow = nil; _fixedLastRow = nil;
}

- (BOOL)packed { return _packed; }

- (CGSize *)preparePackedItems:(NSInteger)count {
    [self pstFreePacked];
    _packed = YES; _packedCount = MAX(0, count);
    _packedSizes = calloc((size_t)MAX(1, count), sizeof(CGSize));
    _packedOrigins = calloc((size_t)MAX(1, count), sizeof(CGPoint));
    return _packedSizes;
}

- (NSInteger)packedRowOfItem:(NSInteger)item {
    NSInteger lo = 0, hi = _packedRowCount;           // last row whose first item is <= item
    while (lo < hi) { NSInteger mid = lo + (hi - lo) / 2; if (_packedRowFirst[mid] <= item) lo = mid + 1; else hi = mid; }
    return MAX(0, lo - 1);
}
- (NSInteger)packedFirstItemOfRow:(NSInteger)row { return _packedRowFirst[row]; }
- (NSInteger)packedItemCountOfRow:(NSInteger)row { return _packedRowFirst[row + 1] - _packedRowFirst[row]; }
- (CGRect)packedItemFrameAtIndex:(NSInteger)item {
    return (CGRect){.origin=_packedOrigins[item], .size=_packedSizes[item]};
}

- (NSInteger)rowCount {
    if (_packed) return _packedRowCount;
    return _fixedRowOrigins ? _fixedRowCount : (NSInteger)self.rows.count;
}

- (PSTGridLayoutRow *)rowAtIndex:(NSInteger)index {
    if (!_fixedRowOrigins) return [self.rows objectAtIndex:(NSUInteger)index];
    return index == _fixedRowCount - 1 ? _fixedLastRow : _fixedTemplateRow;
}

- (CGRect)rowFrameAtIndex:(NSInteger)index {
    if (_packed) {
        CGSize size = _packedRowSize[index];
        return self.layoutInfo.horizontal ? CGRectMake(_packedRowOrigin[index], self.sectionMargins.top, size.width, size.height)
                                          : CGRectMake(self.sectionMargins.left, _packedRowOrigin[index], size.width, size.height);
    }
    if (!_fixedRowOrigins) return [[self.rows objectAtIndex:(NSUInteger)index] rowFrame];
    CGSize size = [self rowAtIndex:index].rowSize;
    return self.layoutInfo.horizontal ? CGRectMake(_fixedRowOrigins[index], self.sectionMargins.top, size.width, size.height)
                                      : CGRectMake(self.sectionMargins.left, _fixedRowOrigins[index], size.width, size.height);
}

// Lays out a fixed-size section without a row object per row. Every complete row is identical, so one
// template row is laid out and the last row (which may be incomplete) on its own. Row origins are
// accumulated with the same additions the per-row loop used, so the geometry is bit-identical.
// Returns NO, doing nothing, for sizes the general loop must handle (empty or zero-size items).
- (BOOL)pstComputeFixedRowsWithDimension:(CGFloat)dimension spacing:(CGFloat)spacing sectionSize:(CGSize *)sectionSize {
    BOOL horizontal = self.layoutInfo.horizontal;
    NSInteger count = self.itemsCount;
    CGFloat itemDimension = horizontal ? self.itemSize.height : self.itemSize.width;
    if (count <= 0 || !(itemDimension > 0) || !(spacing >= 0) || !isfinite(dimension)) return NO;

    // How many items the first row holds: the same running subtraction the per-row loop performed.
    NSInteger perRow = 1;
    CGFloat dimensionLeft = dimension - itemDimension;
    while (perRow < count) {
        CGFloat next = itemDimension + spacing;
        if (dimensionLeft < next) break;
        dimensionLeft -= next;
        perRow++;
    }
    NSInteger rowCount = (count + perRow - 1) / perRow;

    PSTGridLayoutRow *templateRow = [self addRow];
    templateRow.fixedItemSize = YES; templateRow.index = 0; templateRow.firstItemIndex = 0;
    templateRow.itemCount = rowCount == 1 ? count : perRow;
    PSTGridLayoutRow *lastRow = templateRow;
    if (rowCount > 1) {
        lastRow = [self addRow];
        lastRow.fixedItemSize = YES; lastRow.index = rowCount - 1; lastRow.firstItemIndex = (rowCount - 1) * perRow;
        lastRow.itemCount = count - (rowCount - 1) * perRow;
    }
    self.itemsByRowCount = (NSInteger)fmax(perRow, self.itemsByRowCount);

    // A row aligns as the incomplete one only when it is the section's last (see layoutRowAndGenerateRectArray:).
    self.indexOfImcompleteRow = rowCount > 1 ? 1 : 0;
    [templateRow layoutRow];
    if (rowCount > 1) {
        self.indexOfImcompleteRow = rowCount - 1;
        [lastRow layoutRow];
    }

    free(_fixedRowOrigins);
    _fixedRowOrigins = malloc((size_t)rowCount * sizeof(CGFloat));
    for (NSInteger i = 0; i < rowCount; i++) {
        PSTGridLayoutRow *row = i == rowCount - 1 ? lastRow : templateRow;
        BOOL finishCycle = i == rowCount - 1;
        if (horizontal) {
            _fixedRowOrigins[i] = sectionSize->width;
            sectionSize->height = MAX(row.rowSize.height, sectionSize->height);
            sectionSize->width += row.rowSize.width + (finishCycle ? 0 : self.horizontalInterstice);
        } else {
            _fixedRowOrigins[i] = sectionSize->height;
            sectionSize->height += row.rowSize.height + (finishCycle ? 0 : self.verticalInterstice);
            sectionSize->width = MAX(row.rowSize.width, sectionSize->width);
        }
    }
    _fixedRowCount = rowCount; _fixedTemplateRow = templateRow; _fixedLastRow = lastRow;
    templateRow.rowFrame = [self rowFrameAtIndex:0];
    lastRow.rowFrame = [self rowFrameAtIndex:rowCount - 1];
    return YES;
}

// Packed equivalent of the row loop in computeLayout plus PSTGridLayoutRow layoutRowAndGenerateRectArray:, for a
// section whose item sizes are in _packedSizes. It performs the same arithmetic in the same order, so the
// geometry is bit-identical; it only avoids a row object, an item object and an array per item.
- (void)pstComputePackedRowsWithDimension:(CGFloat)dimension spacing:(CGFloat)spacing sectionSize:(CGSize *)sectionSize {
    [self pstBreakPackedRowsWithDimension:dimension spacing:spacing];
    [self pstLayOutPackedRowsFrom:0 to:self.indexOfImcompleteRow + 1 dimension:dimension spacing:spacing sectionSize:sectionSize];
    _packedPrefixExtent = *sectionSize;
}

/// Pass 1 of the packed layout: breaks the items into rows and fills `_packedRowFirst`. No row geometry is
/// computed, so a caller can materialise only the rows it needs (windowed layout).
- (void)pstBreakPackedRowsWithDimension:(CGFloat)dimension spacing:(CGFloat)spacing {
    const BOOL horizontal = self.layoutInfo.horizontal;
    const NSInteger count = _packedCount;
    free(_packedRowFirst); free(_packedRowOrigin); free(_packedRowSize);
    NSInteger capacity = MAX(1, count) + 1;
    _packedRowFirst = malloc((size_t)capacity * sizeof(NSInteger));
    _packedRowOrigin = malloc((size_t)capacity * sizeof(CGFloat));
    _packedRowSize = malloc((size_t)capacity * sizeof(CGSize));
    _packedRowCount = 0;

    // 1. Break the items into rows with the same running subtraction the object loop used.
    NSInteger itemIndex = 0, itemsByRowCount = 0, rowIndex = 0;
    CGFloat dimensionLeft = 0;
    BOOL haveRow = NO;
    do {
        const BOOL finishCycle = itemIndex >= count;
        CGSize itemSize = finishCycle ? CGSizeZero : _packedSizes[itemIndex];
        CGFloat itemDimension = horizontal ? itemSize.height : itemSize.width;
        if (itemsByRowCount > 0) itemDimension += spacing;
        if (dimensionLeft < itemDimension || finishCycle) {
            if (haveRow) {
                self.itemsByRowCount = (NSInteger)fmax(itemsByRowCount, self.itemsByRowCount);
                if (!finishCycle) self.indexOfImcompleteRow = rowIndex - 1;
            }
            if (!finishCycle) {
                _packedRowFirst[_packedRowCount++] = itemIndex;
                haveRow = YES;
                self.indexOfImcompleteRow = rowIndex;
                rowIndex++;
                if (itemsByRowCount > 0) itemDimension -= spacing;
                dimensionLeft = dimension - itemDimension;
                itemsByRowCount = 0;
            }
        } else {
            dimensionLeft -= itemDimension;
        }
        itemIndex++;
        itemsByRowCount++;
    } while (itemIndex <= count);
    _packedRowFirst[_packedRowCount] = count;
    const NSInteger rows = _packedRowCount;
    // The object loop set indexOfImcompleteRow to the last row it created.
    self.indexOfImcompleteRow = rows > 0 ? rows - 1 : self.indexOfImcompleteRow;

    _packedLaidOutRows = 0;
}

/// Lays out rows [firstRow, lastRow) of an already-broken packed section. `sectionSize` carries the running
/// extent, so the same arithmetic serves a full rebuild and a windowed extension (see the valid-range plan).
- (void)pstLayOutPackedRowsFrom:(NSInteger)firstRow to:(NSInteger)lastRow dimension:(CGFloat)dimension
                        spacing:(CGFloat)spacing sectionSize:(CGSize *)sectionSize {
    const BOOL horizontal = self.layoutInfo.horizontal;
    const NSInteger count = _packedCount;
    const CGFloat verticalInterstice = self.verticalInterstice, horizontalInterstice = self.horizontalInterstice;
    const UIEdgeInsets margins = self.sectionMargins;
    const BOOL centerItems = self.centersItemsAcrossRow;
    const NSInteger rows = self.indexOfImcompleteRow + 1;
    for (NSInteger row = firstRow; row < lastRow; row++) {
        const NSInteger first = _packedRowFirst[row], n = _packedRowFirst[row + 1] - first;
        const BOOL isLastRow = self.indexOfImcompleteRow == row;
        const PSTFlowLayoutHorizontalAlignment alignment = (PSTFlowLayoutHorizontalAlignment)(isLastRow ? self.lastRowAlignment : self.commonRowAlignment);
        CGFloat leftOverSpace = self.layoutInfo.dimension - (horizontal ? margins.top + margins.bottom : margins.left + margins.right);
        NSInteger usedItemCount = 0, k = 0;
        CGFloat maxScrollDimension = 0;
        while (k < n || isLastRow) {
            CGSize measured = _packedSizes[first + MIN(k, n - 1)];
            CGFloat next = horizontal ? measured.height : measured.width;
            if (centerItems && k < n) maxScrollDimension = MAX(maxScrollDimension, horizontal ? measured.width : measured.height);
            if (k > 0) next += spacing;
            if (leftOverSpace < next) break;
            leftOverSpace -= next;
            k++; usedItemCount = k;
        }
        const BOOL soleSelfSizingItem = self.layoutInfo.selfSizing && count == 1;
        if (soleSelfSizingItem) {
            CGSize size = _packedSizes[0];
            CGFloat available = self.layoutInfo.dimension - (horizontal ? margins.top + margins.bottom : margins.left + margins.right);
            leftOverSpace = MAX(0, available - (horizontal ? size.height : size.width));
            usedItemCount = 1;
        }
        CGPoint itemOffset = CGPointZero;
        if (alignment == PSTFlowLayoutHorizontalAlignmentRight) {
            if (horizontal) itemOffset.y += leftOverSpace; else itemOffset.x += leftOverSpace;
        } else if (alignment == PSTFlowLayoutHorizontalAlignmentCentered ||
                   (alignment == PSTFlowLayoutHorizontalAlignmentJustify && usedItemCount == 1)) {
            if (horizontal) itemOffset.y += leftOverSpace / 2;
            else itemOffset.x += leftOverSpace / 2;
        }
        const CGFloat interSpacing = usedItemCount <= 1 ? 0 : leftOverSpace / (CGFloat)(usedItemCount - 1);
        CGRect frame = CGRectZero;
        for (NSInteger j = 0; j < n; j++) {
            CGRect itemFrame = (CGRect){.size=_packedSizes[first + j]};
            if (horizontal) {
                itemFrame.origin.x = centerItems ? (maxScrollDimension - itemFrame.size.width) / 2 : 0;
                itemFrame.origin.y = itemOffset.y;
                itemOffset.y += itemFrame.size.height + verticalInterstice;
                if (alignment == PSTFlowLayoutHorizontalAlignmentJustify) itemOffset.y += interSpacing;
            } else {
                itemFrame.origin.y = centerItems ? (maxScrollDimension - itemFrame.size.height) / 2 : 0;
                itemFrame.origin.x = itemOffset.x;
                itemOffset.x += itemFrame.size.width + horizontalInterstice;
                if (alignment == PSTFlowLayoutHorizontalAlignmentJustify) itemOffset.x += interSpacing;
            }
            _packedOrigins[first + j] = itemFrame.origin;
            frame = CGRectUnion(frame, itemFrame);
        }
        _packedRowSize[row] = frame.size;
        const BOOL finish = row == rows - 1;
        if (horizontal) {
            _packedRowOrigin[row] = sectionSize->width;
            sectionSize->height = MAX(frame.size.height, sectionSize->height);
            sectionSize->width += frame.size.width + (finish ? 0 : horizontalInterstice);
        } else {
            _packedRowOrigin[row] = sectionSize->height;
            sectionSize->height += frame.size.height + (finish ? 0 : self.verticalInterstice);
            sectionSize->width = MAX(frame.size.width, sectionSize->width);
        }
    }
}

/// Materialises row geometry up to and including `targetRow`, continuing from whatever is already laid out.
/// `sectionSize` must carry the running extent from the same starting point (see the valid-range plan).
- (NSInteger)materialisedRowCount { return _packed ? _packedLaidOutRows : 0; }

/// Materialises further rows of a lazily built uniform section, continuing from the recorded prefix extent.
/// Returns the section's scrolling-axis growth, which the caller must propagate to later sections.
/// Scrolling-axis extent the section reports for a given number of materialised rows: the measured prefix plus
/// the estimate for the rest. Materialising rows replaces part of that estimate, so the difference is the growth
/// the caller must propagate.
- (CGFloat)packedEstimatedExtentForLaidOutRows:(NSInteger)laid {
    const BOOL horizontal = self.layoutInfo.horizontal;
    const CGFloat prefix = horizontal ? _packedPrefixExtent.width : _packedPrefixExtent.height;
    const NSInteger rest = _packedTotalRows - laid;
    if (rest <= 0) return prefix;
    const CGFloat rowExtent = horizontal ? _packedRemainderEstimate.width : _packedRemainderEstimate.height;
    const CGFloat gap = horizontal ? self.horizontalInterstice : self.verticalInterstice;
    return prefix + (CGFloat)rest * rowExtent + (CGFloat)(rest - 1) * gap;
}

- (BOOL)materialisePackedRowsThroughRow:(NSInteger)row dimension:(CGFloat)dimension spacing:(CGFloat)spacing
                          scrollGrowth:(CGFloat *)growth {
    if (growth) *growth = 0;
    if (!_packed || !_isValid) return NO;
    const NSInteger rows = self.indexOfImcompleteRow + 1;
    const NSInteger target = MIN(row + 1, rows);
    if (target <= _packedLaidOutRows) return YES;
    const CGFloat before = [self packedEstimatedExtentForLaidOutRows:_packedLaidOutRows];
    CGSize extent = _packedPrefixExtent;
    [self pstLayOutPackedRowsFrom:_packedLaidOutRows to:target dimension:dimension spacing:spacing sectionSize:&extent];
    _packedPrefixExtent = extent;
    _packedLaidOutRows = target;
    const CGFloat after = [self packedEstimatedExtentForLaidOutRows:_packedLaidOutRows];
    // The cross axis is the largest row so far; materialising rows can raise it, so refresh it here.
    const BOOL horiz = self.layoutInfo.horizontal;
    CGFloat crossMax = 0;
    for (NSInteger r = 0; r < _packedLaidOutRows; r++)
        crossMax = MAX(crossMax, horiz ? _packedRowSize[r].height : _packedRowSize[r].width);
    CGRect own = _frame;
    if (horiz) own.size.height = MAX(own.size.height, crossMax);
    else own.size.width = MAX(own.size.width, crossMax);
    _frame = own;
    if (growth) *growth = after - before;
    return YES;
}

- (BOOL)packedSizesAreUniform {
    if (!_packed || _packedCount <= 0) return NO;
    const CGSize first = _packedSizes[0];
    if (first.width <= 0 || first.height <= 0) return NO;
    for (NSInteger i = 1; i < _packedCount; i++)
        if (!CGSizeEqualToSize(_packedSizes[i], first)) return NO;
    return YES;
}

- (BOOL)extendPackedRowsThroughRow:(NSInteger)targetRow dimension:(CGFloat)dimension spacing:(CGFloat)spacing
                      sectionSize:(CGSize *)sectionSize {
    if (!_packed || !sectionSize) return NO;
    if (_packedRowCount == 0 && _packedCount > 0) [self pstBreakPackedRowsWithDimension:dimension spacing:spacing];
    if (_packedRowCount == 0) return NO;
    const NSInteger rows = self.indexOfImcompleteRow + 1;
    const NSInteger last = MIN(targetRow + 1, rows);
    if (last <= _packedLaidOutRows) return YES;
    [self pstLayOutPackedRowsFrom:_packedLaidOutRows to:last dimension:dimension spacing:spacing sectionSize:sectionSize];
    _packedLaidOutRows = last;
    return YES;
}

- (BOOL)reflowPackedItemAtIndex:(NSInteger)item size:(CGSize)size scrollDelta:(CGFloat *)delta {
    if (delta) *delta = 0;
    if (!_packed || !_isValid || item < 0 || item >= _packedCount ||
        !isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0) return NO;
    CGRect before = _frame;
    _packedSizes[item] = size;
    [self invalidate];
    [self computeLayout];
    _frame.origin = before.origin;
    if (delta) *delta = self.layoutInfo.horizontal ? _frame.size.width - before.size.width : _frame.size.height - before.size.height;
    return YES;
}

- (BOOL)stagePackedItemAtIndex:(NSInteger)item size:(CGSize)size {
    if (!_packed || !_isValid || item < 0 || item >= _packedCount) return NO;
    const BOOL horizontal = self.layoutInfo.horizontal;
    CGSize old = _packedSizes[item];
    if ((horizontal ? old.height != size.height : old.width != size.width) ||
        !isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0) return NO;
    _packedSizes[item] = size;
    return YES;
}

- (BOOL)updatePackedItemAtIndex:(NSInteger)item size:(CGSize)size scrollDelta:(CGFloat *)delta {
    if (delta) *delta = 0;
    if (![self stagePackedItemAtIndex:item size:size]) return NO;
    const BOOL horizontal = self.layoutInfo.horizontal;
    NSInteger row = [self packedRowOfItem:item];
    NSInteger first = _packedRowFirst[row], end = _packedRowFirst[row + 1];
    CGFloat extent = 0;
    for (NSInteger k = first; k < end; k++) extent = MAX(extent, horizontal ? _packedSizes[k].width : _packedSizes[k].height);
    CGRect unionFrame = CGRectNull;
    for (NSInteger k = first; k < end; k++) {
        CGPoint origin = _packedOrigins[k];
        CGFloat centered = self.centersItemsAcrossRow ? (extent - (horizontal ? _packedSizes[k].width : _packedSizes[k].height)) / 2 : 0;
        if (horizontal) origin.x = centered; else origin.y = centered;
        _packedOrigins[k] = origin;
        unionFrame = CGRectUnion(unionFrame, (CGRect){origin, _packedSizes[k]});
    }
    CGFloat change = horizontal ? unionFrame.size.width - _packedRowSize[row].width : unionFrame.size.height - _packedRowSize[row].height;
    _packedRowSize[row] = unionFrame.size;
    for (NSInteger r = row + 1; r < _packedRowCount; r++) _packedRowOrigin[r] += change;
    if (horizontal) { _frame.size.width += change; _footerFrame.origin.x += change; }
    else { _frame.size.height += change; _footerFrame.origin.y += change; }
    if (delta) *delta = change;
    return YES;
}

/// Lazy variant for packed sections: materialises only rows up to `lastRow` and estimates the rest of the extent.
/// With uniform items the estimate is exact (see -packedSizesAreUniform); with variable items the caller passes
/// `estimate`, the size an unmeasured row's items are expected to take, which is what UIKit assumes for rows it
/// has not laid out. Unmaterialised rows have no geometry until extended.
- (void)computeLayoutMaterialisingRowsThrough:(NSInteger)lastRow {
    CGSize estimate = CGSizeZero;
    if (_packed && _packedCount > 0 && [self packedSizesAreUniform]) estimate = _packedSizes[0];
    [self computeLayoutMaterialisingRowsThrough:lastRow estimate:estimate];
}

- (void)computeLayoutMaterialisingRowsThrough:(NSInteger)lastRow estimate:(CGSize)estimate {
    NSAssert(_packed, @"lazy layout needs a packed section");
    if (_isValid) return;
    NSAssert(self.rows.count == 0, @"No rows shall be at this point.");

    const BOOL horizontal = self.layoutInfo.horizontal;
    CGSize sectionSize = CGSizeZero;
    const CGFloat headerFooterDimension = self.layoutInfo.dimension;
    CGFloat dimension = headerFooterDimension;
    if (horizontal) {
        dimension -= self.sectionMargins.top + self.sectionMargins.bottom;
        self.headerFrame = CGRectMake(sectionSize.width, 0, self.headerDimension, headerFooterDimension);
        sectionSize.width += self.headerDimension + self.sectionMargins.left;
    } else {
        dimension -= self.sectionMargins.left + self.sectionMargins.right;
        self.headerFrame = CGRectMake(0, sectionSize.height, headerFooterDimension, self.headerDimension);
        sectionSize.height += self.headerDimension + self.sectionMargins.top;
    }
    const CGFloat spacing = horizontal ? self.verticalInterstice : self.horizontalInterstice;
    [self pstBreakPackedRowsWithDimension:dimension spacing:spacing];
    const NSInteger rows = self.indexOfImcompleteRow + 1;
    const NSInteger limit = MIN(MAX(lastRow + 1, (NSInteger)0), rows);
    _packedPrefixExtent = sectionSize;   // extent after the header and leading margin, before any rows
    _packedRemainderEstimate = estimate;
    _packedTotalRows = self.indexOfImcompleteRow + 1;
    if (limit > 0) {
        [self pstLayOutPackedRowsFrom:0 to:limit dimension:dimension spacing:spacing sectionSize:&sectionSize];
        _packedPrefixExtent = sectionSize;
        _packedLaidOutRows = limit;
        // Remainder of the rows: same arithmetic as pstLayOutPackedRowsFrom, continued without geometry. For
        // uniform items the last row's extent is exact; for variable items the caller's estimate is used.
        const NSInteger rest = rows - limit;
        if (rest > 0) {
            const CGSize rowSize = [self packedSizesAreUniform] ? _packedRowSize[limit - 1] : estimate;
            const CGFloat rowExtent = horizontal ? rowSize.width : rowSize.height;
            const CGFloat gap = horizontal ? self.horizontalInterstice : self.verticalInterstice;
            // Each remaining row adds its extent, and a gap only between rows (never after the last one); the
            // last materialised row already added the gap that follows it.
            const CGFloat grew = (CGFloat)rest * rowExtent + (rest > 0 ? (CGFloat)(rest - 1) * gap : 0);
            if (horizontal) { sectionSize.width += grew; sectionSize.height = MAX(rowSize.height, sectionSize.height); }
            else { sectionSize.height += grew; sectionSize.width = MAX(rowSize.width, sectionSize.width); }
        }
    }
    if (horizontal) {
        sectionSize.width += self.sectionMargins.right;
        self.footerFrame = CGRectMake(sectionSize.width, 0, self.footerDimension, headerFooterDimension);
        sectionSize.width += self.footerDimension;
    } else {
        sectionSize.height += self.sectionMargins.bottom;
        self.footerFrame = CGRectMake(0, sectionSize.height, headerFooterDimension, self.footerDimension);
        sectionSize.height += self.footerDimension;
    }
    _frame = CGRectMake(0, 0, sectionSize.width, sectionSize.height);
    _isValid = YES;
}

- (void)computeLayout {
    if (!_isValid) {
        NSAssert(self.rows.count == 0, @"No rows shall be at this point.");

        // iterate over all items, turning them into rows.
        CGSize sectionSize = CGSizeZero;
        NSInteger rowIndex = 0;
        NSInteger itemIndex = 0;
        NSInteger itemsByRowCount = 0;
        CGFloat dimensionLeft = 0;
        PSTGridLayoutRow *row = nil;
        PSTGridLayoutRow *templateRow = nil; // first complete row of a fixed-size section
        NSInteger templateCount = 0;
        // get dimension and compensate for section margin
        CGFloat headerFooterDimension = self.layoutInfo.dimension;
        CGFloat dimension = headerFooterDimension;

        if (self.layoutInfo.horizontal) {
            dimension -= self.sectionMargins.top + self.sectionMargins.bottom;
            self.headerFrame = CGRectMake(sectionSize.width, 0, self.headerDimension, headerFooterDimension);
            sectionSize.width += self.headerDimension + self.sectionMargins.left;
        }else {
            dimension -= self.sectionMargins.left + self.sectionMargins.right;
            self.headerFrame = CGRectMake(0, sectionSize.height, headerFooterDimension, self.headerDimension);
            sectionSize.height += self.headerDimension + self.sectionMargins.top;
        }

        CGFloat spacing = self.layoutInfo.horizontal ? self.verticalInterstice : self.horizontalInterstice;

        if (_packed) {
            [self pstComputePackedRowsWithDimension:dimension spacing:spacing sectionSize:&sectionSize];
            // A full build materialises every row; record it so on-demand materialisation is a no-op.
            _packedLaidOutRows = self.indexOfImcompleteRow + 1;
        } else if (![self pstComputeFixedRowsWithDimension:dimension spacing:spacing sectionSize:&sectionSize]) {
            do {
                BOOL finishCycle = itemIndex >= self.itemsCount;
                // TODO: fast path could even remove row creation and just calculate on the fly
                PSTGridLayoutItem *item = nil;
                if (!finishCycle) item = self.fixedItemSize ? nil : [self.items objectAtIndex:(NSUInteger)itemIndex];

                CGSize itemSize = self.fixedItemSize ? self.itemSize : item.itemFrame.size;
                CGFloat itemDimension = self.layoutInfo.horizontal ? itemSize.height : itemSize.width;
                // first item of each row does not add spacing
                if (itemsByRowCount > 0) itemDimension += spacing;
                if (dimensionLeft < itemDimension || finishCycle) {
                    // finish current row
                    if (row) {
                        // compensate last row
                        self.itemsByRowCount = fmax(itemsByRowCount, self.itemsByRowCount);
                        row.itemCount = itemsByRowCount;

                        // if current row is done but there are still items left, increase the incomplete row counter
                        if (!finishCycle) self.indexOfImcompleteRow = rowIndex;

                        // In a fixed-size section every complete row (not the final, possibly incomplete
                        // one) lays out identically, so lay the first one out and let the rest adopt it.
                        BOOL isFinalRow = finishCycle;
                        if (self.fixedItemSize && !isFinalRow && templateRow && itemsByRowCount == templateCount && row != templateRow) {
                            [row adoptLayoutFromRow:templateRow];
                        } else {
                            [row layoutRow];
                            if (self.fixedItemSize && !isFinalRow && !templateRow) { templateRow = row; templateCount = itemsByRowCount; }
                        }

                        if (self.layoutInfo.horizontal) {
                            row.rowFrame = CGRectMake(sectionSize.width, self.sectionMargins.top, row.rowSize.width, row.rowSize.height);
                            sectionSize.height = MAX(row.rowSize.height, sectionSize.height);
                            sectionSize.width += row.rowSize.width + (finishCycle ? 0 : self.horizontalInterstice);
                        }else {
                            row.rowFrame = CGRectMake(self.sectionMargins.left, sectionSize.height, row.rowSize.width, row.rowSize.height);
                            sectionSize.height += row.rowSize.height + (finishCycle ? 0 : self.verticalInterstice);
                            sectionSize.width = MAX(row.rowSize.width, sectionSize.width);
                        }
                    }
                    // add new rows until the section is fully laid out
                    if (!finishCycle) {
                        // create new row
                        row.complete = YES; // finish up current row
                        row = [self addRow];
                        row.fixedItemSize = self.fixedItemSize;
                        row.index = rowIndex;
                        row.firstItemIndex = itemIndex;
                        self.indexOfImcompleteRow = rowIndex;
                        rowIndex++;
                        // convert an item from previous row to current, remove spacing for first item
                        if (itemsByRowCount > 0) itemDimension -= spacing;
                        dimensionLeft = dimension - itemDimension;
                        itemsByRowCount = 0;
                    }
                }else {
                    dimensionLeft -= itemDimension;
                }

                // add item on slow path
                if (item) [row addItem:item];

                itemIndex++;
                itemsByRowCount++;
            } while (itemIndex <= self.itemsCount); // cycle once more to finish last row
        }

        if (self.layoutInfo.horizontal) {
            sectionSize.width += self.sectionMargins.right;
            self.footerFrame = CGRectMake(sectionSize.width, 0, self.footerDimension, headerFooterDimension);
            sectionSize.width += self.footerDimension;
        }else {
            sectionSize.height += self.sectionMargins.bottom;
            self.footerFrame = CGRectMake(0, sectionSize.height, headerFooterDimension, self.footerDimension);
            sectionSize.height += self.footerDimension;
        }

        _frame = CGRectMake(0, 0, sectionSize.width, sectionSize.height);
        _isValid = YES;
    }
}

- (void)recomputeFromIndex:(NSInteger)index {
    // TODO: use index.
    [self invalidate];
    [self computeLayout];
}

- (void)setRowAlignmentOptions:(NSDictionary *)options {
    _rowAlignmentOptions = options;
    // Same reads and defaults the row used to make on every layout.
    _commonRowAlignment = [[options objectForKey:PSTFlowLayoutCommonRowHorizontalAlignmentKey] integerValue];
    _lastRowAlignment = [[options objectForKey:PSTFlowLayoutLastRowHorizontalAlignmentKey] integerValue];
    id vertical = [options objectForKey:PSTFlowLayoutRowVerticalAlignmentKey];
    // UIKit's default mode (1) centers unequal items on the row's scroll axis; other private values keep top/leading.
    _centersItemsAcrossRow = !vertical || ([vertical respondsToSelector:@selector(integerValue)] && [vertical integerValue] == 1);
}

- (PSTGridLayoutItem *)addItem {
    PSTGridLayoutItem *item = [PSTGridLayoutItem new];
    item.section = self;
    [_items addObject:item];
    return item;
}

- (PSTGridLayoutRow *)addRow {
    PSTGridLayoutRow *row = [PSTGridLayoutRow new];
    row.section = self;
    [_rows addObject:row];
    return row;
}

- (PSTGridLayoutSection *)snapshot {
    PSTGridLayoutSection *snapshotSection = [PSTGridLayoutSection new];
    snapshotSection.items = [self.items copy];
    snapshotSection.rows = [self.items copy];
    snapshotSection.verticalInterstice = self.verticalInterstice;
    snapshotSection.horizontalInterstice = self.horizontalInterstice;
    snapshotSection.sectionMargins = self.sectionMargins;
    snapshotSection.frame = self.frame;
    snapshotSection.headerFrame = self.headerFrame;
    snapshotSection.footerFrame = self.footerFrame;
    snapshotSection.headerDimension = self.headerDimension;
    snapshotSection.footerDimension = self.footerDimension;
    snapshotSection.layoutInfo = self.layoutInfo;
    snapshotSection.rowAlignmentOptions = self.rowAlignmentOptions;
    snapshotSection.fixedItemSize = self.fixedItemSize;
    snapshotSection.itemSize = self.itemSize;
    snapshotSection.itemsCount = self.itemsCount;
    snapshotSection.otherMargin = self.otherMargin;
    snapshotSection.beginMargin = self.beginMargin;
    snapshotSection.endMargin = self.endMargin;
    snapshotSection.actualGap = self.actualGap;
    snapshotSection.lastRowBeginMargin = self.lastRowBeginMargin;
    snapshotSection.lastRowEndMargin = self.lastRowEndMargin;
    snapshotSection.lastRowActualGap = self.lastRowActualGap;
    snapshotSection.lastRowIncomplete = self.lastRowIncomplete;
    snapshotSection.itemsByRowCount = self.itemsByRowCount;
    snapshotSection.indexOfImcompleteRow = self.indexOfImcompleteRow;
    return snapshotSection;
}

- (NSInteger)itemsCount {
    if (_packed) return _packedCount;
    return self.fixedItemSize ? _itemsCount : (NSInteger)self.items.count;
}

@end
