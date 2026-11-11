//
//  PSTGridLayoutRow.m
//  PSPDFKit
//
//  Copyright (c) 2012-2013 Peter Steinberger. All rights reserved.
//

#import "PSTCollectionView.h"
#import "PSTGridLayoutRow.h"
#import "PSTGridLayoutSection.h"
#import "PSTGridLayoutItem.h"
#import "PSTGridLayoutInfo.h"

@interface PSTGridLayoutRow () {
    NSMutableArray *_items;
    BOOL _isValid;
    int _verticalAlignement;
    int _horizontalAlignement;
}
@property (nonatomic, strong) NSArray *items;
@end

@implementation PSTGridLayoutRow

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSObject

- (id)init {
    if ((self = [super init])) {
        _items = [NSMutableArray new];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p frame:%@ index:%ld items:%@>", NSStringFromClass(self.class), self, NSStringFromCGRect(self.rowFrame), (long)self.index, self.items];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public

- (void)invalidate {
    _isValid = NO;
    _rowSize = CGSizeZero;
    _rowFrame = CGRectZero;
}

- (NSArray *)itemRects {
    return [self layoutRowAndGenerateRectArray:YES];
}

- (void)adoptLayoutFromRow:(PSTGridLayoutRow *)row {
    _rowSize = row.rowSize;
    _isValid = YES;
}

- (void)layoutRow {
    [self layoutRowAndGenerateRectArray:NO];
}

- (NSArray *)layoutRowAndGenerateRectArray:(BOOL)generateRectArray {
    NSMutableArray *rects = generateRectArray ? [NSMutableArray array] : nil;
    if (!_isValid || generateRectArray) {
        // Read every property the loops below need once. Variable-size sections run this per row
        // over every item, and each repeated property read is an Objective-C message.
        PSTGridLayoutSection *section = self.section;
        PSTGridLayoutInfo *layoutInfo = section.layoutInfo;
        const BOOL fixedSize = self.fixedItemSize;
        const NSInteger count = self.itemCount;
        const CGSize fixedItemSize = section.itemSize;
        const UIEdgeInsets margins = section.sectionMargins;
        const CGFloat verticalInterstice = section.verticalInterstice;
        const CGFloat horizontalInterstice = section.horizontalInterstice;
        NSArray *rowItems = fixedSize ? nil : _items;

        // properties for aligning
        BOOL isHorizontal = layoutInfo.horizontal;
        BOOL isLastRow = section.indexOfImcompleteRow == self.index;
        PSTFlowLayoutHorizontalAlignment horizontalAlignment = (PSTFlowLayoutHorizontalAlignment)(isLastRow ? section.lastRowAlignment : section.commonRowAlignment);

        // calculate space that's left over if we would align it from left to right.
        CGFloat leftOverSpace = layoutInfo.dimension;
        if (isHorizontal) {
            leftOverSpace -= margins.top + margins.bottom;
        }else {
            leftOverSpace -= margins.left + margins.right;
        }

        // calculate the space that we have left after counting all items.
        // UICollectionView is smart and lays out items like they would have been placed on a full row
        // So we need to calculate the "usedItemCount" with using the last item as a reference size.
        // This allows us to correctly justify-place the items in the grid.
        NSInteger usedItemCount = 0;
        NSInteger itemIndex = 0;
        CGFloat spacing = isHorizontal ? verticalInterstice : horizontalInterstice;
        // UIKit's default mode (1) centers unequal items on the row's scroll axis.
        // Preserve the former top/leading behaviour for other private option values.
        const BOOL centerItems = section.centersItemsAcrossRow;
        CGFloat maxScrollDimension = fixedSize ? (isHorizontal ? fixedItemSize.width : fixedItemSize.height) : 0;
        // the last row should justify as if it is filled with more (invisible) items so that the whole
        // UICollectionView feels more like a grid than a random line of blocks
        while (itemIndex < count || isLastRow) {
            CGFloat nextItemSize;
            // first we need to find the size (width/height) of the next item to fit
            if (!fixedSize) {
                CGSize measured = [(PSTGridLayoutItem *)[rowItems objectAtIndex:(NSUInteger)MIN(itemIndex, count - 1)] itemFrame].size;
                nextItemSize = isHorizontal ? measured.height : measured.width;
                if (centerItems && itemIndex < count)
                    maxScrollDimension = MAX(maxScrollDimension, isHorizontal ? measured.width : measured.height);
            }else {
                nextItemSize = isHorizontal ? fixedItemSize.height : fixedItemSize.width;
            }

            // the first item does not add a separator spacing,
            // every one afterwards in the same row will need this spacing constant
            if (itemIndex > 0) {
                nextItemSize += spacing;
            }

            // check to see if we can at least fit an item (+separator if necessary)
            if (leftOverSpace < nextItemSize) {
                break;
            }

            // we need to maintain the leftover space after the maximum amount of items have
            // occupied, so we know how to adjust equal spacing among all the items in a row
            leftOverSpace -= nextItemSize;

            itemIndex++;
            usedItemCount = itemIndex;
        }

        // Native self-sizing flow layout centers a section containing just one item
        // across its non-scrolling axis. Do not apply this to an incomplete last row
        // of a larger section, or to legacy fixed-size layouts.
        BOOL soleSelfSizingItem = layoutInfo.selfSizing && section.itemsCount == 1;
        if (soleSelfSizingItem) {
            CGSize size = fixedSize ? fixedItemSize : ((PSTGridLayoutItem *)[rowItems objectAtIndex:0]).itemFrame.size;
            CGFloat available = layoutInfo.dimension - (isHorizontal
                ? margins.top + margins.bottom
                : margins.left + margins.right);
            leftOverSpace = MAX(0, available - (isHorizontal ? size.height : size.width));
            usedItemCount = 1;
        }

        // push everything to the right if right-aligning and divide in half for centered
        // currently there is no public API supporting this behavior
        CGPoint itemOffset = CGPointZero;
        // The alignment runs along the row: left to right in a vertically scrolling layout, top to bottom in
        // a column of a horizontally scrolling one. (It used to be applied to x in both, so a lone item in a
        // horizontal column was never centered.)
        if (horizontalAlignment == PSTFlowLayoutHorizontalAlignmentRight) {
            if (isHorizontal) itemOffset.y += leftOverSpace; else itemOffset.x += leftOverSpace;
        }else if (horizontalAlignment == PSTFlowLayoutHorizontalAlignmentCentered ||
                (horizontalAlignment == PSTFlowLayoutHorizontalAlignmentJustify && usedItemCount == 1)) {
            // Special case one item row to split leftover space in half
            if (isHorizontal) itemOffset.y += leftOverSpace / 2;
            else itemOffset.x += leftOverSpace / 2;
        }

        // calculate the justified spacing among all items in a row if we are using
        // the default PSTFlowLayoutHorizontalAlignmentJustify layout
        CGFloat interSpacing = usedItemCount <= 1 ? 0 : leftOverSpace / (CGFloat)(usedItemCount - 1);

        // calculate row frame as union of all items
        CGRect frame = CGRectZero;
        CGRect itemFrame = (CGRect){.size=fixedItemSize};
        for (itemIndex = 0; itemIndex < count; itemIndex++) {
            PSTGridLayoutItem *item = nil;
            if (!fixedSize) {
                item = [rowItems objectAtIndex:(NSUInteger)itemIndex];
                itemFrame = [item itemFrame];
            }
            // depending on horizontal/vertical for an item size (height/width),
            // we add the minimum separator then an equally distributed spacing
            // (since our default mode is justify) calculated from the total leftover
            // space divided by the number of intervals
            if (isHorizontal) {
                itemFrame.origin.x = centerItems ? (maxScrollDimension - itemFrame.size.width) / 2 : 0;
                itemFrame.origin.y = itemOffset.y;
                itemOffset.y += itemFrame.size.height + verticalInterstice;
                if (horizontalAlignment == PSTFlowLayoutHorizontalAlignmentJustify) {
                    itemOffset.y += interSpacing;
                }
            }else {
                itemFrame.origin.y = centerItems ? (maxScrollDimension - itemFrame.size.height) / 2 : 0;
                itemFrame.origin.x = itemOffset.x;
                itemOffset.x += itemFrame.size.width + horizontalInterstice;
                if (horizontalAlignment == PSTFlowLayoutHorizontalAlignmentJustify) {
                    itemOffset.x += interSpacing;
                }
            }
            item.itemFrame = itemFrame; // might call nil; don't care
            if (rects) [rects addObject:[NSValue valueWithCGRect:itemFrame]]; // layoutRow passes no array: skip the boxing
            frame = CGRectUnion(frame, itemFrame);
        }
        _rowSize = frame.size;
        //        _rowFrame = frame; // set externally
        _isValid = YES;
    }
    return rects;
}

- (void)addItem:(PSTGridLayoutItem *)item {
    [_items addObject:item];
    item.rowObject = self;
    [self invalidate];
}

- (PSTGridLayoutRow *)snapshot {
    PSTGridLayoutRow *snapshotRow = [self.class new];
    snapshotRow.section = self.section;
    snapshotRow.items = self.items;
    snapshotRow.rowSize = self.rowSize;
    snapshotRow.rowFrame = self.rowFrame;
    snapshotRow.index = self.index;
    snapshotRow.complete = self.complete;
    snapshotRow.fixedItemSize = self.fixedItemSize;
    snapshotRow.itemCount = self.itemCount;
    snapshotRow.firstItemIndex = self.firstItemIndex;
    return snapshotRow;
}

- (PSTGridLayoutRow *)copyFromSection:(PSTGridLayoutSection *)section {
    return nil; // ???
}

- (NSInteger)itemCount {
    if (self.fixedItemSize) {
        return _itemCount;
    }else {
        return (NSInteger)self.items.count;
    }
}

@end
