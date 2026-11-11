//
//  PSTGridLayoutInfo.h
//  PSPDFKit
//
//  Copyright (c) 2012-2013 Peter Steinberger. All rights reserved.
//

#import <UIKit/UIKit.h>

@class PSTGridLayoutSection;

/*
 Every PSTCollectionViewLayout has a PSTGridLayoutInfo attached.
 Is used extensively in PSTCollectionViewFlowLayout.
 */
@interface PSTGridLayoutInfo : NSObject

@property (nonatomic, strong, readonly) NSArray *sections;
@property (nonatomic, strong) NSDictionary *rowAlignmentOptions;
@property (nonatomic, assign) BOOL usesFloatingHeaderFooter;

// Vertical/horizontal dimension (depending on horizontal)
// Used to create row objects
@property (nonatomic, assign) CGFloat dimension;

@property (nonatomic, assign) BOOL horizontal;
@property (nonatomic, assign) BOOL selfSizing;
@property (nonatomic, assign) BOOL leftToRight;
@property (nonatomic, assign) CGSize contentSize;

// Frame for specific PSTGridLayoutItem.
- (CGRect)frameForItemAtIndexPath:(NSIndexPath *)indexPath;
// Incremental scrolling-axis update; propagates the section delta to later sections and content size.
- (BOOL)updatePackedItemAtIndexPath:(NSIndexPath *)indexPath size:(CGSize)size scrollDelta:(CGFloat *)delta;

// Add new section. Invalidates layout.
- (PSTGridLayoutSection *)addSection;

// forces the layout to recompute on next access
// TODO; what's the parameter for?
- (void)invalidate:(BOOL)arg;

// Make a copy of the current state.
- (PSTGridLayoutInfo *)snapshot;

@end
