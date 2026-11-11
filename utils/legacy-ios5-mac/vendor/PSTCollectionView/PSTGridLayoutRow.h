//
//  PSTGridLayoutRow.h
//  PSPDFKit
//
//  Copyright (c) 2012-2013 Peter Steinberger. All rights reserved.
//

#import <UIKit/UIKit.h>

@class PSTGridLayoutSection, PSTGridLayoutItem;

@interface PSTGridLayoutRow : NSObject

@property (nonatomic, unsafe_unretained) PSTGridLayoutSection *section;
@property (nonatomic, strong, readonly) NSArray *items;
@property (nonatomic, assign) CGSize rowSize;
@property (nonatomic, assign) CGRect rowFrame;
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, assign) BOOL complete;
@property (nonatomic, assign) BOOL fixedItemSize;

// @steipete addition for row-fastPath
@property (nonatomic, assign) NSInteger itemCount;
// Index, within the section, of this row's first item (set by the section while it lays rows out).
@property (nonatomic, assign) NSInteger firstItemIndex;

//- (PSTGridLayoutRow *)copyFromSection:(PSTGridLayoutSection *)section; // ???

// Add new item to items array.
- (void)addItem:(PSTGridLayoutItem *)item;

// Take another row's finished layout. Valid only for a complete row of a fixed-size section with the
// same item count and alignment as that row (every such row lays out identically).
- (void)adoptLayoutFromRow:(PSTGridLayoutRow *)row;

// Layout current row (if invalid)
- (void)layoutRow;

// @steipete: Helper to save code in PSTCollectionViewFlowLayout.
// Returns the item rects when fixedItemSize is enabled.
- (NSArray *)itemRects;

//  Set current row frame invalid.
- (void)invalidate;

// Copy a snapshot of the current row data
- (PSTGridLayoutRow *)snapshot;

@end
