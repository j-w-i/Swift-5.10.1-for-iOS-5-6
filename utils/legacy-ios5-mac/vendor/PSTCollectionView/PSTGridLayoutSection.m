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
}

- (void)invalidate {
    _isValid = NO;
    self.rows = [NSMutableArray array];
    free(_fixedRowOrigins); _fixedRowOrigins = NULL;
    _fixedRowCount = 0; _fixedTemplateRow = nil; _fixedLastRow = nil;
}

- (NSInteger)rowCount {
    return _fixedRowOrigins ? _fixedRowCount : (NSInteger)self.rows.count;
}

- (PSTGridLayoutRow *)rowAtIndex:(NSInteger)index {
    if (!_fixedRowOrigins) return [self.rows objectAtIndex:(NSUInteger)index];
    return index == _fixedRowCount - 1 ? _fixedLastRow : _fixedTemplateRow;
}

- (CGRect)rowFrameAtIndex:(NSInteger)index {
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

        if (![self pstComputeFixedRowsWithDimension:dimension spacing:spacing sectionSize:&sectionSize]) {
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
    return self.fixedItemSize ? _itemsCount : (NSInteger)self.items.count;
}

@end
