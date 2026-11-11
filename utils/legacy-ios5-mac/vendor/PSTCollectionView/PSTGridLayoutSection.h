//
//  PSTGridLayoutSection.h
//  PSPDFKit
//
//  Copyright (c) 2012-2013 Peter Steinberger. All rights reserved.
//

#import <UIKit/UIKit.h>

@class PSTGridLayoutInfo, PSTGridLayoutRow, PSTGridLayoutItem;

@interface PSTGridLayoutSection : NSObject

@property (nonatomic, strong, readonly) NSArray *items;
@property (nonatomic, strong, readonly) NSArray *rows;

// fast path for equal-size items
@property (nonatomic, assign) BOOL fixedItemSize;
@property (nonatomic, assign) CGSize itemSize;
// depending on fixedItemSize, this either is a _ivar or queries items.
@property (nonatomic, assign) NSInteger itemsCount;

@property (nonatomic, assign) CGFloat verticalInterstice;
@property (nonatomic, assign) CGFloat horizontalInterstice;
@property (nonatomic, assign) UIEdgeInsets sectionMargins;

@property (nonatomic, assign) CGRect frame;
@property (nonatomic, assign) CGRect headerFrame;
@property (nonatomic, assign) CGRect footerFrame;
@property (nonatomic, assign) CGFloat headerDimension;
@property (nonatomic, assign) CGFloat footerDimension;
@property (nonatomic, unsafe_unretained) PSTGridLayoutInfo *layoutInfo;
@property (nonatomic, strong) NSDictionary *rowAlignmentOptions;
// Values read from rowAlignmentOptions, resolved when it is set so a row does not repeat
// three dictionary lookups per layout. Alignment enum values; see PSTFlowLayoutHorizontalAlignment.
@property (nonatomic, assign, readonly) NSInteger commonRowAlignment;
@property (nonatomic, assign, readonly) NSInteger lastRowAlignment;
@property (nonatomic, assign, readonly) BOOL centersItemsAcrossRow;

@property (nonatomic, assign, readonly) CGFloat otherMargin;
@property (nonatomic, assign, readonly) CGFloat beginMargin;
@property (nonatomic, assign, readonly) CGFloat endMargin;
@property (nonatomic, assign, readonly) CGFloat actualGap;
@property (nonatomic, assign, readonly) CGFloat lastRowBeginMargin;
@property (nonatomic, assign, readonly) CGFloat lastRowEndMargin;
@property (nonatomic, assign, readonly) CGFloat lastRowActualGap;
@property (nonatomic, assign, readonly) BOOL lastRowIncomplete;
@property (nonatomic, assign, readonly) NSInteger itemsByRowCount;
@property (nonatomic, assign, readonly) NSInteger indexOfImcompleteRow; // typo as of iOS6B3

//- (PSTGridLayoutSection *)copyFromLayoutInfo:(PSTGridLayoutInfo *)layoutInfo;

// Row access that works for both layouts. A fixed-size section keeps only two row objects (the first,
// which stands for every complete row, and the last) plus an array of row origins, instead of one row
// object per row; variable-size sections still hold every row in `rows`.
- (NSInteger)rowCount;
- (PSTGridLayoutRow *)rowAtIndex:(NSInteger)index;
- (CGRect)rowFrameAtIndex:(NSInteger)index; // relative to the section, like PSTGridLayoutRow.rowFrame

// Faster variant of invalidate/compute
- (void)recomputeFromIndex:(NSInteger)index;

// Invalidate layout. Destroys rows.
- (void)invalidate;

// Compute layout. Creates rows.
- (void)computeLayout;

- (PSTGridLayoutItem *)addItem;

- (PSTGridLayoutRow *)addRow;

// Copy snapshot of current object
- (PSTGridLayoutSection *)snapshot;

@end
