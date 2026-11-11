//
//  PSTGridLayoutInfo.m
//  PSPDFKit
//
//  Copyright (c) 2012-2013 Peter Steinberger. All rights reserved.
//

#import "PSTGridLayoutInfo.h"
#import "PSTGridLayoutSection.h"
#import "PSTGridLayoutItem.h"

@interface PSTGridLayoutInfo () {
    NSMutableArray *_sections;
    CGRect _visibleBounds;
    CGSize _layoutSize;
    BOOL _isValid;
}
@property (nonatomic, strong) NSMutableArray *sections;
@end

@implementation PSTGridLayoutInfo

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSObject

- (id)init {
    if ((self = [super init])) {
        _sections = [NSMutableArray new];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p dimension:%.1f horizontal:%d contentSize:%@ sections:%@>", NSStringFromClass(self.class), self, self.dimension, self.horizontal, NSStringFromCGSize(self.contentSize), self.sections];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public

- (PSTGridLayoutInfo *)snapshot {
    PSTGridLayoutInfo *layoutInfo = [self.class new];
    layoutInfo.sections = self.sections;
    layoutInfo.rowAlignmentOptions = self.rowAlignmentOptions;
    layoutInfo.usesFloatingHeaderFooter = self.usesFloatingHeaderFooter;
    layoutInfo.dimension = self.dimension;
    layoutInfo.horizontal = self.horizontal;
    layoutInfo.selfSizing = self.selfSizing;
    layoutInfo.leftToRight = self.leftToRight;
    layoutInfo.contentSize = self.contentSize;
    return layoutInfo;
}

- (CGRect)frameForItemAtIndexPath:(NSIndexPath *)indexPath {
    PSTGridLayoutSection *section = [self.sections objectAtIndex:(NSUInteger)indexPath.section];
    CGRect itemFrame;
    if (section.packed) {
        itemFrame = [section packedItemFrameAtIndex:indexPath.row];
    }else if (section.fixedItemSize) {
        itemFrame = (CGRect){.size=section.itemSize};
    }else {
        itemFrame = [[section.items objectAtIndex:(NSUInteger)indexPath.row] itemFrame];
    }
    return itemFrame;
}

- (BOOL)updatePackedItemAtIndexPath:(NSIndexPath *)indexPath size:(CGSize)size scrollDelta:(CGFloat *)delta {
    if (delta) *delta = 0;
    NSInteger sectionIndex = indexPath.section;
    if (!indexPath || sectionIndex < 0 || sectionIndex >= (NSInteger)_sections.count) return NO;
    PSTGridLayoutSection *section = [_sections objectAtIndex:sectionIndex];
    CGFloat change = 0;
    if (![section updatePackedItemAtIndex:indexPath.row size:size scrollDelta:&change]) return NO;
    if (change != 0) {
        for (NSUInteger i = (NSUInteger)sectionIndex + 1; i < _sections.count; i++) {
            PSTGridLayoutSection *later = [_sections objectAtIndex:i];
            CGRect frame = later.frame;
            if (self.horizontal) frame.origin.x += change; else frame.origin.y += change;
            later.frame = frame;
        }
        CGSize content = self.contentSize;
        if (self.horizontal) content.width += change; else content.height += change;
        self.contentSize = content;
    }
    if (delta) *delta = change;
    return YES;
}

- (id)addSection {
    PSTGridLayoutSection *section = [PSTGridLayoutSection new];
    section.rowAlignmentOptions = self.rowAlignmentOptions;
    section.layoutInfo = self;
    [_sections addObject:section];
    [self invalidate:NO];
    return section;
}

- (void)invalidate:(BOOL)arg {
    _isValid = NO;
}

@end
