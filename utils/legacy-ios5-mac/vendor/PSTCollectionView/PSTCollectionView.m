//
//  PSTCollectionView.m
//  PSPDFKit
//
//  Copyright (c) 2012-2013 Peter Steinberger. All rights reserved.
//

#import "PSTCollectionView.h"
#import "PSTCollectionViewData.h"
#import "PSTCollectionViewLayout+Internals.h"
#import "PSTCollectionViewItemKey.h"
#import "PSTCollectionViewFlowLayout.h"
#import "PSTCollectionViewStats.h"

#import <objc/runtime.h>
#if TARGET_IPHONE_SIMULATOR
#import <dlfcn.h>
#endif
#import <tgmath.h>

@interface PSTCollectionViewLayout (Internal)
@property (nonatomic, unsafe_unretained) PSTCollectionView *collectionView;
@end

@interface PSTCollectionViewData (Internal)
- (void)prepareToLoadData;
@end

@interface PSTCollectionViewCell (Internal)
- (void)performSelectionSegue;
@end

@interface PSTCollectionViewUpdateItem ()
- (NSIndexPath *)indexPath;

- (BOOL)isSectionOperation;
@end

@interface PSTCollectionViewLayoutAttributes () {
    char junk[128];
}
@property (nonatomic, copy) NSString *elementKind;
@end

CGFloat PSTSimulatorAnimationDragCoefficient(void);

@class PSTCollectionViewExt;

@interface PSTCollectionView () <UIScrollViewDelegate> {
    // ivar layout needs to EQUAL to UICollectionView.
    PSTCollectionViewLayout *_layout;
    __unsafe_unretained id<PSTCollectionViewDataSource> _dataSource;
    UIView *_backgroundView;
    NSMutableSet *_indexPathsForSelectedItems;
    NSMutableDictionary *_cellReuseQueues;
    NSMutableDictionary *_supplementaryViewReuseQueues;
    NSMutableDictionary *_decorationViewReuseQueues;
    NSMutableSet *_indexPathsForHighlightedItems;
    int _reloadingSuspendedCount;
    PSTCollectionReusableView *_firstResponderView;
    UIView *_newContentView;
    int _firstResponderViewType;
    NSString *_firstResponderViewKind;
    NSIndexPath *_firstResponderIndexPath;
    NSMutableDictionary *_allVisibleViewsDict;
    NSIndexPath *_pendingSelectionIndexPath;
    NSMutableSet *_pendingDeselectionIndexPaths;
    PSTCollectionViewData *_collectionViewData;
    id _update;
    CGRect _visibleBoundRects;
    CGRect _preRotationBounds;
    CGPoint _rotationBoundsOffset;
    int _rotationAnimationCount;
    BOOL _pstMeasuringSelfSizing;
    // Prefetching (iOS 10): items already announced and not yet displayed, and where the last pass stood.
    NSMutableSet *_pstPrefetchedIndexPaths;
    CGPoint _pstPrefetchLastOrigin;
    BOOL _pstPrefetchHasOrigin;
    BOOL _pstPrefetchDisabled;
    __unsafe_unretained id<PSTCollectionViewDataSourcePrefetching> _prefetchDataSource;
    int _updateCount;
    NSMutableArray *_insertItems;
    NSMutableArray *_deleteItems;
    NSMutableArray *_reloadItems;
    NSMutableArray *_moveItems;
    NSArray *_originalInsertItems;
    NSArray *_originalDeleteItems;
    UITouch *_currentTouch;

    void (^_updateCompletionHandler)(BOOL finished);

    NSMutableDictionary *_cellClassDict;
    NSMutableDictionary *_cellNibDict;
    NSMutableDictionary *_supplementaryViewClassDict;
    NSMutableDictionary *_supplementaryViewNibDict;
    NSMutableDictionary *_cellNibExternalObjectsTables;
    NSMutableDictionary *_supplementaryViewNibExternalObjectsTables;
    struct {
        unsigned int delegateShouldHighlightItemAtIndexPath : 1;
        unsigned int delegateDidHighlightItemAtIndexPath : 1;
        unsigned int delegateDidUnhighlightItemAtIndexPath : 1;
        unsigned int delegateShouldSelectItemAtIndexPath : 1;
        unsigned int delegateShouldDeselectItemAtIndexPath : 1;
        unsigned int delegateDidSelectItemAtIndexPath : 1;
        unsigned int delegateDidDeselectItemAtIndexPath : 1;
        unsigned int delegateSupportsMenus : 1;
        unsigned int delegateWillDisplayCell : 1;
        unsigned int delegateWillDisplaySupplementaryView : 1;
        unsigned int delegateDidEndDisplayingCell : 1;
        unsigned int delegateDidEndDisplayingSupplementaryView : 1;
        unsigned int dataSourceNumberOfSections : 1;
        unsigned int dataSourceViewForSupplementaryElement : 1;
        unsigned int reloadSkippedDuringSuspension : 1;
        unsigned int scheduledUpdateVisibleCells : 1;
        unsigned int scheduledUpdateVisibleCellLayoutAttributes : 1;
        unsigned int allowsSelection : 1;
        unsigned int allowsMultipleSelection : 1;
        unsigned int updating : 1;
        unsigned int fadeCellsForBoundsChange : 1;
        unsigned int updatingLayout : 1;
        unsigned int needsReload : 1;
        unsigned int reloading : 1;
        unsigned int skipLayoutDuringSnapshotting : 1;
        unsigned int layoutInvalidatedSinceLastCellUpdate : 1;
        unsigned int doneFirstLayout : 1;
    }_collectionViewFlags;
    CGPoint _lastLayoutOffset;
    // Scratch collections reused by updateVisibleCellsNow: one pass used to
    // allocate two NSSets, an NSArray and an NSMutableDictionary.
    NSMutableSet *_pstVisibleItemKeysScratch;
    NSMutableArray *_pstVisibleItemKeyListScratch;
    NSMutableArray *_pstRetiredViewsScratch;      // retired this pass, enqueued once arrivals exist
    NSMutableArray *_pstRetiredTypesScratch;
    NSMutableArray *_pstVisibleItemKeysToRemoveScratch;
    NSMutableArray *_pstFloatingViewsScratch;
    // Identity of the last completed visible-cell pass.  When the data cache
    // hands back the same attribute generation for the same bounds and no view
    // was added/removed since, repeating the pass can not change anything.
    NSUInteger _pstLastVisibleLayoutAttributesGeneration;
    CGRect _pstLastVisibleBounds;
    BOOL _pstVisibleViewsMatchAttributes;
    // Layout attributes currently being applied while a data-source creates a
    // cell; dequeueReusableCell... reuses them instead of deriving a second copy.
    PSTCollectionViewLayoutAttributes *_pstLayoutAttributesBeingApplied;
    // True while any visible reusable view has zIndex > 0.  addControlledSubview
    // only has to scan/reorder subviews when this is true; the common cell-only
    // grid must not copy and scan the whole subview array per inserted cell.
    BOOL _pstHasFloatingViews;
    char filler[232]; // [HACK] Our class needs to be larger than Apple's class for the superclass change to work.
}
@property (nonatomic, strong) PSTCollectionViewData *collectionViewData;
@property (nonatomic, strong, readonly) PSTCollectionViewExt *extVars;
@property (nonatomic, readonly) id currentUpdate;
@property (nonatomic, readonly) NSDictionary *visibleViewsDict;
@property (nonatomic, assign) CGRect visibleBoundRects;
@end

// Used by PSTCollectionView for external variables.
// (We need to keep the total class size equal to the UICollectionView variant)
@interface PSTCollectionViewExt : NSObject
@property (nonatomic, unsafe_unretained) id<PSTCollectionViewDelegate> collectionViewDelegate;
@property (nonatomic, strong) PSTCollectionViewLayout *nibLayout;
@property (nonatomic, strong) NSDictionary *nibCellsExternalObjects;
@property (nonatomic, strong) NSDictionary *supplementaryViewsExternalObjects;
@property (nonatomic, strong) NSIndexPath *touchingIndexPath;
@property (nonatomic, strong) NSIndexPath *currentIndexPath;
@end

@implementation PSTCollectionViewExt
@end

const char kPSTColletionViewExt;

@implementation PSTCollectionView

@synthesize collectionViewLayout = _layout;
@synthesize currentUpdate = _update;
@synthesize visibleViewsDict = _allVisibleViewsDict;

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - NSObject

// YES when applying `attributes` to `view` would be a complete no-op: the view
// already stores an attribute set with the same visible geometry and every view
// property applyLayoutAttributes: writes already has those values.  This lets a
// scroll pass skip CoreAnimation property writes for the cells that stay put.
static BOOL PSTLayoutAttributesAlreadyApplied(PSTCollectionViewLayoutAttributes *attributes, PSTCollectionReusableView *view) {
    PSTCollectionViewLayoutAttributes *current = view.layoutAttributes;
    if (!current) return NO;
    if (current == attributes) return YES;
    // Identity matters even when the frame is unchanged: cells can be re-indexed
    // by an insert/delete while keeping their geometry.
    if (![current.indexPath isEqual:attributes.indexPath]) return NO;
    if (current.representedElementCategory != attributes.representedElementCategory) return NO;
    if (![current.representedElementKind isEqual:attributes.representedElementKind]) return NO;
    if (!CGRectEqualToRect(current.frame, attributes.frame)) return NO;
    if (current.hidden != attributes.hidden) return NO;
    if (current.alpha != attributes.alpha) return NO;
    if (current.zIndex != attributes.zIndex) return NO;
    if (!CATransform3DEqualToTransform(current.transform3D, attributes.transform3D)) return NO;
    // The view itself must still match as well; otherwise re-apply (and repair).
    if (!CGSizeEqualToSize(view.bounds.size, attributes.size)) return NO;
    if (!CGPointEqualToPoint(view.center, attributes.center)) return NO;
    if (view.hidden != attributes.hidden) return NO;
    if (view.layer.opacity != attributes.alpha) return NO;
    if (view.layer.zPosition != attributes.zIndex) return NO;
    if (!CATransform3DEqualToTransform(view.layer.transform, attributes.transform3D)) return NO;
    return YES;
}

// The compatibility layer mapped a registered UIKit cell class onto the PST
// class; this only has to be resolved once per process, not per created cell.
static Class PSTNativeCollectionViewCellClass(void) {
    static Class cachedClass = Nil;
    static BOOL resolved = NO;
    if (!resolved) {
        cachedClass = NSClassFromString(@"UICollectionViewCell");
        resolved = YES;
    }
    return cachedClass;
}

static Class PSTNativeCollectionReusableViewClass(void) {
    static Class cachedClass = Nil;
    static BOOL resolved = NO;
    if (!resolved) {
        cachedClass = NSClassFromString(@"UICollectionReusableView");
        resolved = YES;
    }
    return cachedClass;
}

static void PSTCollectionViewCommonSetup(PSTCollectionView *_self) {
    _self.allowsSelection = YES;
    _self->_indexPathsForSelectedItems = [NSMutableSet new];
    _self->_indexPathsForHighlightedItems = [NSMutableSet new];
    _self->_cellReuseQueues = [NSMutableDictionary new];
    _self->_supplementaryViewReuseQueues = [NSMutableDictionary new];
    _self->_decorationViewReuseQueues = [NSMutableDictionary new];
    _self->_allVisibleViewsDict = [NSMutableDictionary new];
    _self->_cellClassDict = [NSMutableDictionary new];
    _self->_cellNibDict = [NSMutableDictionary new];
    _self->_supplementaryViewClassDict = [NSMutableDictionary new];
    _self->_supplementaryViewNibDict = [NSMutableDictionary new];

    // add class that saves additional ivars
    objc_setAssociatedObject(_self, &kPSTColletionViewExt, [PSTCollectionViewExt new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (id)initWithFrame:(CGRect)frame {
    return [self initWithFrame:frame collectionViewLayout:nil];
}

- (id)initWithFrame:(CGRect)frame collectionViewLayout:(PSTCollectionViewLayout *)layout {
    if ((self = [super initWithFrame:frame])) {
        // Set self as the UIScrollView's delegate
        [super setDelegate:self];

        PSTCollectionViewCommonSetup(self);
        self.collectionViewLayout = layout;
        _collectionViewData = [[PSTCollectionViewData alloc] initWithCollectionView:self layout:layout];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)inCoder {
    if ((self = [super initWithCoder:inCoder])) {
        // Set self as the UIScrollView's delegate
        [super setDelegate:self];

        PSTCollectionViewCommonSetup(self);

        self.extVars.nibLayout = [inCoder decodeObjectForKey:@"UICollectionLayout"];

        NSDictionary *cellExternalObjects = [inCoder decodeObjectForKey:@"UICollectionViewCellPrototypeNibExternalObjects"];
        NSDictionary *cellNibs = [inCoder decodeObjectForKey:@"UICollectionViewCellNibDict"];

        for (NSString *identifier in cellNibs.allKeys) {
            [_cellNibDict setObject:[cellNibs objectForKey:identifier] forKey:identifier];
        }

        self.extVars.nibCellsExternalObjects = cellExternalObjects;

        NSDictionary *supplementaryViewExternalObjects = [inCoder decodeObjectForKey:@"UICollectionViewSupplementaryViewPrototypeNibExternalObjects"];
        NSDictionary *supplementaryViewNibs = [inCoder decodeObjectForKey:@"UICollectionViewSupplementaryViewNibDict"];

        for (NSString *identifier in supplementaryViewNibs.allKeys) {
            [_supplementaryViewNibDict setObject:[supplementaryViewNibs objectForKey:identifier] forKey:identifier];
        }

        self.extVars.supplementaryViewsExternalObjects = supplementaryViewExternalObjects;
    }
    return self;
}

- (void)awakeFromNib {
    [super awakeFromNib];

    PSTCollectionViewLayout *nibLayout = self.extVars.nibLayout;
    if (nibLayout) {
        self.collectionViewLayout = nibLayout;
        self.extVars.nibLayout = nil;
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ collection view layout: %@", [super description], self.collectionViewLayout];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - UIView

- (void)layoutSubviews {
    [super layoutSubviews];

    // Adding alpha animation to make the relayouting smooth
    if (_collectionViewFlags.fadeCellsForBoundsChange) {
        CATransition *transition = [CATransition animation];
        transition.duration = 0.25f * PSTSimulatorAnimationDragCoefficient();
        transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        transition.type = kCATransitionFade;
        [self.layer addAnimation:transition forKey:@"rotationAnimation"];
    }

    [_collectionViewData validateLayoutInRect:self.bounds];

    // update cells
    if (_collectionViewFlags.fadeCellsForBoundsChange) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
    }

    if (!_collectionViewFlags.updatingLayout)
        [self updateVisibleCellsNow:YES];

    if (_collectionViewFlags.fadeCellsForBoundsChange) {
        [CATransaction commit];
    }

    // do we need to update contentSize?
    CGSize contentSize = [_collectionViewData collectionViewContentRect].size;
    if (!CGSizeEqualToSize(self.contentSize, contentSize)) {
        CGPoint previousContentOffset = self.contentOffset;
        CGSize previousBoundsSize = self.bounds.size;
        self.contentSize = contentSize;

        // if contentSize is different, we need to re-evaluate layout, bounds (contentOffset) might changed.
        // Only run the (expensive) visible-cell pass when the scroll position or
        // size actually moved; a pure content-size change cannot alter which
        // attributes are visible.
        [_collectionViewData validateLayoutInRect:self.bounds];
        if (_collectionViewFlags.updatingLayout ||
            !CGPointEqualToPoint(previousContentOffset, self.contentOffset) ||
            !CGSizeEqualToSize(previousBoundsSize, self.bounds.size)) {
            [self updateVisibleCellsNow:YES];
        }
    }

    if (_backgroundView) {
        _backgroundView.frame = (CGRect){.origin=self.contentOffset, .size=self.bounds.size};
    }

    _collectionViewFlags.fadeCellsForBoundsChange = NO;
    _collectionViewFlags.doneFirstLayout = YES;
}

- (void)setFrame:(CGRect)frame {
    if (!CGRectEqualToRect(frame, self.frame)) {
        CGRect bounds = (CGRect){.origin=self.contentOffset, .size=frame.size};
        BOOL shouldInvalidate = [self.collectionViewLayout shouldInvalidateLayoutForBoundsChange:bounds];
        [super setFrame:frame];
        if (shouldInvalidate) {
            [self invalidateLayout];
            _collectionViewFlags.fadeCellsForBoundsChange = YES;
        }
    }
}

- (void)setBounds:(CGRect)bounds {
    if (!CGRectEqualToRect(bounds, self.bounds)) {
        BOOL shouldInvalidate = [self.collectionViewLayout shouldInvalidateLayoutForBoundsChange:bounds];
        [super setBounds:bounds];
        if (shouldInvalidate) {
            [self invalidateLayout];
            _collectionViewFlags.fadeCellsForBoundsChange = YES;
        }
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - UIScrollViewDelegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(scrollViewDidScroll:)]) {
        [delegate scrollViewDidScroll:scrollView];
    }
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(scrollViewDidZoom:)]) {
        [delegate scrollViewDidZoom:scrollView];
    }
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(scrollViewWillBeginDragging:)]) {
        [delegate scrollViewWillBeginDragging:scrollView];
    }
}

- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset {
    // Let collectionViewLayout decide where to stop.
    *targetContentOffset = [[self collectionViewLayout] targetContentOffsetForProposedContentOffset:*targetContentOffset withScrollingVelocity:velocity];

    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(scrollViewWillEndDragging:withVelocity:targetContentOffset:)]) {
        //if collectionViewDelegate implements this method, it may modify targetContentOffset as well
        [delegate scrollViewWillEndDragging:scrollView withVelocity:velocity targetContentOffset:targetContentOffset];
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(scrollViewDidEndDragging:willDecelerate:)]) {
        [delegate scrollViewDidEndDragging:scrollView willDecelerate:decelerate];
    }

    // if we are in the middle of a cell touch event, perform the "touchEnded" simulation
    if (self.extVars.touchingIndexPath) {
        [self cellTouchCancelled];
    }
}

- (void)scrollViewWillBeginDecelerating:(UIScrollView *)scrollView {
    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(scrollViewWillBeginDecelerating:)]) {
        [delegate scrollViewWillBeginDecelerating:scrollView];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(scrollViewDidEndDecelerating:)]) {
        [delegate scrollViewDidEndDecelerating:scrollView];
    }
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(scrollViewDidEndScrollingAnimation:)]) {
        [delegate scrollViewDidEndScrollingAnimation:scrollView];
    }
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(viewForZoomingInScrollView:)]) {
        return [delegate viewForZoomingInScrollView:scrollView];
    }
    return nil;
}

- (void)scrollViewWillBeginZooming:(UIScrollView *)scrollView withView:(UIView *)view {
    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(scrollViewWillBeginZooming:withView:)]) {
        [delegate scrollViewWillBeginZooming:scrollView withView:view];
    }
}

- (void)scrollViewDidEndZooming:(UIScrollView *)scrollView withView:(UIView *)view atScale:(CGFloat)scale {
    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(scrollViewDidEndZooming:withView:atScale:)]) {
        [delegate scrollViewDidEndZooming:scrollView withView:view atScale:scale];
    }
}

- (BOOL)scrollViewShouldScrollToTop:(UIScrollView *)scrollView {
    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(scrollViewShouldScrollToTop:)]) {
        return [delegate scrollViewShouldScrollToTop:scrollView];
    }
    return YES;
}

- (void)scrollViewDidScrollToTop:(UIScrollView *)scrollView {
    id<PSTCollectionViewDelegate> delegate = self.extVars.collectionViewDelegate;
    if ((id)delegate != self && [delegate respondsToSelector:@selector(scrollViewDidScrollToTop:)]) {
        [delegate scrollViewDidScrollToTop:scrollView];
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Public

- (void)registerClass:(Class)cellClass forCellWithReuseIdentifier:(NSString *)identifier {
    NSParameterAssert(cellClass);
    NSParameterAssert(identifier);
    [_cellClassDict setObject:cellClass forKey:identifier];
}

- (void)registerClass:(Class)viewClass forSupplementaryViewOfKind:(NSString *)elementKind withReuseIdentifier:(NSString *)identifier {
    NSParameterAssert(viewClass);
    NSParameterAssert(elementKind);
    NSParameterAssert(identifier);
    NSString *kindAndIdentifier = [NSString stringWithFormat:@"%@/%@", elementKind, identifier];
    [_supplementaryViewClassDict setObject:viewClass forKey:kindAndIdentifier];
}

- (void)registerNib:(UINib *)nib forCellWithReuseIdentifier:(NSString *)identifier {
    NSArray *topLevelObjects = [nib instantiateWithOwner:nil options:nil];
#pragma unused(topLevelObjects)
    NSAssert(topLevelObjects.count == 1 && [[topLevelObjects objectAtIndex:0] isKindOfClass:PSTCollectionViewCell.class], @"must contain exactly 1 top level object which is a PSTCollectionViewCell");

    [_cellNibDict setObject:nib forKey:identifier];
}

- (void)registerNib:(UINib *)nib forSupplementaryViewOfKind:(NSString *)kind withReuseIdentifier:(NSString *)identifier {
    NSArray *topLevelObjects = [nib instantiateWithOwner:nil options:nil];
#pragma unused(topLevelObjects)
    NSAssert(topLevelObjects.count == 1 && [[topLevelObjects objectAtIndex:0] isKindOfClass:PSTCollectionReusableView.class], @"must contain exactly 1 top level object which is a PSTCollectionReusableView");

    NSString *kindAndIdentifier = [NSString stringWithFormat:@"%@/%@", kind, identifier];
    [_supplementaryViewNibDict setObject:nib forKey:kindAndIdentifier];
}

- (id)dequeueReusableCellWithReuseIdentifier:(NSString *)identifier forIndexPath:(NSIndexPath *)indexPath {
    // de-queue cell (if available)
    NSMutableArray *reusableCells = [_cellReuseQueues objectForKey:identifier];
    PSTCollectionViewCell *cell = [reusableCells lastObject];
    PSTCollectionViewLayoutAttributes *attributes = nil;
    if (_pstLayoutAttributesBeingApplied &&
        _pstLayoutAttributesBeingApplied.isCell &&
        [_pstLayoutAttributesBeingApplied.indexPath isEqual:indexPath]) {
        // Cell creation from updateVisibleCellsNow: this pass already computed the
        // attributes, no need to derive them a second time.
        attributes = _pstLayoutAttributesBeingApplied;
        PSTCollectionViewStatsCountersStorage[PSTStatItemDerivationsCached]++;
    } else {
        attributes = [self.collectionViewLayout layoutAttributesForItemAtIndexPath:indexPath];
    }

    if (cell) {
        // Native UIKit prepares a queued view when it is requested again, not
        // when it stops displaying. Keep delegate-observable state until then.
        [cell prepareForReuse];
        [reusableCells removeObjectAtIndex:reusableCells.count - 1];
        cell.hidden = NO;
    }else {
        if ([_cellNibDict objectForKey:identifier]) {
            // Cell was registered via registerNib:forCellWithReuseIdentifier:
            UINib *cellNib = [_cellNibDict objectForKey:identifier];
            NSDictionary *externalObjects = [self.extVars.nibCellsExternalObjects objectForKey:identifier];
            if (externalObjects) {
                cell = [[cellNib instantiateWithOwner:self options:@{UINibExternalObjects : externalObjects}] objectAtIndex:0];
            }else {
                cell = [[cellNib instantiateWithOwner:self options:nil] objectAtIndex:0];
            }
        }else {
            Class cellClass = [_cellClassDict objectForKey:identifier];
            // compatibility layer
            Class collectionViewCellClass = PSTNativeCollectionViewCellClass();
            if (collectionViewCellClass && [cellClass isEqual:collectionViewCellClass]) {
                cellClass = PSTCollectionViewCell.class;
            }
            if (cellClass == nil) {
                @throw [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"Class not registered for identifier %@", identifier] userInfo:nil];
            }
            if (attributes) {
                cell = [[cellClass alloc] initWithFrame:attributes.frame];
            }else {
                cell = [cellClass new];
            }
        }
        cell.collectionView = self;
        cell.reuseIdentifier = identifier;
    }

    [cell applyLayoutAttributes:attributes];

    return cell;
}

- (id)dequeueReusableSupplementaryViewOfKind:(NSString *)elementKind withReuseIdentifier:(NSString *)identifier forIndexPath:(NSIndexPath *)indexPath {
    NSString *kindAndIdentifier = [NSString stringWithFormat:@"%@/%@", elementKind, identifier];
    NSMutableArray *reusableViews = [_supplementaryViewReuseQueues objectForKey:kindAndIdentifier];
    PSTCollectionReusableView *view = [reusableViews lastObject];
    if (view) {
        [view prepareForReuse];
        [reusableViews removeObjectAtIndex:reusableViews.count - 1];
        view.hidden = NO;
    }else {
        if ([_supplementaryViewNibDict objectForKey:kindAndIdentifier]) {
            // supplementary view was registered via registerNib:forCellWithReuseIdentifier:
            UINib *supplementaryViewNib = [_supplementaryViewNibDict objectForKey:kindAndIdentifier];
            NSDictionary *externalObjects = [self.extVars.supplementaryViewsExternalObjects objectForKey:kindAndIdentifier];
            if (externalObjects) {
                view = [[supplementaryViewNib instantiateWithOwner:self options:@{UINibExternalObjects : externalObjects}] objectAtIndex:0];
            }else {
                view = [[supplementaryViewNib instantiateWithOwner:self options:nil] objectAtIndex:0];
            }
        }else {
            Class viewClass = [_supplementaryViewClassDict objectForKey:kindAndIdentifier];
            Class reusableViewClass = PSTNativeCollectionReusableViewClass();
            if (reusableViewClass && [viewClass isEqual:reusableViewClass]) {
                viewClass = PSTCollectionReusableView.class;
            }
            if (viewClass == nil) {
                @throw [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"Class not registered for kind/identifier %@", kindAndIdentifier] userInfo:nil];
            }
            if (self.collectionViewLayout) {
                PSTCollectionViewLayoutAttributes *attributes = nil;
                if (_pstLayoutAttributesBeingApplied &&
                    !_pstLayoutAttributesBeingApplied.isCell &&
                    [_pstLayoutAttributesBeingApplied.representedElementKind isEqual:elementKind] &&
                    [_pstLayoutAttributesBeingApplied.indexPath isEqual:indexPath]) {
                    attributes = _pstLayoutAttributesBeingApplied;
                    PSTCollectionViewStatsCountersStorage[PSTStatItemDerivationsCached]++;
                } else {
                    attributes = [self.collectionViewLayout layoutAttributesForSupplementaryViewOfKind:elementKind atIndexPath:indexPath];
                }
                if (attributes) {
                    view = [[viewClass alloc] initWithFrame:attributes.frame];
                }
            }else {
                view = [viewClass new];
            }
        }
        view.collectionView = self;
        view.reuseIdentifier = identifier;
    }

    return view;
}

- (id)dequeueReusableOrCreateDecorationViewOfKind:(NSString *)elementKind forIndexPath:(NSIndexPath *)indexPath {
    NSMutableArray *reusableViews = [_decorationViewReuseQueues objectForKey:elementKind];
    PSTCollectionReusableView *view = [reusableViews lastObject];
    PSTCollectionViewLayout *collectionViewLayout = self.collectionViewLayout;
    PSTCollectionViewLayoutAttributes *attributes = [collectionViewLayout layoutAttributesForDecorationViewOfKind:elementKind atIndexPath:indexPath];

    if (view) {
        [view prepareForReuse];
        [reusableViews removeObjectAtIndex:reusableViews.count - 1];
        view.hidden = NO;
    }else {
        NSDictionary *decorationViewNibDict = collectionViewLayout.decorationViewNibDict;
        NSDictionary *decorationViewExternalObjects = collectionViewLayout.decorationViewExternalObjectsTables;
        if ([decorationViewNibDict objectForKey:elementKind]) {
            // supplementary view was registered via registerNib:forCellWithReuseIdentifier:
            UINib *supplementaryViewNib = [decorationViewNibDict objectForKey:elementKind];
            NSDictionary *externalObjects = [decorationViewExternalObjects objectForKey:elementKind];
            if (externalObjects) {
                view = [[supplementaryViewNib instantiateWithOwner:self options:@{UINibExternalObjects : externalObjects}] objectAtIndex:0];
            }else {
                view = [[supplementaryViewNib instantiateWithOwner:self options:nil] objectAtIndex:0];
            }
        }else {
            NSDictionary *decorationViewClassDict = collectionViewLayout.decorationViewClassDict;
            Class viewClass = [decorationViewClassDict objectForKey:elementKind];
            Class reusableViewClass = PSTNativeCollectionReusableViewClass();
            if (reusableViewClass && [viewClass isEqual:reusableViewClass]) {
                viewClass = PSTCollectionReusableView.class;
            }
            if (viewClass == nil) {
                @throw [NSException exceptionWithName:NSInvalidArgumentException reason:[NSString stringWithFormat:@"Class not registered for identifier %@", elementKind] userInfo:nil];
            }
            if (attributes) {
                view = [[viewClass alloc] initWithFrame:attributes.frame];
            }else {
                view = [viewClass new];
            }
        }
        view.collectionView = self;
        view.reuseIdentifier = elementKind;
    }

    [view applyLayoutAttributes:attributes];

    return view;
}

- (NSArray *)allCells {
    NSMutableArray *cells = [NSMutableArray arrayWithCapacity:_allVisibleViewsDict.count];
    NSEnumerator *enumerator = [_allVisibleViewsDict objectEnumerator];
    id evaluatedObject = nil;
    while ((evaluatedObject = [enumerator nextObject]) != nil) {
        if ([evaluatedObject isKindOfClass:PSTCollectionViewCell.class]) {
            [cells addObject:evaluatedObject];
        }
    }
    return cells;
}

- (NSArray *)visibleCells {
    NSMutableArray *cells = [NSMutableArray arrayWithCapacity:_allVisibleViewsDict.count];
    NSEnumerator *enumerator = [_allVisibleViewsDict objectEnumerator];
    id evaluatedObject = nil;
    while ((evaluatedObject = [enumerator nextObject]) != nil) {
        if ([evaluatedObject isKindOfClass:PSTCollectionViewCell.class] && CGRectIntersectsRect(self.bounds, [evaluatedObject frame])) {
            [cells addObject:evaluatedObject];
        }
    }
    return cells;
}

- (void)reloadData {
    if (_reloadingSuspendedCount != 0) return;
    [_pstPrefetchedIndexPaths removeAllObjects];
    _pstPrefetchHasOrigin = NO;
    // Index paths identify new content after a reload; neither measured sizes nor
    // the stable-item set may survive into the next data generation.
    if ([_layout isKindOfClass:[PSTCollectionViewFlowLayout class]])
        [(PSTCollectionViewFlowLayout *)_layout pstResetMeasuredSizes];
    [self invalidateLayout];
    // Retire every visible view the way UIKit does: remove it, tell the delegate it stopped being
    // displayed, and return it to its reuse queue (so the next pass dequeues instead of allocating).
    // Detach the old dictionary before callbacks. Its entries are already the
    // retirement snapshot; copying them and then clearing the original doubles
    // the key/value retain-and-release work on every reload.
    NSDictionary *retiring = _allVisibleViewsDict;
    _allVisibleViewsDict = [NSMutableDictionary new];
    // UIKit's retire order is an unspecified hash order; use a deterministic one.
    NSArray *retiringKeys = [[retiring allKeys] sortedArrayUsingComparator:^NSComparisonResult(PSTCollectionViewItemKey *x, PSTCollectionViewItemKey *y) {
        if (x.type != y.type) return x.type < y.type ? NSOrderedAscending : NSOrderedDescending;
        return [x.indexPath compare:y.indexPath];
    }];
    for (PSTCollectionViewItemKey *key in retiringKeys) {
        id obj = [retiring objectForKey:key];
        if (![obj isKindOfClass:UIView.class]) continue;
        PSTCollectionReusableView *view = obj;
        view.hidden = YES; // stays attached until reused, as under UIKit
        if (key.type == PSTCollectionViewItemTypeCell) {
            if (_collectionViewFlags.delegateDidEndDisplayingCell)
                [self.delegate collectionView:self didEndDisplayingCell:(PSTCollectionViewCell *)view forItemAtIndexPath:key.indexPath];
            [self reuseCell:(PSTCollectionViewCell *)view];
        } else if (key.type == PSTCollectionViewItemTypeSupplementaryView) {
            if (_collectionViewFlags.delegateDidEndDisplayingSupplementaryView)
                [self.delegate collectionView:self didEndDisplayingSupplementaryView:view forElementOfKind:key.identifier atIndexPath:key.indexPath];
            [self reuseSupplementaryView:view];
        } else if (key.type == PSTCollectionViewItemTypeDecorationView) {
            if (_collectionViewFlags.delegateDidEndDisplayingSupplementaryView)
                [self.delegate collectionView:self didEndDisplayingSupplementaryView:view forElementOfKind:key.identifier atIndexPath:key.indexPath];
            [self reuseDecorationView:view];
        }
    }

    for (NSIndexPath *indexPath in _indexPathsForSelectedItems) {
        PSTCollectionViewCell *selectedCell = [self cellForItemAtIndexPath:indexPath];
        selectedCell.selected = NO;
        selectedCell.highlighted = NO;
    }
    [_indexPathsForSelectedItems removeAllObjects];
    [_indexPathsForHighlightedItems removeAllObjects];
    _pstVisibleViewsMatchAttributes = NO;
    _pstHasFloatingViews = NO;

    [self setNeedsLayout];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Query Grid

- (NSInteger)numberOfSections {
    return [_collectionViewData numberOfSections];
}

- (NSInteger)numberOfItemsInSection:(NSInteger)section {
    return [_collectionViewData numberOfItemsInSection:section];
}

- (PSTCollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    return [[self collectionViewLayout] layoutAttributesForItemAtIndexPath:indexPath];
}

- (PSTCollectionViewLayoutAttributes *)layoutAttributesForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    return [[self collectionViewLayout] layoutAttributesForSupplementaryViewOfKind:kind atIndexPath:indexPath];
}

- (NSIndexPath *)indexPathForItemAtPoint:(CGPoint)point {
    PSTCollectionViewLayoutAttributes *attributes = [[self.collectionViewLayout layoutAttributesForElementsInRect:CGRectMake(point.x, point.y, 1, 1)] lastObject];
    return attributes.indexPath;
}

- (NSIndexPath *)indexPathForCell:(PSTCollectionViewCell *)cell {
    __block NSIndexPath *indexPath = nil;
    [_allVisibleViewsDict enumerateKeysAndObjectsWithOptions:kNilOptions usingBlock:^(id key, id obj, BOOL *stop) {
        PSTCollectionViewItemKey *itemKey = (PSTCollectionViewItemKey *)key;
        if (itemKey.type == PSTCollectionViewItemTypeCell) {
            PSTCollectionViewCell *currentCell = (PSTCollectionViewCell *)obj;
            if (currentCell == cell) {
                indexPath = itemKey.indexPath;
                *stop = YES;
            }
        }
    }];
    return indexPath;
}

- (NSArray *)visibleSupplementaryViewsOfKind:(NSString *)elementKind {
    NSMutableArray *views = [NSMutableArray array];
    [_allVisibleViewsDict enumerateKeysAndObjectsUsingBlock:^(PSTCollectionViewItemKey *key, id view, BOOL *stop) {
        if (key.type != PSTCollectionViewItemTypeSupplementaryView) return;
        if (elementKind && ![key.identifier isEqualToString:elementKind]) return;
        [views addObject:view];
    }];
    return views;
}

- (NSArray *)indexPathsForVisibleSupplementaryElementsOfKind:(NSString *)elementKind {
    NSMutableArray *paths = [NSMutableArray array];
    [_allVisibleViewsDict enumerateKeysAndObjectsUsingBlock:^(PSTCollectionViewItemKey *key, id view, BOOL *stop) {
        if (key.type != PSTCollectionViewItemTypeSupplementaryView) return;
        if (elementKind && ![key.identifier isEqualToString:elementKind]) return;
        [paths addObject:key.indexPath];
    }];
    return paths;
}

- (PSTCollectionViewCell *)cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    // NSInteger index = [_collectionViewData globalIndexForItemAtIndexPath:indexPath];
    // TODO Apple uses some kind of globalIndex for this.
    __block PSTCollectionViewCell *cell = nil;
    [_allVisibleViewsDict enumerateKeysAndObjectsWithOptions:0 usingBlock:^(id key, id obj, BOOL *stop) {
        PSTCollectionViewItemKey *itemKey = (PSTCollectionViewItemKey *)key;
        if (itemKey.type == PSTCollectionViewItemTypeCell) {
            if ([itemKey.indexPath isEqual:indexPath]) {
                cell = obj;
                *stop = YES;
            }
        }
    }];
    return cell;
}

- (NSArray *)indexPathsForVisibleItems {
    NSArray *visibleCells = self.visibleCells;
    NSMutableArray *indexPaths = [NSMutableArray arrayWithCapacity:visibleCells.count];

    [visibleCells enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        PSTCollectionViewCell *cell = (PSTCollectionViewCell *)obj;
        [indexPaths addObject:cell.layoutAttributes.indexPath];
    }];

    return indexPaths;
}

// returns nil or an array of selected index paths
- (NSArray *)indexPathsForSelectedItems {
    return [_indexPathsForSelectedItems allObjects];
}

// Interacting with the collection view.
- (void)scrollToItemAtIndexPath:(NSIndexPath *)indexPath atScrollPosition:(PSTCollectionViewScrollPosition)scrollPosition animated:(BOOL)animated {
    // Ensure grid is laid out; else we can't scroll.
    [self layoutSubviews];

    PSTCollectionViewLayoutAttributes *layoutAttributes = [self.collectionViewLayout layoutAttributesForItemAtIndexPath:indexPath];
    if (layoutAttributes) {
        CGRect targetRect = [self makeRect:layoutAttributes.frame toScrollPosition:scrollPosition];
        [self pstScrollItemFrame:layoutAttributes.frame targetRect:targetRect position:scrollPosition animated:animated];
        if (!animated && [_layout isKindOfClass:[PSTCollectionViewFlowLayout class]] &&
            [(PSTCollectionViewFlowLayout *)_layout pstUsesSelfSizing]) {
            // The first offset uses estimates. Measuring the newly visible cells can
            // shift the requested item's frame past that viewport; settle and retarget
            // the same item, without requiring the caller to issue another scroll.
            for (NSUInteger attempt = 0; attempt < 6; attempt++) {
                [self layoutSubviews];
                PSTCollectionViewLayoutAttributes *resolved = [_layout layoutAttributesForItemAtIndexPath:indexPath];
                if (!resolved) break;
                CGRect resolvedRect = [self makeRect:resolved.frame toScrollPosition:scrollPosition];
                CGPoint previousOffset = self.contentOffset;
                [self pstScrollItemFrame:resolved.frame targetRect:resolvedRect position:scrollPosition animated:NO];
                if (CGPointEqualToPoint(previousOffset, self.contentOffset)) break;
            }
        }
    }
}

- (void)pstScrollItemFrame:(CGRect)itemFrame targetRect:(CGRect)targetRect position:(PSTCollectionViewScrollPosition)position animated:(BOOL)animated {
    NSUInteger vertical = position & 0x07;
    NSUInteger horizontal = position & 0x38;
    if (!vertical && !horizontal) {
        [self scrollRectToVisible:targetRect animated:animated];
        return;
    }
    // Explicit vertical alignment uses the inset-adjusted viewport. Asking
    // scrollRectToVisible to show a full-bounds rect chooses its own edge when
    // that rect is larger than the usable viewport, losing top/center alignment.
    UIEdgeInsets inset = self.contentInset;
    CGPoint offset = self.contentOffset;
    if (vertical) {
        CGFloat available = MAX(0, self.bounds.size.height - inset.top - inset.bottom);
        CGFloat y = CGRectGetMinY(itemFrame) - inset.top;
        if (vertical == PSTCollectionViewScrollPositionCenteredVertically)
            y = CGRectGetMidY(itemFrame) - inset.top - available / 2;
        else if (vertical == PSTCollectionViewScrollPositionBottom)
            y = CGRectGetMaxY(itemFrame) - self.bounds.size.height + inset.bottom;
        CGFloat maximum = MAX(-inset.top, self.contentSize.height - self.bounds.size.height + inset.bottom);
        offset.y = MIN(maximum, MAX(-inset.top, y));
    }
    if (horizontal) {
        CGFloat available = MAX(0, self.bounds.size.width - inset.left - inset.right);
        CGFloat x = CGRectGetMinX(itemFrame) - inset.left;
        if (horizontal == PSTCollectionViewScrollPositionCenteredHorizontally)
            x = CGRectGetMidX(itemFrame) - inset.left - available / 2;
        else if (horizontal == PSTCollectionViewScrollPositionRight)
            x = CGRectGetMaxX(itemFrame) - self.bounds.size.width + inset.right;
        CGFloat maximum = MAX(-inset.left, self.contentSize.width - self.bounds.size.width + inset.right);
        offset.x = MIN(maximum, MAX(-inset.left, x));
    }
    [self setContentOffset:offset animated:animated];
}

- (CGRect)makeRect:(CGRect)targetRect toScrollPosition:(PSTCollectionViewScrollPosition)scrollPosition {
    // split parameters
    NSUInteger verticalPosition = scrollPosition&0x07; // 0000 0111
    NSUInteger horizontalPosition = scrollPosition&0x38; // 0011 1000

    if (verticalPosition != PSTCollectionViewScrollPositionNone
            && verticalPosition != PSTCollectionViewScrollPositionTop
            && verticalPosition != PSTCollectionViewScrollPositionCenteredVertically
            && verticalPosition != PSTCollectionViewScrollPositionBottom) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"PSTCollectionViewScrollPosition: attempt to use a scroll position with multiple vertical positioning styles" userInfo:nil];
    }

    if (horizontalPosition != PSTCollectionViewScrollPositionNone
            && horizontalPosition != PSTCollectionViewScrollPositionLeft
            && horizontalPosition != PSTCollectionViewScrollPositionCenteredHorizontally
            && horizontalPosition != PSTCollectionViewScrollPositionRight) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"PSTCollectionViewScrollPosition: attempt to use a scroll position with multiple horizontal positioning styles" userInfo:nil];
    }

    CGRect frame = self.layer.bounds;
    CGFloat calculateX;
    CGFloat calculateY;

    switch (verticalPosition) {
        case PSTCollectionViewScrollPositionCenteredVertically:
            calculateY = fmax(targetRect.origin.y - ((frame.size.height / 2) - (targetRect.size.height / 2)), -self.contentInset.top);
            targetRect = CGRectMake(targetRect.origin.x, calculateY, targetRect.size.width, frame.size.height);
            break;
        case PSTCollectionViewScrollPositionTop:
            targetRect = CGRectMake(targetRect.origin.x, targetRect.origin.y, targetRect.size.width, frame.size.height);
            break;

        case PSTCollectionViewScrollPositionBottom:
            calculateY = fmax(targetRect.origin.y - (frame.size.height - targetRect.size.height), -self.contentInset.top);
            targetRect = CGRectMake(targetRect.origin.x, calculateY, targetRect.size.width, frame.size.height);
            break;
    }

    switch (horizontalPosition) {
        case PSTCollectionViewScrollPositionCenteredHorizontally:
            calculateX = targetRect.origin.x - ((frame.size.width / 2) - (targetRect.size.width / 2));
            targetRect = CGRectMake(calculateX, targetRect.origin.y, frame.size.width, targetRect.size.height);
            break;

        case PSTCollectionViewScrollPositionLeft:
            targetRect = CGRectMake(targetRect.origin.x, targetRect.origin.y, frame.size.width, targetRect.size.height);
            break;

        case PSTCollectionViewScrollPositionRight:
            calculateX = targetRect.origin.x - (frame.size.width - targetRect.size.width);
            targetRect = CGRectMake(calculateX, targetRect.origin.y, frame.size.width, targetRect.size.height);
            break;
    }

    return targetRect;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Touch Handling

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];

    // reset touching state vars
    self.extVars.touchingIndexPath = nil;
    self.extVars.currentIndexPath = nil;

    CGPoint touchPoint = [[touches anyObject] locationInView:self];
    NSIndexPath *indexPath = [self indexPathForItemAtPoint:touchPoint];
    if (indexPath && self.allowsSelection) {
        if (![self highlightItemAtIndexPath:indexPath animated:YES scrollPosition:PSTCollectionViewScrollPositionNone notifyDelegate:YES])
            return;

        self.extVars.touchingIndexPath = indexPath;
        self.extVars.currentIndexPath = indexPath;

        if (!self.allowsMultipleSelection) {
            // temporally unhighlight background on touchesBegan (keeps selected by _indexPathsForSelectedItems)
            // single-select only mode only though
            NSIndexPath *tempDeselectIndexPath = _indexPathsForSelectedItems.anyObject;
            if (tempDeselectIndexPath && ![tempDeselectIndexPath isEqual:self.extVars.touchingIndexPath]) {
                // iOS6 UICollectionView deselects cell without notification
                PSTCollectionViewCell *selectedCell = [self cellForItemAtIndexPath:tempDeselectIndexPath];
                selectedCell.selected = NO;
            }
        }
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];

    // allows moving between highlight and unhighlight state only if setHighlighted is not overwritten
    if (self.extVars.touchingIndexPath) {
        CGPoint touchPoint = [[touches anyObject] locationInView:self];
        NSIndexPath *indexPath = [self indexPathForItemAtPoint:touchPoint];

        // moving out of bounds
        if ([self.extVars.currentIndexPath isEqual:self.extVars.touchingIndexPath] &&
                ![indexPath isEqual:self.extVars.touchingIndexPath] &&
                [self unhighlightItemAtIndexPath:self.extVars.touchingIndexPath animated:YES notifyDelegate:YES shouldCheckHighlight:YES]) {
            self.extVars.currentIndexPath = indexPath;
            // moving back into the original touching cell
        }else if (![self.extVars.currentIndexPath isEqual:self.extVars.touchingIndexPath] &&
                [indexPath isEqual:self.extVars.touchingIndexPath]) {
            [self highlightItemAtIndexPath:self.extVars.touchingIndexPath animated:YES scrollPosition:PSTCollectionViewScrollPositionNone notifyDelegate:YES];
            self.extVars.currentIndexPath = self.extVars.touchingIndexPath;
        }
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];

    if (self.extVars.touchingIndexPath) {
        // first unhighlight the touch operation
        [self unhighlightItemAtIndexPath:self.extVars.touchingIndexPath animated:YES notifyDelegate:YES];

        CGPoint touchPoint = [[touches anyObject] locationInView:self];
        NSIndexPath *indexPath = [self indexPathForItemAtPoint:touchPoint];
        if ([indexPath isEqual:self.extVars.touchingIndexPath]) {
            [self userSelectedItemAtIndexPath:indexPath];
        }
        else if (!self.allowsMultipleSelection) {
            NSIndexPath *tempDeselectIndexPath = _indexPathsForSelectedItems.anyObject;
            if (tempDeselectIndexPath && ![tempDeselectIndexPath isEqual:self.extVars.touchingIndexPath]) {
                [self cellTouchCancelled];
            }
        }

        // for pedantic reasons only - always set to nil on touchesBegan
        self.extVars.touchingIndexPath = nil;
        self.extVars.currentIndexPath = nil;
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];

    // do not mark touchingIndexPath as nil because whoever cancelled this touch will need to signal a touch up event later
    if (self.extVars.touchingIndexPath) {
        // first unhighlight the touch operation
        [self unhighlightItemAtIndexPath:self.extVars.touchingIndexPath animated:YES notifyDelegate:YES];
    }
}

- (void)cellTouchCancelled {
    // turn on ALL the *should be selected* cells (iOS6 UICollectionView does no state keeping or other fancy optimizations)
    // there should be no notifications as this is a silent "turn everything back on"
    for (NSIndexPath *tempDeselectedIndexPath in [_indexPathsForSelectedItems copy]) {
        PSTCollectionViewCell *selectedCell = [self cellForItemAtIndexPath:tempDeselectedIndexPath];
        selectedCell.selected = YES;
    }
}

- (void)userSelectedItemAtIndexPath:(NSIndexPath *)indexPath {
    if (self.allowsMultipleSelection && [_indexPathsForSelectedItems containsObject:indexPath]) {
        [self deselectItemAtIndexPath:indexPath animated:YES notifyDelegate:YES];
    }
    else if (self.allowsSelection) {
        [self selectItemAtIndexPath:indexPath animated:YES scrollPosition:PSTCollectionViewScrollPositionNone notifyDelegate:YES];
    }
}

// select item, notify delegate (internal)
- (void)selectItemAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated scrollPosition:(PSTCollectionViewScrollPosition)scrollPosition notifyDelegate:(BOOL)notifyDelegate {
    if (self.allowsMultipleSelection && [_indexPathsForSelectedItems containsObject:indexPath]) {
        BOOL shouldDeselect = YES;
        if (notifyDelegate && _collectionViewFlags.delegateShouldDeselectItemAtIndexPath) {
            shouldDeselect = [self.delegate collectionView:self shouldDeselectItemAtIndexPath:indexPath];
        }

        if (shouldDeselect) {
            [self deselectItemAtIndexPath:indexPath animated:animated notifyDelegate:notifyDelegate];
        }
    }
    else {
        // either single selection, or wasn't already selected in multiple selection mode
        BOOL shouldSelect = YES;
        if (notifyDelegate && _collectionViewFlags.delegateShouldSelectItemAtIndexPath) {
            shouldSelect = [self.delegate collectionView:self shouldSelectItemAtIndexPath:indexPath];
        }

        if (!self.allowsMultipleSelection) {
            // now unselect the previously selected cell for single selection
            NSIndexPath *tempDeselectIndexPath = _indexPathsForSelectedItems.anyObject;
            if (tempDeselectIndexPath && ![tempDeselectIndexPath isEqual:indexPath]) {
                [self deselectItemAtIndexPath:tempDeselectIndexPath animated:YES notifyDelegate:YES];
            }
        }

        if (shouldSelect) {
            PSTCollectionViewCell *selectedCell = [self cellForItemAtIndexPath:indexPath];
            selectedCell.selected = YES;

            [_indexPathsForSelectedItems addObject:indexPath];

            [selectedCell performSelectionSegue];

            if (scrollPosition != PSTCollectionViewScrollPositionNone) {
                [self scrollToItemAtIndexPath:indexPath atScrollPosition:scrollPosition animated:animated];
            }

            if (notifyDelegate && _collectionViewFlags.delegateDidSelectItemAtIndexPath) {
                [self.delegate collectionView:self didSelectItemAtIndexPath:indexPath];
            }
        }
    }
}

- (void)selectItemAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated scrollPosition:(PSTCollectionViewScrollPosition)scrollPosition {
    [self selectItemAtIndexPath:indexPath animated:animated scrollPosition:scrollPosition notifyDelegate:NO];
}

- (void)deselectItemAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated {
    [self deselectItemAtIndexPath:indexPath animated:animated notifyDelegate:NO];
}

- (void)deselectItemAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated notifyDelegate:(BOOL)notifyDelegate {
    BOOL shouldDeselect = YES;
    // deselect only relevant during multi mode
    if (self.allowsMultipleSelection && notifyDelegate && _collectionViewFlags.delegateShouldDeselectItemAtIndexPath) {
        shouldDeselect = [self.delegate collectionView:self shouldDeselectItemAtIndexPath:indexPath];
    }

    if (shouldDeselect && [_indexPathsForSelectedItems containsObject:indexPath]) {
        PSTCollectionViewCell *selectedCell = [self cellForItemAtIndexPath:indexPath];
        if (selectedCell) {
            if (selectedCell.selected) {
                selectedCell.selected = NO;
            }
        }
        [_indexPathsForSelectedItems removeObject:indexPath];

        if (notifyDelegate && _collectionViewFlags.delegateDidDeselectItemAtIndexPath) {
            [self.delegate collectionView:self didDeselectItemAtIndexPath:indexPath];
        }
    }
}

- (BOOL)highlightItemAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated scrollPosition:(PSTCollectionViewScrollPosition)scrollPosition notifyDelegate:(BOOL)notifyDelegate {
    BOOL shouldHighlight = YES;
    if (notifyDelegate && _collectionViewFlags.delegateShouldHighlightItemAtIndexPath) {
        shouldHighlight = [self.delegate collectionView:self shouldHighlightItemAtIndexPath:indexPath];
    }

    if (shouldHighlight) {
        PSTCollectionViewCell *highlightedCell = [self cellForItemAtIndexPath:indexPath];
        highlightedCell.highlighted = YES;
        [_indexPathsForHighlightedItems addObject:indexPath];

        if (scrollPosition != PSTCollectionViewScrollPositionNone) {
            [self scrollToItemAtIndexPath:indexPath atScrollPosition:scrollPosition animated:animated];
        }

        if (notifyDelegate && _collectionViewFlags.delegateDidHighlightItemAtIndexPath) {
            [self.delegate collectionView:self didHighlightItemAtIndexPath:indexPath];
        }
    }
    return shouldHighlight;
}

- (BOOL)unhighlightItemAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated notifyDelegate:(BOOL)notifyDelegate {
    return [self unhighlightItemAtIndexPath:indexPath animated:animated notifyDelegate:notifyDelegate shouldCheckHighlight:NO];
}

- (BOOL)unhighlightItemAtIndexPath:(NSIndexPath *)indexPath animated:(BOOL)animated notifyDelegate:(BOOL)notifyDelegate shouldCheckHighlight:(BOOL)check {
    if ([_indexPathsForHighlightedItems containsObject:indexPath]) {
        PSTCollectionViewCell *highlightedCell = [self cellForItemAtIndexPath:indexPath];
        // iOS6 does not notify any delegate if the cell was never highlighted (setHighlighted overwritten) during touchMoved
        if (check && !highlightedCell.highlighted) {
            return NO;
        }

        // if multiple selection or not unhighlighting a selected item we don't perform any op
        if (highlightedCell.highlighted && [_indexPathsForSelectedItems containsObject:indexPath]) {
            highlightedCell.highlighted = YES;
        }else {
            highlightedCell.highlighted = NO;
        }

        [_indexPathsForHighlightedItems removeObject:indexPath];

        if (notifyDelegate && _collectionViewFlags.delegateDidUnhighlightItemAtIndexPath) {
            [self.delegate collectionView:self didUnhighlightItemAtIndexPath:indexPath];
        }

        return YES;
    }
    return NO;
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Update Grid

- (void)insertSections:(NSIndexSet *)sections {
    [self updateSections:sections updateAction:PSTCollectionUpdateActionInsert];
}

- (void)deleteSections:(NSIndexSet *)sections {
    // First delete all items
    NSMutableArray *paths = [NSMutableArray new];
    [sections enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        for (int i = 0; i < [self numberOfItemsInSection:(NSInteger)idx]; ++i) {
            [paths addObject:[NSIndexPath indexPathForRow:i inSection:(NSInteger)idx]];
        }
    }];
    [self deleteItemsAtIndexPaths:paths];
    // Then delete the section.
    [self updateSections:sections updateAction:PSTCollectionUpdateActionDelete];
}

- (void)reloadSections:(NSIndexSet *)sections {
    [self updateSections:sections updateAction:PSTCollectionUpdateActionReload];
}

- (void)moveSection:(NSInteger)section toSection:(NSInteger)newSection {
    NSMutableArray *moveUpdateItems = [self arrayForUpdateAction:PSTCollectionUpdateActionMove];
    [moveUpdateItems addObject:
            [[PSTCollectionViewUpdateItem alloc] initWithInitialIndexPath:[NSIndexPath indexPathForRow:NSNotFound inSection:section]
                    finalIndexPath:[NSIndexPath indexPathForRow:NSNotFound inSection:newSection]
                    updateAction:PSTCollectionUpdateActionMove]];
    if (!_collectionViewFlags.updating) {
        [self setupCellAnimations];
        [self endItemAnimations];
    }
}

- (void)insertItemsAtIndexPaths:(NSArray *)indexPaths {
    [self updateRowsAtIndexPaths:indexPaths updateAction:PSTCollectionUpdateActionInsert];
}

- (void)deleteItemsAtIndexPaths:(NSArray *)indexPaths {
    [self updateRowsAtIndexPaths:indexPaths updateAction:PSTCollectionUpdateActionDelete];

}

- (void)reloadItemsAtIndexPaths:(NSArray *)indexPaths {
    [self updateRowsAtIndexPaths:indexPaths updateAction:PSTCollectionUpdateActionReload];
}

- (void)moveItemAtIndexPath:(NSIndexPath *)indexPath toIndexPath:(NSIndexPath *)newIndexPath {
    NSMutableArray *moveUpdateItems = [self arrayForUpdateAction:PSTCollectionUpdateActionMove];
    [moveUpdateItems addObject:
            [[PSTCollectionViewUpdateItem alloc] initWithInitialIndexPath:indexPath
                    finalIndexPath:newIndexPath
                    updateAction:PSTCollectionUpdateActionMove]];
    if (!_collectionViewFlags.updating) {
        [self setupCellAnimations];
        [self endItemAnimations];
    }
}

- (void)performBatchUpdates:(void (^)(void))updates completion:(void (^)(BOOL finished))completion {
    [self setupCellAnimations];

    if (updates) updates();
    // Each update owns its completion: a second performBatchUpdates:completion: issued while the
    // first is still animating must not replace (and so lose) the first one's handler.
    _updateCompletionHandler = completion;

    [self endItemAnimations];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Properties

- (void)setBackgroundView:(UIView *)backgroundView {
    if (backgroundView != _backgroundView) {
        [_backgroundView removeFromSuperview];
        _backgroundView = backgroundView;
        backgroundView.frame = (CGRect){.origin=self.contentOffset, .size=self.bounds.size};
        backgroundView.autoresizingMask = UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleWidth;
        [self addSubview:backgroundView];
        [self sendSubviewToBack:backgroundView];
    }
}

- (void)setCollectionViewLayout:(PSTCollectionViewLayout *)layout animated:(BOOL)animated {
    if (layout == _layout) return;

    // not sure it was it original code, but here this prevents crash
    // in case we switch layout before previous one was initially loaded
    if (CGRectIsEmpty(self.bounds) || !_collectionViewFlags.doneFirstLayout) {
        _layout.collectionView = nil;
        _collectionViewData = [[PSTCollectionViewData alloc] initWithCollectionView:self layout:layout];
        layout.collectionView = self;
        _layout = layout;

        // originally the use method
        // _setNeedsVisibleCellsUpdate:withLayoutAttributes:
        // here with CellsUpdate set to YES and LayoutAttributes parameter set to NO
        // inside this method probably some flags are set and finally
        // setNeedsDisplay is called

        _collectionViewFlags.scheduledUpdateVisibleCells = YES;
        _collectionViewFlags.scheduledUpdateVisibleCellLayoutAttributes = NO;
        _pstVisibleViewsMatchAttributes = NO;
        [self setNeedsDisplay];
    }
    else {
        _pstVisibleViewsMatchAttributes = NO;

        layout.collectionView = self;

        _layout.collectionView = nil;
        _layout = layout;

        _collectionViewData = [[PSTCollectionViewData alloc] initWithCollectionView:self layout:layout];
        [_collectionViewData prepareToLoadData];

        NSArray *previouslySelectedIndexPaths = [self indexPathsForSelectedItems];
        NSMutableSet *selectedCellKeys = [NSMutableSet setWithCapacity:previouslySelectedIndexPaths.count];

        for (NSIndexPath *indexPath in previouslySelectedIndexPaths) {
            [selectedCellKeys addObject:[PSTCollectionViewItemKey collectionItemKeyForCellWithIndexPath:indexPath]];
        }

        NSArray *previouslyVisibleItemsKeys = [_allVisibleViewsDict allKeys];
        NSSet *previouslyVisibleItemsKeysSet = [NSSet setWithArray:previouslyVisibleItemsKeys];
        NSMutableSet *previouslyVisibleItemsKeysSetMutable = [NSMutableSet setWithArray:previouslyVisibleItemsKeys];

        if ([selectedCellKeys intersectsSet:selectedCellKeys]) {
            [previouslyVisibleItemsKeysSetMutable intersectSet:previouslyVisibleItemsKeysSetMutable];
        }

        [self bringSubviewToFront:[_allVisibleViewsDict objectForKey:[previouslyVisibleItemsKeysSetMutable anyObject]]];

        CGPoint targetOffset = self.contentOffset;
        CGPoint centerPoint = CGPointMake(self.bounds.origin.x + self.bounds.size.width / 2.f,
                self.bounds.origin.y + self.bounds.size.height / 2.f);
        // Resolve the centre item once.  indexPathForItemAtPoint: performed the
        // 1x1 scan and threw the attributes away, just to derive an identical
        // attributes object again below; keep the attribute that the scan already
        // returned instead.
        CGRect centerRect = CGRectMake(centerPoint.x, centerPoint.y, 1.f, 1.f);
        PSTCollectionViewLayoutAttributes *centerItemLayoutAttributes = [[layout layoutAttributesForElementsInRect:centerRect] lastObject];
        NSIndexPath *centerItemIndexPath = centerItemLayoutAttributes.indexPath;

        if (!centerItemIndexPath) {
            NSArray *visibleItems = [self indexPathsForVisibleItems];
            if (visibleItems.count > 0) {
                centerItemIndexPath = [visibleItems objectAtIndex:visibleItems.count / 2];
            }
        }

        if (centerItemIndexPath) {
            PSTCollectionViewLayoutAttributes *layoutAttributes = centerItemLayoutAttributes;
            if (!layoutAttributes) {
                layoutAttributes = [layout layoutAttributesForItemAtIndexPath:centerItemIndexPath];
            }
            if (layoutAttributes) {
                PSTCollectionViewScrollPosition scrollPosition = PSTCollectionViewScrollPositionCenteredVertically|PSTCollectionViewScrollPositionCenteredHorizontally;
                CGRect targetRect = [self makeRect:layoutAttributes.frame toScrollPosition:scrollPosition];
                targetOffset = CGPointMake(fmax(0.f, targetRect.origin.x), fmax(0.f, targetRect.origin.y));
            }
        }

        CGRect newlyBounds = CGRectMake(targetOffset.x, targetOffset.y, self.bounds.size.width, self.bounds.size.height);
        NSArray *newlyVisibleLayoutAttrs = [_collectionViewData layoutAttributesForElementsInRect:newlyBounds];

        NSMutableDictionary *layoutInterchangeData = [NSMutableDictionary dictionaryWithCapacity:
                newlyVisibleLayoutAttrs.count + previouslyVisibleItemsKeysSet.count];

        NSMutableSet *newlyVisibleItemsKeys = [NSMutableSet set];
        NSMutableDictionary *newlyVisibleAttrsByKey = [NSMutableDictionary dictionaryWithCapacity:previouslyVisibleItemsKeysSet.count];
        for (PSTCollectionViewLayoutAttributes *attr in newlyVisibleLayoutAttrs) {
            PSTCollectionViewItemKey *newKey = [PSTCollectionViewItemKey collectionItemKeyForLayoutAttributes:attr];
            [newlyVisibleItemsKeys addObject:newKey];

            // The second loop fills the interchange entry for every previously
            // visible key (and used to overwrite the entry written here), so
            // deriving prev/new attributes for those keys is pure duplicate work.
            // Keep the already-fetched attribute for that loop instead.
            if ([previouslyVisibleItemsKeysSet containsObject:newKey]) {
                [newlyVisibleAttrsByKey setObject:attr forKey:newKey];
                continue;
            }

            // This attribute already is the new layout's attribute for the key;
            // the old code derived two more, value-identical copies by asking the
            // same layout object again.  Use the fetched attribute for both
            // animation endpoints (the second application becomes a no-op).
            PSTCollectionViewStatsCountersStorage[PSTStatItemDerivationsCached]++;
            PSTCollectionViewStatsCountersStorage[PSTStatLayoutAttributeDiffs]++;
            [layoutInterchangeData setObject:@{@"previousLayoutInfos": attr, @"newLayoutInfos": attr} forKey:newKey];
        }

        for (PSTCollectionViewItemKey *key in previouslyVisibleItemsKeysSet) {
            PSTCollectionViewLayoutAttributes *prevAttr = nil;
            PSTCollectionViewLayoutAttributes *newAttr = nil;
            PSTCollectionViewLayoutAttributes *alreadyFetchedAttrs = [newlyVisibleAttrsByKey objectForKey:key];

            if (alreadyFetchedAttrs) {
                // The old code derived two separate, value-identical attributes
                // from the new layout for every key that stays visible.  Reuse the
                // one fetched for the new bounds; the second application is then a
                // no-op on the view (same pointer) and the final geometry is
                // unchanged.
                prevAttr = alreadyFetchedAttrs;
                newAttr = alreadyFetchedAttrs;
                PSTCollectionViewStatsCountersStorage[PSTStatItemDerivationsCached] += 2;
            }
            else if (key.type == PSTCollectionViewItemTypeDecorationView) {
                PSTCollectionReusableView *decorView = [_allVisibleViewsDict objectForKey:key];
                prevAttr = [self.collectionViewLayout layoutAttributesForDecorationViewOfKind:decorView.reuseIdentifier
                        atIndexPath:key.indexPath];
                newAttr = [layout layoutAttributesForDecorationViewOfKind:decorView.reuseIdentifier
                        atIndexPath:key.indexPath];
            }
            else if (key.type == PSTCollectionViewItemTypeCell) {
                prevAttr = [self.collectionViewLayout layoutAttributesForItemAtIndexPath:key.indexPath];
                newAttr = [layout layoutAttributesForItemAtIndexPath:key.indexPath];
            }
            else if (key.type == PSTCollectionViewItemTypeSupplementaryView) {
                PSTCollectionReusableView *suuplView = [_allVisibleViewsDict objectForKey:key];
                prevAttr = [self.collectionViewLayout layoutAttributesForSupplementaryViewOfKind:suuplView.layoutAttributes.representedElementKind
                        atIndexPath:key.indexPath];
                newAttr = [layout layoutAttributesForSupplementaryViewOfKind:suuplView.layoutAttributes.representedElementKind
                        atIndexPath:key.indexPath];
            }

            NSMutableDictionary *layoutInterchangeDataValue = [NSMutableDictionary dictionary];
            if (prevAttr) [layoutInterchangeDataValue setObject:prevAttr forKey:@"previousLayoutInfos"];
            if (newAttr) [layoutInterchangeDataValue setObject:newAttr forKey:@"newLayoutInfos"];
            PSTCollectionViewStatsCountersStorage[PSTStatLayoutAttributeDiffs]++;
            [layoutInterchangeData setObject:layoutInterchangeDataValue forKey:key];
        }

        for (PSTCollectionViewItemKey *key in [layoutInterchangeData keyEnumerator]) {
            if (key.type == PSTCollectionViewItemTypeCell) {
                PSTCollectionViewCell *cell = [_allVisibleViewsDict objectForKey:key];

                if (!cell) {
                    cell = [self createPreparedCellForItemAtIndexPath:key.indexPath
                            withLayoutAttributes:[[layoutInterchangeData objectForKey:key] objectForKey:@"previousLayoutInfos"]];
                    [_allVisibleViewsDict setObject:cell forKey:key];
                    [self addControlledSubview:cell];
                    [self pstNotifyWillDisplayView:cell forKey:key];
                }
                else [cell applyLayoutAttributes:[[layoutInterchangeData objectForKey:key] objectForKey:@"previousLayoutInfos"]];
            }
            else if (key.type == PSTCollectionViewItemTypeSupplementaryView) {
                PSTCollectionReusableView *view = [_allVisibleViewsDict objectForKey:key];
                if (!view) {
                    PSTCollectionViewLayoutAttributes *attrs = [[layoutInterchangeData objectForKey:key] objectForKey:@"previousLayoutInfos"];
                    view = [self createPreparedSupplementaryViewForElementOfKind:attrs.representedElementKind
                            atIndexPath:attrs.indexPath
                            withLayoutAttributes:attrs];
                    [_allVisibleViewsDict setObject:view forKey:key];
                    [self addControlledSubview:view];
                    [self pstNotifyWillDisplayView:view forKey:key];
                }
            }
            else if (key.type == PSTCollectionViewItemTypeDecorationView) {
                PSTCollectionReusableView *view = [_allVisibleViewsDict objectForKey:key];
                if (!view) {
                    PSTCollectionViewLayoutAttributes *attrs = [[layoutInterchangeData objectForKey:key] objectForKey:@"previousLayoutInfos"];
                    view = [self dequeueReusableOrCreateDecorationViewOfKind:attrs.representedElementKind forIndexPath:attrs.indexPath];
                    [_allVisibleViewsDict setObject:view forKey:key];
                    [self addControlledSubview:view];
                }
            }
        };

        CGRect contentRect = [_collectionViewData collectionViewContentRect];

        void (^applyNewLayoutBlock)(void) = ^{
            NSEnumerator *keys = [layoutInterchangeData keyEnumerator];
            for (PSTCollectionViewItemKey *key in keys) {
                // TODO: This is most likely not 100% the same time as in UICollectionView. Needs to be investigated.
                PSTCollectionViewCell *cell = (PSTCollectionViewCell *)[_allVisibleViewsDict objectForKey:key];
                [cell willTransitionFromLayout:_layout toLayout:layout];
                [cell applyLayoutAttributes:[[layoutInterchangeData objectForKey:key] objectForKey:@"newLayoutInfos"]];
                [cell didTransitionFromLayout:_layout toLayout:layout];
            }
        };

        void (^freeUnusedViews)(void) = ^{
            NSMutableSet *toRemove = [NSMutableSet set];
            for (PSTCollectionViewItemKey *key in [_allVisibleViewsDict keyEnumerator]) {
                if (![newlyVisibleItemsKeys containsObject:key]) {
                    if (key.type == PSTCollectionViewItemTypeCell) {
                        [self reuseCell:[_allVisibleViewsDict objectForKey:key]];
                        [toRemove addObject:key];
                    }
                    else if (key.type == PSTCollectionViewItemTypeSupplementaryView) {
                        [self reuseSupplementaryView:[_allVisibleViewsDict objectForKey:key]];
                        [toRemove addObject:key];
                    }
                    else if (key.type == PSTCollectionViewItemTypeDecorationView) {
                        [self reuseDecorationView:[_allVisibleViewsDict objectForKey:key]];
                        [toRemove addObject:key];
                    }
                }
            }

            for (id key in toRemove)
                [_allVisibleViewsDict removeObjectForKey:key];
        };

        if (animated) {
            [UIView animateWithDuration:.3 animations:^{
                _collectionViewFlags.updatingLayout = YES;
                self.contentOffset = targetOffset;
                self.contentSize = contentRect.size;
                applyNewLayoutBlock();
            } completion:^(BOOL finished) {
                freeUnusedViews();
                _pstHasFloatingViews = [self pstVisibleViewsHaveFloatingViews];
                _collectionViewFlags.updatingLayout = NO;

                // layout subviews for updating content offset or size while updating layout
                if (!CGPointEqualToPoint(self.contentOffset, targetOffset)
                        || !CGSizeEqualToSize(self.contentSize, contentRect.size)) {
                    [self layoutSubviews];
                }
            }];
        }
        else {
            self.contentOffset = targetOffset;
            self.contentSize = contentRect.size;
            applyNewLayoutBlock();
            freeUnusedViews();
            _pstHasFloatingViews = [self pstVisibleViewsHaveFloatingViews];
        }
    }
}

- (void)setCollectionViewLayout:(PSTCollectionViewLayout *)layout {
    [self setCollectionViewLayout:layout animated:NO];
}

- (id<PSTCollectionViewDelegate>)delegate {
    return self.extVars.collectionViewDelegate;
}

- (void)setDelegate:(id<PSTCollectionViewDelegate>)delegate {
    self.extVars.collectionViewDelegate = delegate;

    //  Managing the Selected Cells
    _collectionViewFlags.delegateShouldSelectItemAtIndexPath = (unsigned int)[self.delegate respondsToSelector:@selector(collectionView:shouldSelectItemAtIndexPath:)];
    _collectionViewFlags.delegateDidSelectItemAtIndexPath = (unsigned int)[self.delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)];
    _collectionViewFlags.delegateShouldDeselectItemAtIndexPath = (unsigned int)[self.delegate respondsToSelector:@selector(collectionView:shouldDeselectItemAtIndexPath:)];
    _collectionViewFlags.delegateDidDeselectItemAtIndexPath = (unsigned int)[self.delegate respondsToSelector:@selector(collectionView:didDeselectItemAtIndexPath:)];

    //  Managing Cell Highlighting
    _collectionViewFlags.delegateShouldHighlightItemAtIndexPath = (unsigned int)[self.delegate respondsToSelector:@selector(collectionView:shouldHighlightItemAtIndexPath:)];
    _collectionViewFlags.delegateDidHighlightItemAtIndexPath = (unsigned int)[self.delegate respondsToSelector:@selector(collectionView:didHighlightItemAtIndexPath:)];
    _collectionViewFlags.delegateDidUnhighlightItemAtIndexPath = (unsigned int)[self.delegate respondsToSelector:@selector(collectionView:didUnhighlightItemAtIndexPath:)];

    //  Tracking the Removal of Views
    _collectionViewFlags.delegateWillDisplayCell = (unsigned int)[self.delegate respondsToSelector:@selector(collectionView:willDisplayCell:forItemAtIndexPath:)];
    _collectionViewFlags.delegateWillDisplaySupplementaryView = (unsigned int)[self.delegate respondsToSelector:@selector(collectionView:willDisplaySupplementaryView:forElementKind:atIndexPath:)];
    _collectionViewFlags.delegateDidEndDisplayingCell = (unsigned int)[self.delegate respondsToSelector:@selector(collectionView:didEndDisplayingCell:forItemAtIndexPath:)];
    _collectionViewFlags.delegateDidEndDisplayingSupplementaryView = (unsigned int)[self.delegate respondsToSelector:@selector(collectionView:didEndDisplayingSupplementaryView:forElementOfKind:atIndexPath:)];

    //  Managing Actions for Cells
    _collectionViewFlags.delegateSupportsMenus = (unsigned int)[self.delegate respondsToSelector:@selector(collectionView:shouldShowMenuForItemAtIndexPath:)];

    // These aren't present in the flags which is a little strange. Not adding them because that will mess with byte alignment which will affect cross compatibility.
    // The flag names are guesses and are there for documentation purposes.
    // _collectionViewFlags.delegateCanPerformActionForItemAtIndexPath = [self.delegate respondsToSelector:@selector(collectionView:canPerformAction:forItemAtIndexPath:withSender:)];
    // _collectionViewFlags.delegatePerformActionForItemAtIndexPath    = [self.delegate respondsToSelector:@selector(collectionView:performAction:forItemAtIndexPath:withSender:)];
}

// Might be overkill since two are required and two are handled by PSTCollectionViewData leaving only one flag we actually need to check for
- (void)setDataSource:(id<PSTCollectionViewDataSource>)dataSource {
    if (dataSource != _dataSource) {
        _dataSource = dataSource;

        //  Getting Item and Section Metrics
        _collectionViewFlags.dataSourceNumberOfSections = (unsigned int)[_dataSource respondsToSelector:@selector(numberOfSectionsInCollectionView:)];

        //  Getting Views for Items
        _collectionViewFlags.dataSourceViewForSupplementaryElement = (unsigned int)[_dataSource respondsToSelector:@selector(collectionView:viewForSupplementaryElementOfKind:atIndexPath:)];
    }
}

- (BOOL)allowsSelection {
    return _collectionViewFlags.allowsSelection;
}

- (void)setAllowsSelection:(BOOL)allowsSelection {
    _collectionViewFlags.allowsSelection = (unsigned int)allowsSelection;
}

- (BOOL)allowsMultipleSelection {
    return _collectionViewFlags.allowsMultipleSelection;
}

- (void)setAllowsMultipleSelection:(BOOL)allowsMultipleSelection {
    _collectionViewFlags.allowsMultipleSelection = (unsigned int)allowsMultipleSelection;

    // Deselect all objects if allows multiple selection is false
    if (!allowsMultipleSelection && _indexPathsForSelectedItems.count) {

        // Note: Apple's implementation leaves a mostly random item selected. Presumably they
        //       have a good reason for this, but I guess it's just skipping the last or first index.
        for (NSIndexPath *selectedIndexPath in [_indexPathsForSelectedItems copy]) {
            if (_indexPathsForSelectedItems.count == 1) continue;
            [self deselectItemAtIndexPath:selectedIndexPath animated:YES notifyDelegate:YES];
        }
    }
}

- (CGRect)visibleBoundRects {
    // in original UICollectionView implementation they
    // check for _visibleBounds and can union self.bounds
    // with this value. Don't know the meaning of _visibleBounds however.
    return self.bounds;
}
///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Private

- (PSTCollectionViewExt *)extVars {
    return objc_getAssociatedObject(self, &kPSTColletionViewExt);
}

// Recompute whether any currently visible reusable view floats (zIndex > 0).
// Used after bulk operations that apply attributes to many views at once.
- (BOOL)pstVisibleViewsHaveFloatingViews {
    NSEnumerator *enumerator = [_allVisibleViewsDict objectEnumerator];
    PSTCollectionReusableView *view = nil;
    while ((view = [enumerator nextObject]) != nil) {
        if (view.layoutAttributes.zIndex > 0) {
            return YES;
        }
    }
    return NO;
}

- (void)invalidateLayout {
    [self.collectionViewLayout invalidateLayout];
    [self.collectionViewData invalidate]; // invalidate layout cache
}

// update currently visible cells, fetches new cells if needed
// TODO: use now parameter.
- (void)pstAddVisibleViewForAttributes:(PSTCollectionViewLayoutAttributes *)layoutAttributes key:(PSTCollectionViewItemKey *)itemKey {

        // check if cell is in visible dict; add it if not.
        PSTCollectionReusableView *view = [_allVisibleViewsDict objectForKey:itemKey];
        if (!view) {
            if (itemKey.type == PSTCollectionViewItemTypeCell) {
                view = [self createPreparedCellForItemAtIndexPath:itemKey.indexPath withLayoutAttributes:layoutAttributes];

            }else if (itemKey.type == PSTCollectionViewItemTypeSupplementaryView) {
                view = [self createPreparedSupplementaryViewForElementOfKind:layoutAttributes.representedElementKind
                        atIndexPath:layoutAttributes.indexPath
                        withLayoutAttributes:layoutAttributes];
            }else if (itemKey.type == PSTCollectionViewItemTypeDecorationView) {
                view = [self dequeueReusableOrCreateDecorationViewOfKind:layoutAttributes.representedElementKind forIndexPath:layoutAttributes.indexPath];
            }

            // Supplementary views are optional
            if (view) {
                [_allVisibleViewsDict setObject:view forKey:itemKey];
                [self addControlledSubview:view];

                // Always apply attributes. Fixes #203.
                PSTCollectionViewStatsCountersStorage[PSTStatVisibleAttributeApplications]++;
                [view applyLayoutAttributes:layoutAttributes];
                [self pstNotifyWillDisplayView:view forKey:itemKey];
            }
        }else {
            // just update cell - unless it already shows exactly these attributes
            if (!PSTLayoutAttributesAlreadyApplied(layoutAttributes, view)) {
                PSTCollectionViewStatsCountersStorage[PSTStatVisibleAttributeApplications]++;
                [view applyLayoutAttributes:layoutAttributes];
            }
        }
}

- (void)updateVisibleCellsNow:(BOOL)now {
    PSTCollectionViewStatsCountersStorage[PSTStatPasses]++;
    uint64_t pstPassStart = PSTCollectionViewStatsNowNanoseconds();
#define PST_STATS_END_PASS() do { \
    PSTCollectionViewStatsCountersStorage[PSTStatLayoutPassNanoseconds] += PSTCollectionViewStatsNowNanoseconds() - pstPassStart; \
} while (0)
    NSArray *layoutAttributesArray = [_collectionViewData layoutAttributesForElementsInRect:self.bounds];

    // An empty attribute set is a valid layout result, not an unavailable layout.
    // Continue through the set difference below so previously visible views end
    // displaying and enter reuse even when there are no replacement attributes.
    // In particular, invalidating a custom layout must not leave stale cells on
    // screen merely because its data-source item count and bounds stayed fixed.

    // Steady state: the data cache already produced this exact attribute set for
    // this exact bounds and the visible views are known to be in sync with it.
    // Re-building the key set and re-applying every attribute can not change a
    // single view, so skip the whole pass.
    if (_pstVisibleViewsMatchAttributes &&
        _pstLastVisibleLayoutAttributesGeneration == [_collectionViewData layoutAttributesGeneration] &&
        CGRectEqualToRect(self.bounds, _pstLastVisibleBounds)) {
        PSTCollectionViewStatsCountersStorage[PSTStatPassesSkipped]++;
        PST_STATS_END_PASS();
        return;
    }

    if (!_pstVisibleItemKeysScratch) {
        _pstVisibleItemKeysScratch = [NSMutableSet setWithCapacity:layoutAttributesArray.count];
    } else {
        [_pstVisibleItemKeysScratch removeAllObjects];
    }

    // Collect the new visible key set first: UIKit retires views leaving the
    // rect (didEndDisplaying) before it displays arriving ones.
    // Each key is built once here and reused by the add loop below.
    if (!_pstVisibleItemKeyListScratch) _pstVisibleItemKeyListScratch = [NSMutableArray arrayWithCapacity:layoutAttributesArray.count];
    else [_pstVisibleItemKeyListScratch removeAllObjects];
    NSMutableArray *pstKeys = _pstVisibleItemKeyListScratch;
    for (PSTCollectionViewLayoutAttributes *layoutAttributes in layoutAttributesArray) {
        PSTCollectionViewItemKey *pstKey = [PSTCollectionViewItemKey collectionItemKeyForLayoutAttributes:layoutAttributes];
        [pstKeys addObject:pstKey];
        // UIKit creates no view for an item whose attributes are hidden, and retires one it
        // already had; leaving the key out of the visible set does both.
        if (!layoutAttributes.isHidden) [_pstVisibleItemKeysScratch addObject:pstKey];
    }

    // Detect what items should be removed and queued back.  The previous code
    // allocated two NSSets and two NSArrays per pass just to compute this set
    // difference; the scratch array keeps the collection order and allocation
    // out of the steady-state path.
    if (!_pstVisibleItemKeysToRemoveScratch) {
        _pstVisibleItemKeysToRemoveScratch = [NSMutableArray array];
    } else {
        [_pstVisibleItemKeysToRemoveScratch removeAllObjects];
    }
    NSEnumerator *visibleKeyEnumerator = [_allVisibleViewsDict keyEnumerator];
    PSTCollectionViewItemKey *candidateKey = nil;
    while ((candidateKey = [visibleKeyEnumerator nextObject]) != nil) {
        if (![_pstVisibleItemKeysScratch containsObject:candidateKey]) {
            [_pstVisibleItemKeysToRemoveScratch addObject:candidateKey];
        }
    }

    // Retire views that left the rect before adding arrivals. UIKit's own retire
    // order is an unspecified hash order, so sort for a deterministic one.
    if (_pstVisibleItemKeysToRemoveScratch.count > 1)
        [_pstVisibleItemKeysToRemoveScratch sortUsingComparator:^NSComparisonResult(PSTCollectionViewItemKey *x, PSTCollectionViewItemKey *y) {
            if (x.type != y.type) return x.type < y.type ? NSOrderedAscending : NSOrderedDescending;
            return [x.indexPath compare:y.indexPath];
        }];
    if (!_pstRetiredViewsScratch) { _pstRetiredViewsScratch = [NSMutableArray array]; _pstRetiredTypesScratch = [NSMutableArray array]; }
    else { [_pstRetiredViewsScratch removeAllObjects]; [_pstRetiredTypesScratch removeAllObjects]; }
    for (PSTCollectionViewItemKey *itemKey in _pstVisibleItemKeysToRemoveScratch) {
        PSTCollectionReusableView *reusableView = [_allVisibleViewsDict objectForKey:itemKey];
        if (reusableView) {
            // The view stays in the hierarchy and is hidden when it is queued below, after
            // this pass has created its arrivals: UIKit does not recycle a view in the
            // pass that retired it.
            [_allVisibleViewsDict removeObjectForKey:itemKey];
            reusableView.hidden = YES; // delegates see the retiring view already hidden, as under UIKit
            if (itemKey.type == PSTCollectionViewItemTypeCell) {
                if (_collectionViewFlags.delegateDidEndDisplayingCell) {
                    [self.delegate collectionView:self didEndDisplayingCell:(PSTCollectionViewCell *)reusableView forItemAtIndexPath:itemKey.indexPath];
                }
            }
            else if (itemKey.type == PSTCollectionViewItemTypeSupplementaryView || itemKey.type == PSTCollectionViewItemTypeDecorationView) {
                // UIKit routes retiring decorations through the reusable-view
                // end-display callback too; the kind identifies the decoration.
                if (_collectionViewFlags.delegateDidEndDisplayingSupplementaryView) {
                    [self.delegate collectionView:self didEndDisplayingSupplementaryView:reusableView forElementOfKind:itemKey.identifier atIndexPath:itemKey.indexPath];
                }
            }
            [_pstRetiredViewsScratch addObject:reusableView];
            [_pstRetiredTypesScratch addObject:@(itemKey.type)];
        }
    }

    // Add new views. UIKit displays arriving cells before supplementary and
    // decoration views, whatever order the layout listed them in.
    // One pass: non-cell attributes are deferred to a scratch array, allocated
    // lazily, so a cells-only pass pays nothing extra.
    NSMutableArray *pstDeferred = nil, *pstDeferredKeys = nil;
    NSUInteger pstKeyIndex = 0;
    for (PSTCollectionViewLayoutAttributes *layoutAttributes in layoutAttributesArray) {
        PSTCollectionViewItemKey *pstKey = [pstKeys objectAtIndex:pstKeyIndex++];
        if (layoutAttributes.isHidden) continue;
        if (layoutAttributes.representedElementCategory != PSTCollectionViewItemTypeCell) {
            if (!pstDeferred) { pstDeferred = [NSMutableArray array]; pstDeferredKeys = [NSMutableArray array]; }
            [pstDeferred addObject:layoutAttributes]; [pstDeferredKeys addObject:pstKey];
            continue;
        }
        [self pstAddVisibleViewForAttributes:layoutAttributes key:pstKey];
    }
    for (NSUInteger i = 0; i < pstDeferred.count; i++)
        [self pstAddVisibleViewForAttributes:[pstDeferred objectAtIndex:i] key:[pstDeferredKeys objectAtIndex:i]];
    [pstKeys removeAllObjects];

    for (NSUInteger r = 0; r < _pstRetiredViewsScratch.count; r++) {
        PSTCollectionReusableView *view = [_pstRetiredViewsScratch objectAtIndex:r];
        PSTCollectionViewItemType type = (PSTCollectionViewItemType)[[_pstRetiredTypesScratch objectAtIndex:r] unsignedIntegerValue];
        if (type == PSTCollectionViewItemTypeCell) [self reuseCell:(PSTCollectionViewCell *)view];
        else if (type == PSTCollectionViewItemTypeSupplementaryView) [self reuseSupplementaryView:view];
        else [self reuseDecorationView:view];
    }
    [_pstRetiredViewsScratch removeAllObjects]; [_pstRetiredTypesScratch removeAllObjects];

    _pstHasFloatingViews = [self pstVisibleViewsHaveFloatingViews];
    _pstLastVisibleLayoutAttributesGeneration = [_collectionViewData layoutAttributesGeneration];
    _pstLastVisibleBounds = self.bounds;
    _pstVisibleViewsMatchAttributes = YES;
    PST_STATS_END_PASS();
    [self pstMeasureSelfSizingCells];
    [self pstPrefetchAfterPass];
}
#undef PST_STATS_END_PASS

- (id<PSTCollectionViewDataSourcePrefetching>)prefetchDataSource { return _prefetchDataSource; }
- (void)setPrefetchDataSource:(id<PSTCollectionViewDataSourcePrefetching>)source { _prefetchDataSource = source; }
- (BOOL)isPrefetchingEnabled { return !_pstPrefetchDisabled; }
- (void)setPrefetchingEnabled:(BOOL)enabled {
    _pstPrefetchDisabled = !enabled;
    if (!enabled) {
        NSArray *cancelled = [[_pstPrefetchedIndexPaths allObjects] sortedArrayUsingSelector:@selector(compare:)];
        // Clear before calling app code so reentrant disable does not cancel twice.
        [_pstPrefetchedIndexPaths removeAllObjects];
        id<PSTCollectionViewDataSourcePrefetching> source = _prefetchDataSource;
        if (cancelled.count && [source respondsToSelector:@selector(collectionView:cancelPrefetchingForItemsAtIndexPaths:)])
            [source collectionView:self cancelPrefetchingForItemsAtIndexPaths:cancelled];
    }
}

/// UICollectionViewDataSourcePrefetching. While the bounds are moving, the items just beyond the visible
/// rect in the scroll direction (about three quarters of a screen, nearest first) are announced once through
/// -collectionView:prefetchItemsAtIndexPaths:. An announced item that is then left behind without ever being
/// displayed is cancelled through -collectionView:cancelPrefetchingForItemsAtIndexPaths:. Nothing fires
/// while the bounds are still, so the initial layout and reloads never prefetch (matching iOS 27).
- (void)pstPrefetchAfterPass {
    id<PSTCollectionViewDataSourcePrefetching> source = _prefetchDataSource;
    CGPoint origin = self.bounds.origin;
    CGPoint previous = _pstPrefetchLastOrigin;
    BOOL hadOrigin = _pstPrefetchHasOrigin;
    _pstPrefetchLastOrigin = origin; _pstPrefetchHasOrigin = YES;
    if (!source || _pstPrefetchDisabled || !hadOrigin) return;
    CGFloat dx = origin.x - previous.x, dy = origin.y - previous.y;
    if (dx == 0 && dy == 0) return;
    BOOL vertical = fabs(dy) >= fabs(dx);
    CGRect visible = self.bounds;
    CGRect ahead = visible;
    CGFloat reach = 0.75 * (vertical ? visible.size.height : visible.size.width);
    if (vertical) { if (dy > 0) ahead.size.height += reach; else { ahead.origin.y -= reach; ahead.size.height += reach; } }
    else          { if (dx > 0) ahead.size.width  += reach; else { ahead.origin.x -= reach; ahead.size.width  += reach; } }
    BOOL forward = vertical ? dy > 0 : dx > 0;

    NSMutableArray *candidates = [NSMutableArray array];
    NSMutableSet *inAhead = [NSMutableSet set];
    for (PSTCollectionViewLayoutAttributes *attributes in [_collectionViewData layoutAttributesForElementsInRect:ahead]) {
        if (attributes.representedElementCategory != PSTCollectionViewItemTypeCell) continue;
        [inAhead addObject:attributes.indexPath];
        PSTCollectionViewItemKey *key = [PSTCollectionViewItemKey collectionItemKeyForLayoutAttributes:attributes];
        if ([_allVisibleViewsDict objectForKey:key]) continue;
        if ([_pstPrefetchedIndexPaths containsObject:attributes.indexPath]) continue;
        [candidates addObject:attributes];
    }
    // Nearest to the visible edge first, ties in reading order.
    CGFloat edge = vertical ? (forward ? CGRectGetMaxY(visible) : CGRectGetMinY(visible))
                            : (forward ? CGRectGetMaxX(visible) : CGRectGetMinX(visible));
    [candidates sortUsingComparator:^NSComparisonResult(PSTCollectionViewLayoutAttributes *a, PSTCollectionViewLayoutAttributes *b) {
        CGFloat da = fabs((vertical ? (forward ? CGRectGetMinY(a.frame) : CGRectGetMaxY(a.frame))
                                    : (forward ? CGRectGetMinX(a.frame) : CGRectGetMaxX(a.frame))) - edge);
        CGFloat db = fabs((vertical ? (forward ? CGRectGetMinY(b.frame) : CGRectGetMaxY(b.frame))
                                    : (forward ? CGRectGetMinX(b.frame) : CGRectGetMaxX(b.frame))) - edge);
        if (da != db) return da < db ? NSOrderedAscending : NSOrderedDescending;
        return [a.indexPath compare:b.indexPath];
    }];

    // Items announced earlier that are now displayed are done; ones that left the window undisplayed are cancelled.
    if (!_pstPrefetchedIndexPaths) _pstPrefetchedIndexPaths = [NSMutableSet set];
    NSMutableArray *cancelled = [NSMutableArray array];
    for (NSIndexPath *indexPath in [_pstPrefetchedIndexPaths allObjects]) {
        PSTCollectionViewItemKey *key = [PSTCollectionViewItemKey collectionItemKeyForCellWithIndexPath:indexPath];
        if ([_allVisibleViewsDict objectForKey:key]) [_pstPrefetchedIndexPaths removeObject:indexPath];
        else if (![inAhead containsObject:indexPath]) { [cancelled addObject:indexPath]; [_pstPrefetchedIndexPaths removeObject:indexPath]; }
    }
    if ([cancelled count] && [source respondsToSelector:@selector(collectionView:cancelPrefetchingForItemsAtIndexPaths:)]) {
        [cancelled sortUsingSelector:@selector(compare:)];
        [source collectionView:self cancelPrefetchingForItemsAtIndexPaths:cancelled];
    }
    if ([candidates count]) {
        NSMutableArray *paths = [NSMutableArray arrayWithCapacity:[candidates count]];
        for (PSTCollectionViewLayoutAttributes *attributes in candidates) { [paths addObject:attributes.indexPath]; [_pstPrefetchedIndexPaths addObject:attributes.indexPath]; }
        [source collectionView:self prefetchItemsAtIndexPaths:paths];
    }
}

/// Self-sizing cells (flow layout estimatedItemSize). Visible cells whose size is not yet confirmed for their
/// proposal are asked for their preferred attributes, and the layout is rebuilt with the answers.
///
/// UIKit does this in several small steps rather than one: it fits the cells nearest the visible origin first,
/// and about half of the cells it has not fitted yet per step, then relays out so the next step's proposals
/// already reflect the sizes just learned. The order and step size decide which proposals each cell sees and
/// so the final geometry; matching them reproduces UIKit's frames. Confirmations (a cell whose answer equals
/// its proposal) are cheap and are checked last, in index order.
///
/// Bounded: a cell is fitted at most PSTSelfSizingAttemptsPerCell times and a transaction runs at most
/// PSTSelfSizingMaxPasses passes, so a cell whose size depends on its own frame cannot loop forever.
enum { PSTSelfSizingAttemptsPerCell = 6, PSTSelfSizingMaxPasses = 256 };

- (void)pstMeasureSelfSizingCells {
    if (_pstMeasuringSelfSizing || ![_layout isKindOfClass:[PSTCollectionViewFlowLayout class]]) return;
    PSTCollectionViewFlowLayout *flow = (PSTCollectionViewFlowLayout *)_layout;
    if (![flow pstUsesSelfSizing]) return;
    _pstMeasuringSelfSizing = YES;   // a relayout inside this transaction must not start another
    NSMutableDictionary *attempts = [NSMutableDictionary dictionary];
    @try {
        for (NSUInteger pass = 0; pass < PSTSelfSizingMaxPasses; pass++) {
            NSMutableArray *fresh = [NSMutableArray array], *confirm = [NSMutableArray array];
            for (PSTCollectionViewItemKey *key in [_allVisibleViewsDict allKeys]) {
                if (key.type != PSTCollectionViewItemTypeCell) continue;
                PSTCollectionReusableView *cell = [_allVisibleViewsDict objectForKey:key];
                PSTCollectionViewLayoutAttributes *proposed = cell.layoutAttributes;
                if (!cell || !proposed) continue;
                if ([flow pstHasStableMeasuredSizeForItemAtIndexPath:key.indexPath proposedFrame:proposed.frame]) continue;
                NSUInteger tries = [[attempts objectForKey:key.indexPath] unsignedIntegerValue];
                if (tries >= PSTSelfSizingAttemptsPerCell) continue;
                [(tries ? confirm : fresh) addObject:key];
            }
            if (!fresh.count && !confirm.count) break;

            NSArray *chosen;
            if (fresh.count) {
                const CGPoint origin = self.bounds.origin;
                [fresh sortUsingComparator:^NSComparisonResult(PSTCollectionViewItemKey *a, PSTCollectionViewItemKey *b) {
                    CGPoint x = ((PSTCollectionReusableView *)[_allVisibleViewsDict objectForKey:a]).layoutAttributes.frame.origin;
                    CGPoint y = ((PSTCollectionReusableView *)[_allVisibleViewsDict objectForKey:b]).layoutAttributes.frame.origin;
                    CGFloat da = (x.x - origin.x) * (x.x - origin.x) + (x.y - origin.y) * (x.y - origin.y);
                    CGFloat db = (y.x - origin.x) * (y.x - origin.x) + (y.y - origin.y) * (y.y - origin.y);
                    if (da != db) return da < db ? NSOrderedAscending : NSOrderedDescending;
                    return [a.indexPath compare:b.indexPath];
                }];
                chosen = [fresh subarrayWithRange:NSMakeRange(0, MAX((NSUInteger)1, fresh.count / 2))];
            } else {
                [confirm sortUsingComparator:^NSComparisonResult(PSTCollectionViewItemKey *a, PSTCollectionViewItemKey *b) { return [a.indexPath compare:b.indexPath]; }];
                chosen = confirm;
            }

            BOOL changed = NO;
            for (PSTCollectionViewItemKey *key in chosen) {
                PSTCollectionReusableView *cell = [_allVisibleViewsDict objectForKey:key];
                PSTCollectionViewLayoutAttributes *proposed = cell.layoutAttributes;
                if (!cell || !proposed) continue;
                NSUInteger tries = [[attempts objectForKey:key.indexPath] unsignedIntegerValue];
                [attempts setObject:@(tries + 1) forKey:key.indexPath];
                PSTCollectionViewLayoutAttributes *preferred = [cell preferredLayoutAttributesFittingAttributes:proposed];
                CGSize size = preferred ? preferred.size : proposed.size;
                if ([flow pstRecordPreferredSize:size forItemAtIndexPath:key.indexPath proposedFrame:proposed.frame]) changed = YES;
            }
            if (changed) {
                [flow pstInvalidateForPreferredSizeChanges];
                [_collectionViewData validateLayoutInRect:self.bounds];
                [self updateVisibleCellsNow:YES];
                CGSize contentSize = [_collectionViewData collectionViewContentRect].size;
                if (!CGSizeEqualToSize(self.contentSize, contentSize)) self.contentSize = contentSize;
            }
        }
    } @finally {
        _pstMeasuringSelfSizing = NO;
    }
}

// fetches a cell from the dataSource and sets the layoutAttributes
- (PSTCollectionViewCell *)createPreparedCellForItemAtIndexPath:(NSIndexPath *)indexPath withLayoutAttributes:(PSTCollectionViewLayoutAttributes *)layoutAttributes {
    PSTCollectionViewStatsCountersStorage[PSTStatVisibleCellsCreated]++;
    // The data source will very likely dequeue a cell for exactly this index
    // path; hand it the attributes already computed for this pass instead of
    // letting it ask the layout for a second, identical attributes object.
    PSTCollectionViewLayoutAttributes *previousAttributes = _pstLayoutAttributesBeingApplied;
    _pstLayoutAttributesBeingApplied = layoutAttributes;
    PSTCollectionViewCell *cell = [self.dataSource collectionView:self cellForItemAtIndexPath:indexPath];
    _pstLayoutAttributesBeingApplied = previousAttributes;
    if ([_layout isKindOfClass:[PSTCollectionViewFlowLayout class]] && [(PSTCollectionViewFlowLayout *)_layout pstUsesSelfSizing]) {
        [(PSTCollectionViewFlowLayout *)_layout pstForgetStableMeasurementForItemAtIndexPath:indexPath];
    }

    // Apply attributes
    [cell applyLayoutAttributes:layoutAttributes];

    // reset selected/highlight state
    // UIKit does not call the setters when nothing changes; a fresh or reused
    // cell is normally unselected and unhighlighted already.
    BOOL wantHighlighted = _indexPathsForHighlightedItems.count && [_indexPathsForHighlightedItems containsObject:indexPath];
    BOOL wantSelected = _indexPathsForSelectedItems.count && [_indexPathsForSelectedItems containsObject:indexPath];
    if (cell.isHighlighted != wantHighlighted) [cell setHighlighted:wantHighlighted];
    if (cell.isSelected != wantSelected) [cell setSelected:wantSelected];

    // voiceover support
    cell.isAccessibilityElement = YES;

    return cell;
}

- (PSTCollectionReusableView *)createPreparedSupplementaryViewForElementOfKind:(NSString *)kind
        atIndexPath:(NSIndexPath *)indexPath
        withLayoutAttributes:(PSTCollectionViewLayoutAttributes *)layoutAttributes {
    if (_collectionViewFlags.dataSourceViewForSupplementaryElement) {
        PSTCollectionViewLayoutAttributes *previousAttributes = _pstLayoutAttributesBeingApplied;
        _pstLayoutAttributesBeingApplied = layoutAttributes;
        PSTCollectionReusableView *view = [self.dataSource collectionView:self
                viewForSupplementaryElementOfKind:kind
                atIndexPath:indexPath];
        _pstLayoutAttributesBeingApplied = previousAttributes;
        [view applyLayoutAttributes:layoutAttributes];
        return view;
    }
    return nil;
}

// @steipete optimization
- (void)queueReusableView:(PSTCollectionReusableView *)reusableView inQueue:(NSMutableDictionary *)queue withIdentifier:(NSString *)identifier {
    NSParameterAssert(identifier.length > 0);

    // Dequeue owns prepareForReuse; a view may remain queued indefinitely.
    NSMutableArray *reuseableViews = [queue objectForKey:identifier];
    if (!reuseableViews) {
        reuseableViews = [NSMutableArray array];
        [queue setObject:reuseableViews forKey:identifier];
    }
    // UIKit keeps a retired view in the hierarchy, hidden, until it is reused: that
    // spares a remove and a re-insert on every scroll step. The queue is capped at about
    // half a screen's worth of such views; beyond that, or for a duplicate, detach it.
    if (reuseableViews.count < [self pstReuseQueueCapacityForView:reusableView] && ![reuseableViews containsObject:reusableView]) {
        [reuseableViews addObject:reusableView];
        if (!reusableView.hidden) reusableView.hidden = YES;
    } else if (reusableView.superview) {
        [reusableView removeFromSuperview];
    }
}

- (NSUInteger)pstReuseQueueCapacityForView:(UIView *)view {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    CGSize size = view.frame.size;
    CGFloat area = size.width * size.height;
    if (area < 1.0) area = 1.0;
    return (NSUInteger)ceil((screen.width * screen.height * 0.5) / area) + 1;
}

// enqueue cell for reuse
- (void)reuseCell:(PSTCollectionViewCell *)cell {
    [self queueReusableView:cell inQueue:_cellReuseQueues withIdentifier:cell.reuseIdentifier];
}

// enqueue supplementary view for reuse
- (void)reuseSupplementaryView:(PSTCollectionReusableView *)supplementaryView {
    NSString *kindAndIdentifier = [NSString stringWithFormat:@"%@/%@", supplementaryView.layoutAttributes.elementKind, supplementaryView.reuseIdentifier];
    [self queueReusableView:supplementaryView inQueue:_supplementaryViewReuseQueues withIdentifier:kindAndIdentifier];
}

// enqueue decoration view for reuse
- (void)reuseDecorationView:(PSTCollectionReusableView *)decorationView {
    [self queueReusableView:decorationView inQueue:_decorationViewReuseQueues withIdentifier:decorationView.reuseIdentifier];
}

/// Delivers collectionView:willDisplayCell: / willDisplaySupplementaryView: for a view that has just been
/// created, configured and added. Decoration views have no such callback in UIKit.
- (void)pstNotifyWillDisplayView:(PSTCollectionReusableView *)view forKey:(PSTCollectionViewItemKey *)key {
    if (!view || !key) return;
    if (key.type == PSTCollectionViewItemTypeCell) {
        if (_collectionViewFlags.delegateWillDisplayCell)
            [self.delegate collectionView:self willDisplayCell:(PSTCollectionViewCell *)view forItemAtIndexPath:key.indexPath];
    } else if (key.type == PSTCollectionViewItemTypeSupplementaryView) {
        if (_collectionViewFlags.delegateWillDisplaySupplementaryView)
            [self.delegate collectionView:self willDisplaySupplementaryView:view forElementKind:key.identifier atIndexPath:key.indexPath];
    }
}

- (void)addControlledSubview:(PSTCollectionReusableView *)subview {
    // avoids placing views above the scroll indicator
    // If the collection view is not displaying scrollIndicators then self.subviews.count can be 0.
    // We take the max to ensure we insert at a non negative index because a negative index will silently fail to insert the view
    // A recycled view is still attached, merely hidden; there is nothing to insert.
    if (subview.superview != self) {
        NSInteger insertionIndex = MAX((NSInteger)(self.subviews.count - (self.dragging ? 1 : 0)), 0);
        [self insertSubview:subview atIndex:insertionIndex];
    }

    // z-index ordering only matters when a visible view floats above the normal
    // cell layer.  Keep that fact instead of copying and scanning the whole
    // subview array for every newly visible cell.
    if (subview.layoutAttributes.zIndex > 0) {
        _pstHasFloatingViews = YES;
    }
    if (!_pstHasFloatingViews) {
        return;
    }

    // One subviews snapshot for both the scroll-indicator and the z-index scan.
    NSArray *subviews = self.subviews;
    UIView *scrollIndicatorView = nil;
    if (self.dragging) {
        scrollIndicatorView = [subviews lastObject];
    }

    // This runs for every newly visible cell.  Layouts without floating
    // supplementary views (the common case) must not allocate and sort.
    if (!_pstFloatingViewsScratch) {
        _pstFloatingViewsScratch = [NSMutableArray array];
    } else {
        [_pstFloatingViewsScratch removeAllObjects];
    }
    NSMutableArray *floatingViews = _pstFloatingViewsScratch;
    for (UIView *uiView in subviews) {
        if ([uiView isKindOfClass:PSTCollectionReusableView.class] && [[(PSTCollectionReusableView *)uiView layoutAttributes] zIndex] > 0) {
            [floatingViews addObject:uiView];
        }
    }

    if (floatingViews.count > 1) {
        [floatingViews sortUsingComparator:^NSComparisonResult(PSTCollectionReusableView *obj1, PSTCollectionReusableView *obj2) {
            CGFloat z1 = [[obj1 layoutAttributes] zIndex];
            CGFloat z2 = [[obj2 layoutAttributes] zIndex];
            if (z1 > z2) {
                return (NSComparisonResult)NSOrderedDescending;
            }else if (z1 < z2) {
                return (NSComparisonResult)NSOrderedAscending;
            }else {
                return (NSComparisonResult)NSOrderedSame;
            }
        }];
    }

    for (PSTCollectionReusableView *uiView in floatingViews) {
        [self bringSubviewToFront:uiView];
    }

    if (floatingViews.count && scrollIndicatorView) {
        [self bringSubviewToFront:scrollIndicatorView];
    }
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Updating grid internal functionality

- (void)suspendReloads {
    _reloadingSuspendedCount++;
}

- (void)resumeReloads {
    if (0 < _reloadingSuspendedCount) _reloadingSuspendedCount--;
}

- (NSMutableArray *)arrayForUpdateAction:(PSTCollectionUpdateAction)updateAction {
    NSMutableArray *updateActions = nil;

    switch (updateAction) {
        case PSTCollectionUpdateActionInsert:
            if (!_insertItems) _insertItems = [NSMutableArray new];
            updateActions = _insertItems;
            break;
        case PSTCollectionUpdateActionDelete:
            if (!_deleteItems) _deleteItems = [NSMutableArray new];
            updateActions = _deleteItems;
            break;
        case PSTCollectionUpdateActionMove:
            if (!_moveItems) _moveItems = [NSMutableArray new];
            updateActions = _moveItems;
            break;
        case PSTCollectionUpdateActionReload:
            if (!_reloadItems) _reloadItems = [NSMutableArray new];
            updateActions = _reloadItems;
            break;
        default: break;
    }
    return updateActions;
}

- (void)prepareLayoutForUpdates {
    NSMutableArray *array = [[NSMutableArray alloc] init];
    [array addObjectsFromArray:[_originalDeleteItems sortedArrayUsingSelector:@selector(inverseCompareIndexPaths:)]];
    [array addObjectsFromArray:[_originalInsertItems sortedArrayUsingSelector:@selector(compareIndexPaths:)]];
    [array addObjectsFromArray:[_reloadItems sortedArrayUsingSelector:@selector(compareIndexPaths:)]];
    [array addObjectsFromArray:[_moveItems sortedArrayUsingSelector:@selector(compareIndexPaths:)]];
    [_layout prepareForCollectionViewUpdates:array];
}

- (void)updateWithItems:(NSArray *)items {
    [self prepareLayoutForUpdates];

    NSMutableArray *animations = [[NSMutableArray alloc] init];
    NSMutableDictionary *newAllVisibleView = [[NSMutableDictionary alloc] init];
    // Dictionary lookup supplies keyed membership as well as the view, without
    // allocating an allKeys array or maintaining a second hash table of the keys.
    // The update machinery asks the layout for the same item/visible attributes
    // repeatedly; fetch everything visible once and reuse it.
    NSArray *allNewlyVisibleItems = [_layout layoutAttributesForElementsInRect:self.visibleBoundRects];
    NSMutableDictionary *newlyVisibleAttrsByKey = [NSMutableDictionary dictionaryWithCapacity:allNewlyVisibleItems.count];
    for (PSTCollectionViewLayoutAttributes *attributes in allNewlyVisibleItems) {
        [newlyVisibleAttrsByKey setObject:attributes forKey:[PSTCollectionViewItemKey collectionItemKeyForLayoutAttributes:attributes]];
    }

    NSMutableDictionary *viewsToRemove = [NSMutableDictionary dictionaryWithObjectsAndKeys:
            [NSMutableArray array], @(PSTCollectionViewItemTypeCell),
            [NSMutableArray array], @(PSTCollectionViewItemTypeDecorationView),
            [NSMutableArray array], @(PSTCollectionViewItemTypeSupplementaryView), nil];
    // Keys of those views, in the same order, so finishUpdate can tell the delegate which
    // index path each one stopped displaying (UIKit sends didEndDisplaying when the
    // delete animation completes, with the view already hidden).
    NSMutableDictionary *keysToRemove = [NSMutableDictionary dictionaryWithObjectsAndKeys:
            [NSMutableArray array], @(PSTCollectionViewItemTypeCell),
            [NSMutableArray array], @(PSTCollectionViewItemTypeDecorationView),
            [NSMutableArray array], @(PSTCollectionViewItemTypeSupplementaryView), nil];

    for (PSTCollectionViewUpdateItem *updateItem in items) {
        if (updateItem.isSectionOperation && updateItem.updateAction != PSTCollectionUpdateActionDelete) continue;
        if (updateItem.isSectionOperation && updateItem.updateAction == PSTCollectionUpdateActionDelete) {
            NSInteger numberOfBeforeSection = [(PSTCollectionViewData *)[_update objectForKey:@"oldModel"] numberOfItemsInSection:updateItem.indexPathBeforeUpdate.section];
            for (NSInteger i = 0; i < numberOfBeforeSection; i++) {
                NSIndexPath *indexPath = [NSIndexPath indexPathForRow:i inSection:updateItem.indexPathBeforeUpdate.section];

                PSTCollectionViewLayoutAttributes *finalAttrs = [_layout finalLayoutAttributesForDisappearingItemAtIndexPath:indexPath];
                PSTCollectionViewItemKey *key = [PSTCollectionViewItemKey collectionItemKeyForCellWithIndexPath:indexPath];
                PSTCollectionReusableView *view = [_allVisibleViewsDict objectForKey:key];
                if (view) {
                    PSTCollectionViewLayoutAttributes *startAttrs = view.layoutAttributes;

                    if (!finalAttrs) {
                        finalAttrs = [startAttrs copy];
                        finalAttrs.alpha = 0;
                    }
                    [animations addObject:@{@"view" : view, @"previousLayoutInfos" : startAttrs, @"newLayoutInfos" : finalAttrs}];

                    [_allVisibleViewsDict removeObjectForKey:key];

                    [(NSMutableArray *)[viewsToRemove objectForKey:@(key.type)] addObject:view];
                [(NSMutableArray *)[keysToRemove objectForKey:@(key.type)] addObject:key];
                    [(NSMutableArray *)[keysToRemove objectForKey:@(key.type)] addObject:key];

                }
            }
            continue;
        }

        if (updateItem.updateAction == PSTCollectionUpdateActionDelete) {
            NSIndexPath *indexPath = updateItem.indexPathBeforeUpdate;

            PSTCollectionViewLayoutAttributes *finalAttrs = [_layout finalLayoutAttributesForDisappearingItemAtIndexPath:indexPath];
            PSTCollectionViewItemKey *key = [PSTCollectionViewItemKey collectionItemKeyForCellWithIndexPath:indexPath];
            PSTCollectionReusableView *view = [_allVisibleViewsDict objectForKey:key];
            if (view) {
                PSTCollectionViewLayoutAttributes *startAttrs = view.layoutAttributes;

                if (!finalAttrs) {
                    finalAttrs = [startAttrs copy];
                    finalAttrs.alpha = 0;
                }
                [animations addObject:@{@"view" : view, @"previousLayoutInfos" : startAttrs, @"newLayoutInfos" : finalAttrs}];

                [_allVisibleViewsDict removeObjectForKey:key];

                [(NSMutableArray *)[viewsToRemove objectForKey:@(key.type)] addObject:view];
                [(NSMutableArray *)[keysToRemove objectForKey:@(key.type)] addObject:key];

            }
        }
        else if (updateItem.updateAction == PSTCollectionUpdateActionInsert) {
            NSIndexPath *indexPath = updateItem.indexPathAfterUpdate;
            PSTCollectionViewItemKey *key = [PSTCollectionViewItemKey collectionItemKeyForCellWithIndexPath:indexPath];
            PSTCollectionViewLayoutAttributes *startAttrs = [_layout initialLayoutAttributesForAppearingItemAtIndexPath:indexPath];
            PSTCollectionViewLayoutAttributes *finalAttrs = [newlyVisibleAttrsByKey objectForKey:key];
            if (finalAttrs) {
                PSTCollectionViewStatsCountersStorage[PSTStatItemDerivationsCached]++;
            } else {
                finalAttrs = [_layout layoutAttributesForItemAtIndexPath:indexPath];
            }

            CGRect startRect = startAttrs.frame;
            CGRect finalRect = finalAttrs.frame;

            // A nil startAttrs reads as CGRectZero, which touches the visible rect whenever the view
            // is scrolled to the origin; an insert far outside the viewport would then be given a
            // cell, a willDisplay and a data source request that UIKit does not make.
            if ((startAttrs && CGRectIntersectsRect(self.visibleBoundRects, startRect)) || CGRectIntersectsRect(self.visibleBoundRects, finalRect)) {

                if (!startAttrs) {
                    startAttrs = [finalAttrs copy];
                    startAttrs.alpha = 0;
                }

                PSTCollectionReusableView *view = [self createPreparedCellForItemAtIndexPath:indexPath
                        withLayoutAttributes:startAttrs];
                [self addControlledSubview:view];
                [self pstNotifyWillDisplayView:view forKey:key];

                [newAllVisibleView setObject:view forKey:key];
                [animations addObject:@{@"view" : view, @"previousLayoutInfos" : startAttrs, @"newLayoutInfos" : finalAttrs}];
            }
        }
        else if (updateItem.updateAction == PSTCollectionUpdateActionMove) {
            NSIndexPath *indexPathBefore = updateItem.indexPathBeforeUpdate;
            NSIndexPath *indexPathAfter = updateItem.indexPathAfterUpdate;

            PSTCollectionViewItemKey *keyBefore = [PSTCollectionViewItemKey collectionItemKeyForCellWithIndexPath:indexPathBefore];
            PSTCollectionViewItemKey *keyAfter = [PSTCollectionViewItemKey collectionItemKeyForCellWithIndexPath:indexPathAfter];
            PSTCollectionReusableView *view = [_allVisibleViewsDict objectForKey:keyBefore];

            PSTCollectionViewLayoutAttributes *startAttrs = nil;
            PSTCollectionViewLayoutAttributes *finalAttrs = [newlyVisibleAttrsByKey objectForKey:keyAfter];
            if (finalAttrs) {
                PSTCollectionViewStatsCountersStorage[PSTStatItemDerivationsCached]++;
            } else {
                finalAttrs = [_layout layoutAttributesForItemAtIndexPath:indexPathAfter];
            }

            if (view) {
                startAttrs = view.layoutAttributes;
                [_allVisibleViewsDict removeObjectForKey:keyBefore];
                [newAllVisibleView setObject:view forKey:keyAfter];
            }
            else {
                startAttrs = [finalAttrs copy];
                startAttrs.alpha = 0;
                view = [self createPreparedCellForItemAtIndexPath:indexPathAfter withLayoutAttributes:startAttrs];
                [self addControlledSubview:view];
                [self pstNotifyWillDisplayView:view forKey:keyAfter];
                [newAllVisibleView setObject:view forKey:keyAfter];
            }

            [animations addObject:@{@"view" : view, @"previousLayoutInfos" : startAttrs, @"newLayoutInfos" : finalAttrs}];
        }
    }

    PSTCollectionViewData *oldModel = [_update objectForKey:@"oldModel"];
    PSTCollectionViewData *newModel = [_update objectForKey:@"newModel"];
    NSArray *oldToNewIndexMap = [_update objectForKey:@"oldToNewIndexMap"];
    for (PSTCollectionViewItemKey *key in [_allVisibleViewsDict keyEnumerator]) {
        PSTCollectionReusableView *view = [_allVisibleViewsDict objectForKey:key];

        if (key.type == PSTCollectionViewItemTypeCell) {
            NSUInteger oldGlobalIndex = [oldModel globalIndexForItemAtIndexPath:key.indexPath];
            NSUInteger newGlobalIndex = NSNotFound;
            if (NSNotFound != oldGlobalIndex && oldGlobalIndex < oldToNewIndexMap.count) {
                newGlobalIndex = [[oldToNewIndexMap objectAtIndex:oldGlobalIndex] unsignedIntegerValue];
            }
            NSIndexPath *newIndexPath = newGlobalIndex == NSNotFound ? nil : [newModel indexPathForItemAtGlobalIndex:(int)newGlobalIndex];
            // The visible dictionary key already is the old index path. Avoid a
            // global-index round trip (prefix search plus NSIndexPath creation).
            NSIndexPath *oldIndexPath = oldGlobalIndex == NSNotFound ? nil : key.indexPath;

            if (newIndexPath) {
                PSTCollectionViewLayoutAttributes *startAttrs = nil;
                PSTCollectionViewLayoutAttributes *finalAttrs = nil;

                startAttrs = [_layout initialLayoutAttributesForAppearingItemAtIndexPath:oldIndexPath];
                PSTCollectionViewItemKey *newKey = [key copy];
                [newKey setIndexPath:newIndexPath];
                finalAttrs = [newlyVisibleAttrsByKey objectForKey:newKey];
                if (finalAttrs) {
                    PSTCollectionViewStatsCountersStorage[PSTStatItemDerivationsCached]++;
                } else {
                    finalAttrs = [_layout layoutAttributesForItemAtIndexPath:newIndexPath];
                }

                NSMutableDictionary *dic = [NSMutableDictionary dictionaryWithDictionary:@{@"view" : view}];
                if (startAttrs) [dic setObject:startAttrs forKey:@"previousLayoutInfos"];
                if (finalAttrs) [dic setObject:finalAttrs forKey:@"newLayoutInfos"];

                [animations addObject:dic];
                [newAllVisibleView setObject:view forKey:newKey];

            }
        }else if (key.type == PSTCollectionViewItemTypeSupplementaryView) {
            PSTCollectionViewLayoutAttributes *startAttrs = nil;
            PSTCollectionViewLayoutAttributes *finalAttrs = nil;

            startAttrs = view.layoutAttributes;
            finalAttrs = [_layout layoutAttributesForSupplementaryViewOfKind:view.layoutAttributes.representedElementKind atIndexPath:key.indexPath];

            NSMutableDictionary *dic = [NSMutableDictionary dictionaryWithDictionary:@{@"view" : view}];
            if (startAttrs) [dic setObject:startAttrs forKey:@"previousLayoutInfos"];
            if (finalAttrs) [dic setObject:finalAttrs forKey:@"newLayoutInfos"];

            [animations addObject:dic];
            PSTCollectionViewItemKey *newKey = [key copy];
            [newAllVisibleView setObject:view forKey:newKey];

        }
    }
    for (PSTCollectionViewLayoutAttributes *attrs in allNewlyVisibleItems) {
        PSTCollectionViewItemKey *key = [PSTCollectionViewItemKey collectionItemKeyForLayoutAttributes:attrs];

        if (key.type == PSTCollectionViewItemTypeCell && ![newAllVisibleView objectForKey:key]) {
            PSTCollectionViewLayoutAttributes *startAttrs =
                    [_layout initialLayoutAttributesForAppearingItemAtIndexPath:attrs.indexPath];

            PSTCollectionReusableView *view = [self createPreparedCellForItemAtIndexPath:attrs.indexPath
                    withLayoutAttributes:startAttrs];
            [self addControlledSubview:view];
            [self pstNotifyWillDisplayView:view forKey:key];
            [newAllVisibleView setObject:view forKey:key];

            [animations addObject:@{@"view" : view, @"previousLayoutInfos" : startAttrs ? startAttrs : attrs, @"newLayoutInfos" : attrs}];
        }
    }

	//In here I think it doesn't need the animation but the transaction, it would cause some issue of display.
	//I resolve the bug when user insert the new sections, the cell will display with a blink animation at the first operation.
	//But I don't know why the next operation wouldn't reproduction in the pre version.
    _allVisibleViewsDict = newAllVisibleView;
    _pstVisibleViewsMatchAttributes = NO;

    // Starting state: applied without animation so every view begins exactly where the previous
    // layout (or the layout's initial/final appearing attributes) says it is.
    BOOL animationsWereEnabled = [UIView areAnimationsEnabled];
    [UIView setAnimationsEnabled:NO];
    for (NSDictionary *animation in animations) {
        PSTCollectionReusableView *view = [animation objectForKey:@"view"];
        PSTCollectionViewLayoutAttributes *attr = [animation objectForKey:@"previousLayoutInfos"];
        [view applyLayoutAttributes:attr];
    };
    [UIView setAnimationsEnabled:animationsWereEnabled];

    _collectionViewFlags.updatingLayout = YES;

    void (^updateCompletion)(BOOL) = _updateCompletionHandler;
    _updateCompletionHandler = nil;
    void (^finishUpdate)(void) = ^{
        // Iterate through all the views that we are going to remove.
        [viewsToRemove enumerateKeysAndObjectsUsingBlock:^(NSNumber *keyObj, NSArray *views, BOOL *stop) {
            PSTCollectionViewItemType type = [keyObj unsignedIntegerValue];
            NSArray *removedKeys = [keysToRemove objectForKey:keyObj];
            // Report in ascending index-path order, as UIKit does; deletes are collected descending.
            NSMutableArray *order = [NSMutableArray arrayWithCapacity:views.count];
            for (NSUInteger i = 0; i < views.count; i++) [order addObject:@(i)];
            if (removedKeys.count == views.count) {
                [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
                    return [[[removedKeys objectAtIndex:[a unsignedIntegerValue]] indexPath] compare:[[removedKeys objectAtIndex:[b unsignedIntegerValue]] indexPath]];
                }];
            }
            for (NSNumber *orderedIndex in order) {
                NSUInteger removedIndex = [orderedIndex unsignedIntegerValue];
                PSTCollectionReusableView *view = [views objectAtIndex:removedIndex];
                PSTCollectionViewItemKey *removedKey = removedIndex < removedKeys.count ? [removedKeys objectAtIndex:removedIndex] : nil;
                view.hidden = YES; // retiring views are hidden when the delegate hears of it
                if (removedKey && type == PSTCollectionViewItemTypeCell && _collectionViewFlags.delegateDidEndDisplayingCell) {
                    [self.delegate collectionView:self didEndDisplayingCell:(PSTCollectionViewCell *)view forItemAtIndexPath:removedKey.indexPath];
                } else if (removedKey && type != PSTCollectionViewItemTypeCell && _collectionViewFlags.delegateDidEndDisplayingSupplementaryView) {
                    [self.delegate collectionView:self didEndDisplayingSupplementaryView:view forElementOfKind:removedKey.identifier atIndexPath:removedKey.indexPath];
                }
                if (type == PSTCollectionViewItemTypeCell) {
                    [self reuseCell:(PSTCollectionViewCell *)view];
                } else if (type == PSTCollectionViewItemTypeSupplementaryView) {
                    [self reuseSupplementaryView:view];
                } else if (type == PSTCollectionViewItemTypeDecorationView) {
                    [self reuseDecorationView:view];
                }
            }
        }];

        _collectionViewFlags.updatingLayout = NO;

        if (updateCompletion) updateCompletion(YES);
    };

    // UIKit's own collection view animates position/bounds/alpha/transform over 0.3 s (measured on
    // iOS 6.1.3 hardware). A view's backing layer only animates inside a UIView animation block, so a
    // bare CATransaction with duration 0 (the previous code) made every update snap.
    if ([animations count] && animationsWereEnabled) {
        [UIView animateWithDuration:0.3 * PSTSimulatorAnimationDragCoefficient()
                              delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             for (NSDictionary *animation in animations) {
                                 PSTCollectionReusableView *view = [animation objectForKey:@"view"];
                                 PSTCollectionViewLayoutAttributes *attrs = [animation objectForKey:@"newLayoutInfos"];
                                 [view applyLayoutAttributes:attrs];
                             }
                         }
                         completion:^(BOOL finished) { finishUpdate(); }];
    } else {
        for (NSDictionary *animation in animations) {
            PSTCollectionReusableView *view = [animation objectForKey:@"view"];
            PSTCollectionViewLayoutAttributes *attrs = [animation objectForKey:@"newLayoutInfos"];
            [view applyLayoutAttributes:attrs];
        }
        finishUpdate();
    }
	_pstHasFloatingViews = [self pstVisibleViewsHaveFloatingViews];

    [_layout finalizeCollectionViewUpdates];
}

- (void)setupCellAnimations {
    [self updateVisibleCellsNow:YES];
    [self suspendReloads];
    _collectionViewFlags.updating = YES;
}

- (void)endItemAnimations {
    _updateCount++;
    PSTCollectionViewData *oldCollectionViewData = _collectionViewData;
    _collectionViewData = [[PSTCollectionViewData alloc] initWithCollectionView:self layout:_layout];

    [_layout invalidateLayout];
    [_collectionViewData prepareToLoadData];

    NSMutableArray *someMutableArr1 = [[NSMutableArray alloc] init];

    NSArray *removeUpdateItems = [[self arrayForUpdateAction:PSTCollectionUpdateActionDelete]
            sortedArrayUsingSelector:@selector(inverseCompareIndexPaths:)];

    NSArray *insertUpdateItems = [[self arrayForUpdateAction:PSTCollectionUpdateActionInsert]
            sortedArrayUsingSelector:@selector(compareIndexPaths:)];

    NSMutableArray *sortedMutableReloadItems = [[_reloadItems sortedArrayUsingSelector:@selector(compareIndexPaths:)] mutableCopy];
    NSMutableArray *sortedMutableMoveItems = [[_moveItems sortedArrayUsingSelector:@selector(compareIndexPaths:)] mutableCopy];

    _originalDeleteItems = [removeUpdateItems copy];
    _originalInsertItems = [insertUpdateItems copy];

    NSMutableArray *someMutableArr2 = [[NSMutableArray alloc] init];
    NSMutableArray *someMutableArr3 = [[NSMutableArray alloc] init];
    NSMutableDictionary *operations = [[NSMutableDictionary alloc] init];

    for (PSTCollectionViewUpdateItem *updateItem in sortedMutableReloadItems) {
        NSAssert(updateItem.indexPathBeforeUpdate.section < [oldCollectionViewData numberOfSections],
        @"attempt to reload item (%@) that doesn't exist (there are only %ld sections before update)",
        updateItem.indexPathBeforeUpdate, (long)[oldCollectionViewData numberOfSections]);

        if (updateItem.indexPathBeforeUpdate.row != NSNotFound) {
            NSAssert(updateItem.indexPathBeforeUpdate.row < [oldCollectionViewData numberOfItemsInSection:updateItem.indexPathBeforeUpdate.section],
            @"attempt to reload item (%@) that doesn't exist (there are only %ld items in section %ld before update)",
            updateItem.indexPathBeforeUpdate,
            (long)[oldCollectionViewData numberOfItemsInSection:updateItem.indexPathBeforeUpdate.section],
            (long)updateItem.indexPathBeforeUpdate.section);
        }

        [someMutableArr2 addObject:[[PSTCollectionViewUpdateItem alloc] initWithAction:PSTCollectionUpdateActionDelete
                forIndexPath:updateItem.indexPathBeforeUpdate]];
        [someMutableArr3 addObject:[[PSTCollectionViewUpdateItem alloc] initWithAction:PSTCollectionUpdateActionInsert
                forIndexPath:updateItem.indexPathAfterUpdate]];
    }

    NSMutableArray *sortedDeletedMutableItems = [[_deleteItems sortedArrayUsingSelector:@selector(inverseCompareIndexPaths:)] mutableCopy];
    NSMutableArray *sortedInsertMutableItems = [[_insertItems sortedArrayUsingSelector:@selector(compareIndexPaths:)] mutableCopy];

    for (PSTCollectionViewUpdateItem *deleteItem in sortedDeletedMutableItems) {
        if ([deleteItem isSectionOperation]) {
            NSAssert(deleteItem.indexPathBeforeUpdate.section < [oldCollectionViewData numberOfSections],
            @"attempt to delete section (%ld) that doesn't exist (there are only %ld sections before update)",
            (long)deleteItem.indexPathBeforeUpdate.section,
            (long)[oldCollectionViewData numberOfSections]);

            for (PSTCollectionViewUpdateItem *moveItem in sortedMutableMoveItems) {
                if (moveItem.indexPathBeforeUpdate.section == deleteItem.indexPathBeforeUpdate.section) {
                    if (moveItem.isSectionOperation)
                    NSAssert(NO, @"attempt to delete and move from the same section %ld", (long)deleteItem.indexPathBeforeUpdate.section);
                    else
                            NSAssert(NO, @"attempt to delete and move from the same section (%@)", moveItem.indexPathBeforeUpdate);
                }
            }
        }else {
            NSAssert(deleteItem.indexPathBeforeUpdate.section < [oldCollectionViewData numberOfSections],
            @"attempt to delete item (%@) that doesn't exist (there are only %ld sections before update)",
            deleteItem.indexPathBeforeUpdate,
            (long)[oldCollectionViewData numberOfSections]);
            NSAssert(deleteItem.indexPathBeforeUpdate.row < [oldCollectionViewData numberOfItemsInSection:deleteItem.indexPathBeforeUpdate.section],
            @"attempt to delete item (%@) that doesn't exist (there are only %ld items in section%ld before update)",
            deleteItem.indexPathBeforeUpdate,
            (long)[oldCollectionViewData numberOfItemsInSection:deleteItem.indexPathBeforeUpdate.section],
            (long)deleteItem.indexPathBeforeUpdate.section);

            for (PSTCollectionViewUpdateItem *moveItem in sortedMutableMoveItems) {
                NSAssert(![deleteItem.indexPathBeforeUpdate isEqual:moveItem.indexPathBeforeUpdate],
                @"attempt to delete and move the same item (%@)", deleteItem.indexPathBeforeUpdate);
            }

            if (![operations objectForKey:@(deleteItem.indexPathBeforeUpdate.section)])
                [operations setObject:[NSMutableDictionary dictionary] forKey:@(deleteItem.indexPathBeforeUpdate.section)];

            [[operations objectForKey:@(deleteItem.indexPathBeforeUpdate.section)] setObject:@([[[operations objectForKey:@(deleteItem.indexPathBeforeUpdate.section)] objectForKey:@"deleted"] intValue] + 1) forKey:@"deleted"];
        }
    }

    for (NSUInteger i = 0; i < sortedInsertMutableItems.count; i++) {
        PSTCollectionViewUpdateItem *insertItem = [sortedInsertMutableItems objectAtIndex:i];
        NSIndexPath *indexPath = insertItem.indexPathAfterUpdate;

        BOOL sectionOperation = [insertItem isSectionOperation];
        if (sectionOperation) {
            NSAssert([indexPath section] < [_collectionViewData numberOfSections],
            @"attempt to insert %ld but there are only %ld sections after update",
            (long)[indexPath section], (long)[_collectionViewData numberOfSections]);

            for (PSTCollectionViewUpdateItem *moveItem in sortedMutableMoveItems) {
                if ([moveItem.indexPathAfterUpdate isEqual:indexPath]) {
                    if (moveItem.isSectionOperation)
                    NSAssert(NO, @"attempt to perform an insert and a move to the same section (%ld)", (long)indexPath.section);
                }
            }

            NSUInteger j = i + 1;
            while (j < sortedInsertMutableItems.count) {
                PSTCollectionViewUpdateItem *nextInsertItem = [sortedInsertMutableItems objectAtIndex:j];

                if (nextInsertItem.indexPathAfterUpdate.section == indexPath.section) {
                    NSAssert(nextInsertItem.indexPathAfterUpdate.row < [_collectionViewData numberOfItemsInSection:indexPath.section],
                    @"attempt to insert item %ld into section %ld, but there are only %ld items in section %ld after the update",
                    (long)nextInsertItem.indexPathAfterUpdate.row,
                    (long)indexPath.section,
                    (long)[_collectionViewData numberOfItemsInSection:indexPath.section],
                    (long)indexPath.section);
                    [sortedInsertMutableItems removeObjectAtIndex:j];
                }
                else break;
            }
        }else {
            NSAssert(indexPath.row < [_collectionViewData numberOfItemsInSection:indexPath.section],
            @"attempt to insert item to (%@) but there are only %ld items in section %ld after update",
            indexPath,
            (long)[_collectionViewData numberOfItemsInSection:indexPath.section],
            (long)indexPath.section);

            if (![operations objectForKey:@(indexPath.section)])
                [operations setObject:[NSMutableDictionary dictionary] forKey:@(indexPath.section)];

            [[operations objectForKey:@(indexPath.section)] setObject:@([[[operations objectForKey:@(indexPath.section)] objectForKey:@"inserted"] intValue] + 1) forKey:@"inserted"];
        }
    }

    for (PSTCollectionViewUpdateItem *sortedItem in sortedMutableMoveItems) {
        if (sortedItem.isSectionOperation) {
            NSAssert(sortedItem.indexPathBeforeUpdate.section < [oldCollectionViewData numberOfSections],
            @"attempt to move section (%ld) that doesn't exist (%ld sections before update)",
            (long)sortedItem.indexPathBeforeUpdate.section,
            (long)[oldCollectionViewData numberOfSections]);
            NSAssert(sortedItem.indexPathAfterUpdate.section < [_collectionViewData numberOfSections],
            @"attempt to move section to %ld but there are only %ld sections after update",
            (long)sortedItem.indexPathAfterUpdate.section,
            (long)[_collectionViewData numberOfSections]);
        }else {
            NSAssert(sortedItem.indexPathBeforeUpdate.section < [oldCollectionViewData numberOfSections],
            @"attempt to move item (%@) that doesn't exist (%ld sections before update)",
            sortedItem, (long)[oldCollectionViewData numberOfSections]);
            NSAssert(sortedItem.indexPathBeforeUpdate.row < [oldCollectionViewData numberOfItemsInSection:sortedItem.indexPathBeforeUpdate.section],
            @"attempt to move item (%@) that doesn't exist (%ld items in section %ld before update)",
            sortedItem,
            (long)[oldCollectionViewData numberOfItemsInSection:sortedItem.indexPathBeforeUpdate.section],
            (long)sortedItem.indexPathBeforeUpdate.section);

            NSAssert(sortedItem.indexPathAfterUpdate.section < [_collectionViewData numberOfSections],
            @"attempt to move item to (%@) but there are only %ld sections after update",
            sortedItem.indexPathAfterUpdate,
            (long)[_collectionViewData numberOfSections]);
            NSAssert(sortedItem.indexPathAfterUpdate.row < [_collectionViewData numberOfItemsInSection:sortedItem.indexPathAfterUpdate.section],
            @"attempt to move item to (%@) but there are only %ld items in section %ld after update",
            sortedItem,
            (long)[_collectionViewData numberOfItemsInSection:sortedItem.indexPathAfterUpdate.section],
            (long)sortedItem.indexPathAfterUpdate.section);
        }

        if (![operations objectForKey:@(sortedItem.indexPathBeforeUpdate.section)])
            [operations setObject:[NSMutableDictionary dictionary] forKey:@(sortedItem.indexPathBeforeUpdate.section)];
        if (![operations objectForKey:@(sortedItem.indexPathAfterUpdate.section)])
            [operations setObject:[NSMutableDictionary dictionary] forKey:@(sortedItem.indexPathAfterUpdate.section)];

        [[operations objectForKey:@(sortedItem.indexPathBeforeUpdate.section)] setObject:@([[[operations objectForKey:@(sortedItem.indexPathBeforeUpdate.section)] objectForKey:@"movedOut"] intValue] + 1) forKey:@"movedOut"];

        [[operations objectForKey:@(sortedItem.indexPathAfterUpdate.section)] setObject:@([[[operations objectForKey:@(sortedItem.indexPathAfterUpdate.section)] objectForKey:@"movedIn"] intValue] + 1) forKey:@"movedIn"];
    }

#if !defined  NS_BLOCK_ASSERTIONS
    for (NSNumber *sectionKey in [operations keyEnumerator]) {
        NSInteger section = [sectionKey integerValue];

        NSInteger insertedCount = [[[operations objectForKey:sectionKey] objectForKey:@"inserted"] integerValue];
        NSInteger deletedCount = [[[operations objectForKey:sectionKey] objectForKey:@"deleted"] integerValue];
        NSInteger movedInCount = [[[operations objectForKey:sectionKey] objectForKey:@"movedIn"] integerValue];
        NSInteger movedOutCount = [[[operations objectForKey:sectionKey] objectForKey:@"movedOut"] integerValue];

        NSAssert([oldCollectionViewData numberOfItemsInSection:section] + insertedCount - deletedCount + movedInCount - movedOutCount ==
                [_collectionViewData numberOfItemsInSection:section],
        @"invalid update in section %ld: number of items after update (%ld) should be equal to the number of items before update (%ld) "\
                 "plus count of inserted items (%ld), minus count of deleted items (%ld), plus count of items moved in (%ld), minus count of items moved out (%ld)",
        (long)section,
        (long)[_collectionViewData numberOfItemsInSection:section],
        (long)[oldCollectionViewData numberOfItemsInSection:section],
        (long)insertedCount, (long)deletedCount, (long)movedInCount, (long)movedOutCount);
    }
#endif

    [someMutableArr2 addObjectsFromArray:sortedDeletedMutableItems];
    [someMutableArr3 addObjectsFromArray:sortedInsertMutableItems];
    [someMutableArr1 addObjectsFromArray:[someMutableArr2 sortedArrayUsingSelector:@selector(inverseCompareIndexPaths:)]];
    [someMutableArr1 addObjectsFromArray:sortedMutableMoveItems];
    [someMutableArr1 addObjectsFromArray:[someMutableArr3 sortedArrayUsingSelector:@selector(compareIndexPaths:)]];

    NSMutableArray *layoutUpdateItems = [[NSMutableArray alloc] init];

    [layoutUpdateItems addObjectsFromArray:sortedDeletedMutableItems];
    [layoutUpdateItems addObjectsFromArray:sortedMutableMoveItems];
    [layoutUpdateItems addObjectsFromArray:sortedInsertMutableItems];


    NSMutableArray *newModel = [NSMutableArray array];
    for (NSInteger i = 0; i < [oldCollectionViewData numberOfSections]; i++) {
        NSInteger count = [oldCollectionViewData numberOfItemsInSection:i];
        NSUInteger base = [oldCollectionViewData numberOfItemsBeforeSection:i];
        NSMutableArray *sectionArr = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
        // Global indexes are contiguous within a section. Avoid constructing an
        // NSIndexPath and querying the section prefix again for every old item.
        for (NSInteger j = 0; j < count; j++)
            [sectionArr addObject:@(base + (NSUInteger)j)];
        [newModel addObject:sectionArr];
    }

    for (PSTCollectionViewUpdateItem *updateItem in layoutUpdateItems) {
        switch (updateItem.updateAction) {
            case PSTCollectionUpdateActionDelete: {
                if (updateItem.isSectionOperation) {
                    // section updates are ignored anyway in animation code. If not commented, mixing rows and section deletion causes crash in else below
                    // [newModel removeObjectAtIndex:updateItem.indexPathBeforeUpdate.section];
                }else {
                    [(NSMutableArray *)[newModel objectAtIndex:(NSUInteger)updateItem.indexPathBeforeUpdate.section]
                            removeObjectAtIndex:(NSUInteger)updateItem.indexPathBeforeUpdate.row];
                }
            }
                break;
            case PSTCollectionUpdateActionInsert: {
                if (updateItem.isSectionOperation) {
                    [newModel insertObject:[[NSMutableArray alloc] init]
                            atIndex:(NSUInteger)updateItem.indexPathAfterUpdate.section];
                }else {
                    [(NSMutableArray *)[newModel objectAtIndex:(NSUInteger)updateItem.indexPathAfterUpdate.section]
                            insertObject:@(NSNotFound)
                            atIndex:(NSUInteger)updateItem.indexPathAfterUpdate.row];
                }
            }
                break;

            case PSTCollectionUpdateActionMove: {
                if (updateItem.isSectionOperation) {
                    id section = [newModel objectAtIndex:(NSUInteger)updateItem.indexPathBeforeUpdate.section];
                    [newModel insertObject:section atIndex:(NSUInteger)updateItem.indexPathAfterUpdate.section];
                }
                else {
                    id object = @([oldCollectionViewData globalIndexForItemAtIndexPath:updateItem.indexPathBeforeUpdate]);
                    [[newModel objectAtIndex:(NSUInteger)updateItem.indexPathBeforeUpdate.section] removeObject:object];
                    [[newModel objectAtIndex:(NSUInteger)updateItem.indexPathAfterUpdate.section] insertObject:object
                                                                            atIndex:(NSUInteger)updateItem.indexPathAfterUpdate.row];
                }
            }
                break;
            default: break;
        }
    }

    NSMutableArray *oldToNewMap = [NSMutableArray arrayWithCapacity:(NSUInteger)[oldCollectionViewData numberOfItems]];
    NSMutableArray *newToOldMap = [NSMutableArray arrayWithCapacity:(NSUInteger)[_collectionViewData numberOfItems]];

    for (NSInteger i = 0; i < [oldCollectionViewData numberOfItems]; i++)
        [oldToNewMap addObject:@(NSNotFound)];

    for (NSInteger i = 0; i < [_collectionViewData numberOfItems]; i++)
        [newToOldMap addObject:@(NSNotFound)];

    for (NSUInteger i = 0; i < newModel.count; i++) {
        NSMutableArray *section = [newModel objectAtIndex:i];
        NSUInteger base = [_collectionViewData numberOfItemsBeforeSection:(NSInteger)i];
        for (NSUInteger j = 0; j < section.count; j++) {
            NSUInteger newGlobalIndex = base + j;
            if ([[section objectAtIndex:j] integerValue] != NSNotFound)
                [oldToNewMap replaceObjectAtIndex:[[section objectAtIndex:j] unsignedIntegerValue] withObject:@(newGlobalIndex)];
            if (newGlobalIndex != NSNotFound)
                [newToOldMap replaceObjectAtIndex:newGlobalIndex withObject:[section objectAtIndex:j]];
        }
    }

    _update = @{@"oldModel" : oldCollectionViewData, @"newModel" : _collectionViewData, @"oldToNewIndexMap" : oldToNewMap, @"newToOldIndexMap" : newToOldMap};

    [self updateWithItems:someMutableArr1];

    _originalInsertItems = nil;
    _originalDeleteItems = nil;
    _insertItems = nil;
    _deleteItems = nil;
    _moveItems = nil;
    _reloadItems = nil;
    _update = nil;
    _updateCount--;
    _collectionViewFlags.updating = NO;
    [self resumeReloads];
}

- (void)updateRowsAtIndexPaths:(NSArray *)indexPaths updateAction:(PSTCollectionUpdateAction)updateAction {
    BOOL updating = _collectionViewFlags.updating;
    if (!updating) [self setupCellAnimations];

    NSMutableArray *array = [self arrayForUpdateAction:updateAction]; //returns appropriate empty array if not exists

    for (NSIndexPath *indexPath in indexPaths) {
        PSTCollectionViewUpdateItem *updateItem = [[PSTCollectionViewUpdateItem alloc] initWithAction:updateAction forIndexPath:indexPath];
        [array addObject:updateItem];
    }

    if (!updating) [self endItemAnimations];
}


- (void)updateSections:(NSIndexSet *)sections updateAction:(PSTCollectionUpdateAction)updateAction {
    BOOL updating = _collectionViewFlags.updating;
    if (!updating) [self setupCellAnimations];

    NSMutableArray *updateActions = [self arrayForUpdateAction:updateAction];

    [sections enumerateIndexesUsingBlock:^(NSUInteger section, BOOL *stop) {
        PSTCollectionViewUpdateItem *updateItem = [[PSTCollectionViewUpdateItem alloc] initWithAction:updateAction forIndexPath:[NSIndexPath indexPathForRow:NSNotFound inSection:(NSInteger)section]];
        [updateActions addObject:updateItem];
    }];

    if (!updating) [self endItemAnimations];
}

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - PSTCollection/UICollection interoperability

#ifdef kPSUIInteroperabilityEnabled
#import <objc/message.h>
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    NSMethodSignature *sig = [super methodSignatureForSelector:selector];
    if(!sig) {
        NSString *selString = NSStringFromSelector(selector);
        if ([selString hasPrefix:@"_"]) {
            SEL cleanedSelector = NSSelectorFromString([selString substringFromIndex:1]);
            sig = [super methodSignatureForSelector:cleanedSelector];
        }
    }
    return sig;
}
- (void)forwardInvocation:(NSInvocation *)inv {
    NSString *selString = NSStringFromSelector([inv selector]);
    if ([selString hasPrefix:@"_"]) {
        SEL cleanedSelector = NSSelectorFromString([selString substringFromIndex:1]);
        if ([self respondsToSelector:cleanedSelector]) {
            // dynamically add method for faster resolving
            Method newMethod = class_getInstanceMethod(self.class, [inv selector]);
            IMP underscoreIMP = imp_implementationWithBlock(^(id _self) {
                return objc_msgSend(_self, cleanedSelector);
            });
            class_addMethod(self.class, [inv selector], underscoreIMP, method_getTypeEncoding(newMethod));
            // invoke now
            inv.selector = cleanedSelector;
            [inv invokeWithTarget:self];
        }
    }else {
        [super forwardInvocation:inv];
    }
}
#endif

@end

///////////////////////////////////////////////////////////////////////////////////////////
#pragma mark - Runtime Additions to create UICollectionView

@implementation PSUICollectionView_ @end
@implementation PSUICollectionViewCell_ @end
@implementation PSUICollectionReusableView_ @end
@implementation PSUICollectionViewLayout_ @end
@implementation PSUICollectionViewFlowLayout_ @end
@implementation PSUICollectionViewLayoutAttributes_ @end
@implementation PSUICollectionViewController_ @end

static void PSTRegisterClasses() {
    NSDictionary *map = @{
        @"UICollectionView": PSUICollectionView_.class,
        @"UICollectionViewCell": PSUICollectionViewCell_.class,
        @"UICollectionReusableView": PSUICollectionReusableView_.class,
        @"UICollectionViewLayout": PSUICollectionViewLayout_.class,
        @"UICollectionViewFlowLayout": PSUICollectionViewFlowLayout_.class,
        @"UICollectionViewLayoutAttributes": PSUICollectionViewLayoutAttributes_.class,
        @"UICollectionViewController": PSUICollectionViewController_.class
    };

    // Ensure that superclass replacement is all-or-nothing for the PSUI*_ types. Either use exclusively
    // UICollectionView*, or exclusively PSTCollectionView*.
    __block BOOL canOverwrite = YES;
    [map enumerateKeysAndObjectsUsingBlock:^(NSString* UIClassName, id PSTClass, BOOL *stop) {
        Class UIClass = NSClassFromString(UIClassName);
        if (UIClass) {
            // Class size need to be the same for class_setSuperclass to work.
            // If the UIKit class is smaller then our subclass, ivars won't clash, so there's no issue.
            long sizeDifference = (long)class_getInstanceSize(UIClass) - class_getInstanceSize(PSTClass);
            if (sizeDifference > 0) {
                canOverwrite = NO;
                NSLog(@"Warning! ivar size mismatch in %@ of %tu bytes - can't change the superclass.", PSTClass, sizeDifference);
            }
        } else {
            canOverwrite = NO;
            // We're most likely on iOS5, the requested UIKit class doesn't exist, so we create it dynamically.
            if ((UIClass = objc_allocateClassPair(PSTClass, UIClassName.UTF8String, 0))) {
                objc_registerClassPair(UIClass);
            }
        }
    }];

#if !defined(PST_TOOLCHAIN_RUNTIME)
    if (canOverwrite) {
        // All UICollectionView types were found and appropriately sized, so it is safe to replace the super-class.
        [map enumerateKeysAndObjectsUsingBlock:^(NSString* UIClassName, id PSTClass, BOOL *stop) {
            Class UIClass = NSClassFromString(UIClassName);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            // class_setSuperclass is deprecated, but still exists and works on iOS6/7.
            class_setSuperclass(PSTClass, UIClass);
#pragma clang diagnostic pop
        }];
    }
#endif
}

// Create subclasses that pose as UICollectionView et al, if not available at runtime.
__attribute__((constructor)) static void PSTCreateUICollectionViewClasses(void) {
    if (objc_getClass("PSTCollectionViewDisableForwardToUICollectionViewSentinel")) return;
#if defined(PST_TOOLCHAIN_RUNTIME)
    // The importer selects PST at compile time for deployment targets below 6.
    // Never reparent compatibility classes or touch native UIKit on newer OSes.
    if (objc_getClass("UICollectionView")) return;
#endif

    @autoreleasepool {
        // Change superclass at runtime. This allows seamless switching from PST* to UI* at runtime.
        PSTRegisterClasses();

        // add PSUI classes at runtime to make Interface Builder sane
        // (IB doesn't allow adding the PSUICollectionView_ types but doesn't complain on unknown classes)
        // The class name may already be in use. This may happen if this code is running for the second time (first for an app bundle, then again for a unit test bundle).
        Class c;
        if ((c = objc_allocateClassPair(PSUICollectionView_.class, "PSUICollectionView", 0))) objc_registerClassPair(c);
        if ((c = objc_allocateClassPair(PSUICollectionViewCell_.class, "PSUICollectionViewCell", 0))) objc_registerClassPair(c);
        if ((c = objc_allocateClassPair(PSUICollectionReusableView_.class, "PSUICollectionReusableView", 0))) objc_registerClassPair(c);
        if ((c = objc_allocateClassPair(PSUICollectionViewLayout_.class, "PSUICollectionViewLayout", 0))) objc_registerClassPair(c);
        if ((c = objc_allocateClassPair(PSUICollectionViewFlowLayout_.class, "PSUICollectionViewFlowLayout", 0))) objc_registerClassPair(c);
        if ((c = objc_allocateClassPair(PSUICollectionViewLayoutAttributes_.class, "PSUICollectionViewLayoutAttributes", 0)))objc_registerClassPair(c);
        if ((c = objc_allocateClassPair(PSUICollectionViewController_.class, "PSUICollectionViewController", 0))) objc_registerClassPair(c);
    }
}

CGFloat PSTSimulatorAnimationDragCoefficient(void) {
    // UIKit's UIAnimationDragCoefficient returns a float. Declaring it as returning CGFloat
    // (a double on 64-bit) reads the wrong register on arm64 and yielded garbage.
    static float (*UIAnimationDragCoefficient)(void) = NULL;
#if TARGET_IPHONE_SIMULATOR
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIAnimationDragCoefficient = (CGFloat (*)(void))dlsym(RTLD_DEFAULT, "UIAnimationDragCoefficient");
    });
#endif
    return UIAnimationDragCoefficient ? (CGFloat)UIAnimationDragCoefficient() : 1.f;
}

// helper to check for ivar layout
#if 0
static void PSTPrintIvarsForClass(Class aClass) {
    unsigned int varCount;
    Ivar *vars = class_copyIvarList(aClass, &varCount);
    for (int i = 0; i < varCount; i++) {
        NSLog(@"%s %s", ivar_getTypeEncoding(vars[i]), ivar_getName(vars[i]));
    }
    free(vars);
}

__attribute__((constructor)) static void PSTCheckIfIVarLayoutIsEqualSize(void) {
    @autoreleasepool {
        NSLog(@"PSTCollectionView size = %zd, UICollectionView size = %zd", class_getInstanceSize(PSTCollectionView.class),class_getInstanceSize(UICollectionView.class));
        NSLog(@"PSTCollectionViewCell size = %zd, UICollectionViewCell size = %zd", class_getInstanceSize(PSTCollectionViewCell.class),class_getInstanceSize(UICollectionViewCell.class));
        NSLog(@"PSTCollectionViewController size = %zd, UICollectionViewController size = %zd", class_getInstanceSize(PSTCollectionViewController.class),class_getInstanceSize(UICollectionViewController.class));
        NSLog(@"PSTCollectionViewLayout size = %zd, UICollectionViewLayout size = %zd", class_getInstanceSize(PSTCollectionViewLayout.class),class_getInstanceSize(UICollectionViewLayout.class));
        NSLog(@"PSTCollectionViewFlowLayout size = %zd, UICollectionViewFlowLayout size = %zd", class_getInstanceSize(PSTCollectionViewFlowLayout.class),class_getInstanceSize(UICollectionViewFlowLayout.class));
        //PSTPrintIvarsForClass(PSTCollectionViewFlowLayout.class); NSLog(@"\n\n\n");PSTPrintIvarsForClass(UICollectionViewFlowLayout.class);
    }
}
#endif
