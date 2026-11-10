//
//  UICCollectionViewDisplay.m
//  UIKitBackports runtime
//
//  Collection-view API that Apple's own UICollectionView lacks before the OS that introduced it,
//  added to Apple's class so apps on iOS 6 and 7 see the same behaviour as the kit's PSTCollectionView
//  (iOS 5) and as UIKit on iOS 8+:
//
//    * collectionView:willDisplayCell:forItemAtIndexPath:                       (iOS 8)
//    * collectionView:willDisplaySupplementaryView:forElementKind:atIndexPath:  (iOS 8)
//    * -visibleSupplementaryViewsOfKind: / -indexPathsForVisibleSupplementaryElementsOfKind: (iOS 9)
//
//  Strictly additive: nothing is installed when UIKit already provides the API, and Apple's
//  implementation always runs first. Observed against the iOS 27 simulator (call order: cell is created
//  and configured, added to the collection view, then willDisplay is delivered) and against UIKit 6.1
//  on hardware, whose update pass creates a view and then calls the private
//  -_addControlledSubview:atZIndex: — the point this file observes.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// iOS 8.0 reports CoreFoundation 1140.10; every earlier release is below it.
#define UIC_CF_IOS_8 1140.0

static IMP UICOriginalAddControlledSubview;
static void UICInstallSelfSizing(Class collectionView);
static void UICInstallPrefetching(Class collectionView);

/// The layout attributes UIKit stored on a reusable view (private accessor present on iOS 6 and 7).
static UICollectionViewLayoutAttributes *UICAttributesForView(UIView *view) {
    SEL accessor = sel_registerName("_layoutAttributes");
    if (![view respondsToSelector:accessor]) accessor = sel_registerName("layoutAttributes");
    if (![view respondsToSelector:accessor]) return nil;
    id attributes = ((id (*)(id, SEL))objc_msgSend)(view, accessor);
    return [attributes isKindOfClass:[UICollectionViewLayoutAttributes class]] ? attributes : nil;
}

static void UICAddControlledSubview(id self, SEL _cmd, UIView *subview, int zIndex) {
    ((void (*)(id, SEL, id, int))UICOriginalAddControlledSubview)(self, _cmd, subview, zIndex);
    id delegate = [(UICollectionView *)self delegate];
    if (!delegate) return;
    UICollectionViewLayoutAttributes *attributes = UICAttributesForView(subview);
    if (!attributes) return;
    NSIndexPath *indexPath = attributes.indexPath;
    if ([subview isKindOfClass:[UICollectionViewCell class]]) {
        SEL selector = sel_registerName("collectionView:willDisplayCell:forItemAtIndexPath:");
        if ([delegate respondsToSelector:selector])
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, selector, self, subview, indexPath);
    } else if ([attributes representedElementCategory] == UICollectionElementCategorySupplementaryView) {
        SEL selector = sel_registerName("collectionView:willDisplaySupplementaryView:forElementKind:atIndexPath:");
        if ([delegate respondsToSelector:selector])
            ((void (*)(id, SEL, id, id, id, id))objc_msgSend)(delegate, selector, self, subview,
                                                               [attributes representedElementKind], indexPath);
    }
}

#pragma mark - visibleSupplementaryViews

static NSArray *UICVisibleSupplementaryViews(UICollectionView *self, SEL _cmd, NSString *kind) {
    NSMutableArray *result = [NSMutableArray array];
    for (UIView *subview in [self subviews]) {
        if (![subview isKindOfClass:[UICollectionReusableView class]] ||
            [subview isKindOfClass:[UICollectionViewCell class]]) continue;
        UICollectionViewLayoutAttributes *attributes = UICAttributesForView(subview);
        if ([attributes representedElementCategory] != UICollectionElementCategorySupplementaryView) continue;
        if (kind && ![[attributes representedElementKind] isEqualToString:kind]) continue;
        [result addObject:subview];
    }
    return result;
}

static NSArray *UICIndexPathsForVisibleSupplementaryElements(UICollectionView *self, SEL _cmd, NSString *kind) {
    NSMutableArray *result = [NSMutableArray array];
    for (UIView *view in UICVisibleSupplementaryViews(self, _cmd, kind)) {
        NSIndexPath *indexPath = UICAttributesForView(view).indexPath;
        if (indexPath) [result addObject:indexPath];
    }
    return result;
}

#pragma mark - Installation

void UICInstallCollectionViewDisplay(void) {
    Class collectionView = objc_getClass("UICollectionView");
    if (!collectionView) return;                           // iOS 5: PSTCollectionView carries this itself

    // willDisplay exists natively from iOS 8; below that, observe the point UIKit adds a view.
    if (kCFCoreFoundationVersionNumber < UIC_CF_IOS_8) {
        SEL add = sel_registerName("_addControlledSubview:atZIndex:");
        Method method = class_getInstanceMethod(collectionView, add);
        if (method && !UICOriginalAddControlledSubview)
            UICOriginalAddControlledSubview = method_setImplementation(method, (IMP)UICAddControlledSubview);
    }

    // iOS 8 self-sizing: below it, give Apple's flow layout the estimate and the cell the preferred-size method.
    if (kCFCoreFoundationVersionNumber < UIC_CF_IOS_8) UICInstallSelfSizing(collectionView);

    // iOS 10 prefetching, only where UIKit does not already have it.
    if (!class_getInstanceMethod(collectionView, sel_registerName("prefetchDataSource"))) UICInstallPrefetching(collectionView);

    // The iOS 9 accessors, only where UIKit does not already have them.
    SEL visible = sel_registerName("visibleSupplementaryViewsOfKind:");
    if (!class_getInstanceMethod(collectionView, visible))
        class_addMethod(collectionView, visible, (IMP)UICVisibleSupplementaryViews, "@@:@");
    SEL paths = sel_registerName("indexPathsForVisibleSupplementaryElementsOfKind:");
    if (!class_getInstanceMethod(collectionView, paths))
        class_addMethod(collectionView, paths, (IMP)UICIndexPathsForVisibleSupplementaryElements, "@@:@");
}

#pragma mark - Self-sizing cells on Apple's UICollectionView (iOS 6, 7)

// iOS 8 added UICollectionViewFlowLayout.estimatedItemSize and the cell's preferredLayoutAttributesFitting.
// Apple's flow layout before that asks the collection view's delegate for every item size, so a layout with an
// estimate is given sizes through the delegate's class: each answer is the size the cell last reported, else the
// estimate (and the layout's itemSize when it is not self-sizing, so other collection views sharing the delegate
// class are unaffected). After each layout pass the visible cells are asked for their preferred size; when any
// differs the layout is invalidated and laid out again, bounded to a few rounds.

static char UICEstimateKey, UICMeasuredKey, UICStableKey, UICRoundsKey;
static IMP UICOriginalLayoutSubviews, UICOriginalPrepareLayout, UICOriginalReloadData;

static BOOL UICLayoutIsSelfSizing(id layout) {
    NSValue *value = objc_getAssociatedObject(layout, &UICEstimateKey);
    if (!value) return NO;
    CGSize size = [value CGSizeValue];
    return size.width > 0 && size.height > 0;
}
static CGSize UICSizeForItem(id layout, NSIndexPath *indexPath) {
    NSValue *measured = [objc_getAssociatedObject(layout, &UICMeasuredKey) objectForKey:indexPath];
    return measured ? [measured CGSizeValue] : [objc_getAssociatedObject(layout, &UICEstimateKey) CGSizeValue];
}
static void UICResetMeasured(id layout) {
    objc_setAssociatedObject(layout, &UICMeasuredKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(layout, &UICStableKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// The delegate hook: UIKit's flow layout calls this once the delegate responds to it.
static CGSize UICDelegateSizeForItem(id self, SEL _cmd, UICollectionView *collectionView,
                                     UICollectionViewFlowLayout *layout, NSIndexPath *indexPath) {
    if (UICLayoutIsSelfSizing(layout)) return UICSizeForItem(layout, indexPath);
    return [layout itemSize];
}

/// Makes the layout's delegate answer sizeForItem, unless it already does (an app-provided answer always wins,
/// as on iOS 8). Returns YES when the hook was newly installed.
static BOOL UICInstallSizeHook(UICollectionView *collectionView) {
    id delegate = [collectionView delegate];
    if (!delegate) return NO;
    SEL selector = sel_registerName("collectionView:layout:sizeForItemAtIndexPath:");
    Class delegateClass = object_getClass(delegate);
    Method existing = class_getInstanceMethod(delegateClass, selector);
    // The shim may already be inherited or have been installed for another collection view.
    // Each flow layout caches delegate capabilities independently: refresh this layout too.
    // An app-provided implementation remains authoritative and is never changed here.
    if (existing && method_getImplementation(existing) != (IMP)UICDelegateSizeForItem) return NO;
    if (!existing && [delegate respondsToSelector:selector]) return NO; // forwarding/proxy delegate
    char types[64];
    snprintf(types, sizeof types, "%s@:@@@", @encode(CGSize));
    BOOL added = !existing && class_addMethod(delegateClass, selector, (IMP)UICDelegateSizeForItem, types);
    if (existing || added) {
        SEL flags = sel_registerName("_updateDelegateFlags");
        id layout = [collectionView collectionViewLayout];
        if ([layout respondsToSelector:flags]) ((void (*)(id, SEL))objc_msgSend)(layout, flags);
    }
    return added;
}

static CGSize UICEstimatedItemSizeGetter(id self, SEL _cmd) {
    return [objc_getAssociatedObject(self, &UICEstimateKey) CGSizeValue];
}
static void UICEstimatedItemSizeSetter(id self, SEL _cmd, CGSize size) {
    objc_setAssociatedObject(self, &UICEstimateKey, [NSValue valueWithCGSize:size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UICResetMeasured(self);
    UICollectionView *collectionView = [(UICollectionViewLayout *)self collectionView];
    if (collectionView) UICInstallSizeHook(collectionView);
    [(UICollectionViewLayout *)self invalidateLayout];
}

static void UICPrepareLayout(id self, SEL _cmd) {
    if (UICLayoutIsSelfSizing(self)) {
        UICollectionView *collectionView = [(UICollectionViewLayout *)self collectionView];
        if (collectionView) UICInstallSizeHook(collectionView);
    }
    ((void (*)(id, SEL))UICOriginalPrepareLayout)(self, _cmd);
}

/// iOS 8 default: measure the cell's contentView (or the view itself) with Auto Layout and return a copy of the
/// proposal carrying that size. Override in a subclass for a custom size.
static UICollectionViewLayoutAttributes *UICPreferredAttributes(UICollectionReusableView *self, SEL _cmd,
                                                                UICollectionViewLayoutAttributes *proposal) {
    UICollectionViewLayoutAttributes *preferred = [proposal copy];
    UIView *measured = [self isKindOfClass:[UICollectionViewCell class]] ? [(UICollectionViewCell *)self contentView] : self;
    if (![measured respondsToSelector:@selector(systemLayoutSizeFittingSize:)]) return preferred;
    CGSize size = [measured systemLayoutSizeFittingSize:proposal.size];
    if (size.width > 0 && size.height > 0) preferred.size = size;
    return preferred;
}

/// After a layout pass: ask every visible cell whether it wants a different size than the layout gave it.
static BOOL UICMeasureVisibleCells(UICollectionView *collectionView) {
    id layout = [collectionView collectionViewLayout];
    if (![layout isKindOfClass:[UICollectionViewFlowLayout class]] || !UICLayoutIsSelfSizing(layout)) return NO;
    NSMutableDictionary *measured = objc_getAssociatedObject(layout, &UICMeasuredKey);
    if (!measured) { measured = [NSMutableDictionary dictionary]; objc_setAssociatedObject(layout, &UICMeasuredKey, measured, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    NSMutableSet *stable = objc_getAssociatedObject(layout, &UICStableKey);
    if (!stable) { stable = [NSMutableSet set]; objc_setAssociatedObject(layout, &UICStableKey, stable, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    BOOL changed = NO;
    for (UICollectionViewCell *cell in [[collectionView visibleCells] copy]) {
        NSIndexPath *indexPath = [collectionView indexPathForCell:cell];
        if (!indexPath || [stable containsObject:indexPath]) continue;
        UICollectionViewLayoutAttributes *proposal = [layout layoutAttributesForItemAtIndexPath:indexPath];
        if (!proposal) continue;
        UICollectionViewLayoutAttributes *preferred = [cell preferredLayoutAttributesFittingAttributes:[proposal copy]];
        CGSize size = preferred ? preferred.size : proposal.size;
        CGSize current = UICSizeForItem(layout, indexPath);
        [measured setObject:[NSValue valueWithCGSize:size] forKey:indexPath];
        if (CGSizeEqualToSize(size, current)) [stable addObject:indexPath];
        else { [stable removeObject:indexPath]; changed = YES; }
    }
    return changed;
}

static void UICLayoutSubviews(UICollectionView *self, SEL _cmd) {
    ((void (*)(id, SEL))UICOriginalLayoutSubviews)(self, _cmd);
    NSNumber *running = objc_getAssociatedObject(self, &UICRoundsKey);
    if (running) return;                                   // already inside the measuring loop
    objc_setAssociatedObject(self, &UICRoundsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (int round = 0; round < 6 && UICMeasureVisibleCells(self); round++) {
        [[self collectionViewLayout] invalidateLayout];
        ((void (*)(id, SEL))UICOriginalLayoutSubviews)(self, _cmd);
    }
    objc_setAssociatedObject(self, &UICRoundsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void UICReloadData(UICollectionView *self, SEL _cmd) {
    id layout = [self collectionViewLayout];
    if (UICLayoutIsSelfSizing(layout)) UICResetMeasured(layout);
    ((void (*)(id, SEL))UICOriginalReloadData)(self, _cmd);
}

static void UICInstallSelfSizing(Class collectionView) {
    Class flow = objc_getClass("UICollectionViewFlowLayout");
    Class reusable = objc_getClass("UICollectionReusableView");
    if (!flow || !reusable) return;
    char getter[32], setter[32];
    snprintf(getter, sizeof getter, "%s@:", @encode(CGSize));
    snprintf(setter, sizeof setter, "v@:%s", @encode(CGSize));
    class_addMethod(flow, sel_registerName("estimatedItemSize"), (IMP)UICEstimatedItemSizeGetter, getter);
    class_addMethod(flow, sel_registerName("setEstimatedItemSize:"), (IMP)UICEstimatedItemSizeSetter, setter);
    class_addMethod(reusable, sel_registerName("preferredLayoutAttributesFittingAttributes:"), (IMP)UICPreferredAttributes, "@@:@");

    Method prepare = class_getInstanceMethod(flow, sel_registerName("prepareLayout"));
    if (prepare && !UICOriginalPrepareLayout) UICOriginalPrepareLayout = method_setImplementation(prepare, (IMP)UICPrepareLayout);
    Method layout = class_getInstanceMethod(collectionView, sel_registerName("layoutSubviews"));
    if (layout && !UICOriginalLayoutSubviews) UICOriginalLayoutSubviews = method_setImplementation(layout, (IMP)UICLayoutSubviews);
    Method reload = class_getInstanceMethod(collectionView, sel_registerName("reloadData"));
    if (reload && !UICOriginalReloadData) UICOriginalReloadData = method_setImplementation(reload, (IMP)UICReloadData);
}

#pragma mark - Prefetching on Apple's UICollectionView (iOS 6-9)

// iOS 10 UICollectionViewDataSourcePrefetching: while the bounds are moving, the items just beyond the visible
// rect in the scroll direction are announced once through collectionView:prefetchItemsAtIndexPaths:, and items
// announced but left behind undisplayed are cancelled. Nothing fires while the bounds are still. Same rule as the
// kit's PSTCollectionView, observed against UIKit on iOS 27.

static char UICPrefetchSourceKey, UICPrefetchDisabledKey, UICPrefetchSetKey, UICPrefetchOriginKey;
static IMP UICOriginalLayoutSubviewsForPrefetch, UICOriginalReloadDataForPrefetch;

static id UICPrefetchDataSource(id self, SEL _cmd) {
    return [objc_getAssociatedObject(self, &UICPrefetchSourceKey) nonretainedObjectValue];
}
static void UICSetPrefetchDataSource(id self, SEL _cmd, id source) {
    objc_setAssociatedObject(self, &UICPrefetchSourceKey, source ? [NSValue valueWithNonretainedObject:source] : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL UICIsPrefetchingEnabled(id self, SEL _cmd) {
    return ![objc_getAssociatedObject(self, &UICPrefetchDisabledKey) boolValue];
}
static void UICSetPrefetchingEnabled(id self, SEL _cmd, BOOL enabled) {
    objc_setAssociatedObject(self, &UICPrefetchDisabledKey, enabled ? nil : @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!enabled) [(NSMutableSet *)objc_getAssociatedObject(self, &UICPrefetchSetKey) removeAllObjects];
}

static void UICPrefetchAfterPass(UICollectionView *self) {
    id source = UICPrefetchDataSource(self, NULL);
    CGPoint origin = self.bounds.origin;
    NSValue *previousValue = objc_getAssociatedObject(self, &UICPrefetchOriginKey);
    objc_setAssociatedObject(self, &UICPrefetchOriginKey, [NSValue valueWithCGPoint:origin], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!source || !UICIsPrefetchingEnabled(self, NULL) || !previousValue) return;
    CGPoint previous = [previousValue CGPointValue];
    CGFloat dx = origin.x - previous.x, dy = origin.y - previous.y;
    if (dx == 0 && dy == 0) return;
    SEL prefetchSel = sel_registerName("collectionView:prefetchItemsAtIndexPaths:");
    if (![source respondsToSelector:prefetchSel]) return;
    BOOL vertical = fabs(dy) >= fabs(dx), forward = vertical ? dy > 0 : dx > 0;
    CGRect visible = self.bounds, ahead = visible;
    CGFloat reach = 0.75 * (vertical ? visible.size.height : visible.size.width);
    if (vertical) { if (!forward) ahead.origin.y -= reach; ahead.size.height += reach; }
    else          { if (!forward) ahead.origin.x -= reach; ahead.size.width  += reach; }

    NSMutableSet *announced = objc_getAssociatedObject(self, &UICPrefetchSetKey);
    if (!announced) { announced = [NSMutableSet set]; objc_setAssociatedObject(self, &UICPrefetchSetKey, announced, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    NSMutableSet *displayed = [NSMutableSet set];
    for (UICollectionViewCell *cell in [self visibleCells]) { NSIndexPath *p = [self indexPathForCell:cell]; if (p) [displayed addObject:p]; }

    NSMutableArray *candidates = [NSMutableArray array];
    NSMutableSet *inAhead = [NSMutableSet set];
    for (UICollectionViewLayoutAttributes *attributes in [[self collectionViewLayout] layoutAttributesForElementsInRect:ahead]) {
        if ([attributes representedElementCategory] != UICollectionElementCategoryCell) continue;
        [inAhead addObject:attributes.indexPath];
        if ([displayed containsObject:attributes.indexPath] || [announced containsObject:attributes.indexPath]) continue;
        [candidates addObject:attributes];
    }
    CGFloat edge = vertical ? (forward ? CGRectGetMaxY(visible) : CGRectGetMinY(visible))
                            : (forward ? CGRectGetMaxX(visible) : CGRectGetMinX(visible));
    CGFloat (^distance)(UICollectionViewLayoutAttributes *) = ^CGFloat(UICollectionViewLayoutAttributes *a) {
        CGFloat position = vertical ? (forward ? CGRectGetMinY(a.frame) : CGRectGetMaxY(a.frame))
                                    : (forward ? CGRectGetMinX(a.frame) : CGRectGetMaxX(a.frame));
        return fabs(position - edge);
    };
    [candidates sortUsingComparator:^NSComparisonResult(UICollectionViewLayoutAttributes *a, UICollectionViewLayoutAttributes *b) {
        CGFloat da = distance(a), db = distance(b);
        if (da != db) return da < db ? NSOrderedAscending : NSOrderedDescending;
        return [a.indexPath compare:b.indexPath];
    }];

    NSMutableArray *cancelled = [NSMutableArray array];
    for (NSIndexPath *indexPath in [announced allObjects]) {
        if ([displayed containsObject:indexPath]) [announced removeObject:indexPath];
        else if (![inAhead containsObject:indexPath]) { [cancelled addObject:indexPath]; [announced removeObject:indexPath]; }
    }
    SEL cancelSel = sel_registerName("collectionView:cancelPrefetchingForItemsAtIndexPaths:");
    if ([cancelled count] && [source respondsToSelector:cancelSel]) {
        [cancelled sortUsingSelector:@selector(compare:)];
        ((void (*)(id, SEL, id, id))objc_msgSend)(source, cancelSel, self, cancelled);
    }
    if ([candidates count]) {
        NSMutableArray *paths = [NSMutableArray arrayWithCapacity:[candidates count]];
        for (UICollectionViewLayoutAttributes *attributes in candidates) { [paths addObject:attributes.indexPath]; [announced addObject:attributes.indexPath]; }
        ((void (*)(id, SEL, id, id))objc_msgSend)(source, prefetchSel, self, paths);
    }
}

static void UICLayoutSubviewsPrefetch(UICollectionView *self, SEL _cmd) {
    ((void (*)(id, SEL))UICOriginalLayoutSubviewsForPrefetch)(self, _cmd);
    UICPrefetchAfterPass(self);
}
static void UICReloadDataPrefetch(UICollectionView *self, SEL _cmd) {
    [(NSMutableSet *)objc_getAssociatedObject(self, &UICPrefetchSetKey) removeAllObjects];
    objc_setAssociatedObject(self, &UICPrefetchOriginKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL))UICOriginalReloadDataForPrefetch)(self, _cmd);
}

static void UICInstallPrefetching(Class collectionView) {
    char getter[16], setter[16], boolGetter[16], boolSetter[16];
    snprintf(getter, sizeof getter, "@@:"); snprintf(setter, sizeof setter, "v@:@");
    snprintf(boolGetter, sizeof boolGetter, "%s@:", @encode(BOOL)); snprintf(boolSetter, sizeof boolSetter, "v@:%s", @encode(BOOL));
    class_addMethod(collectionView, sel_registerName("prefetchDataSource"), (IMP)UICPrefetchDataSource, getter);
    class_addMethod(collectionView, sel_registerName("setPrefetchDataSource:"), (IMP)UICSetPrefetchDataSource, setter);
    class_addMethod(collectionView, sel_registerName("isPrefetchingEnabled"), (IMP)UICIsPrefetchingEnabled, boolGetter);
    class_addMethod(collectionView, sel_registerName("setPrefetchingEnabled:"), (IMP)UICSetPrefetchingEnabled, boolSetter);
    // Wrap layoutSubviews / reloadData (the self-sizing installer may already have wrapped them; both chain).
    Method layout = class_getInstanceMethod(collectionView, sel_registerName("layoutSubviews"));
    if (layout && !UICOriginalLayoutSubviewsForPrefetch)
        UICOriginalLayoutSubviewsForPrefetch = method_setImplementation(layout, (IMP)UICLayoutSubviewsPrefetch);
    Method reload = class_getInstanceMethod(collectionView, sel_registerName("reloadData"));
    if (reload && !UICOriginalReloadDataForPrefetch)
        UICOriginalReloadDataForPrefetch = method_setImplementation(reload, (IMP)UICReloadDataPrefetch);
}

#pragma mark - UICollectionViewFlowLayoutAutomaticSize (iOS 10)

// Same value UIKit exports: the largest CGSize, which a flow layout reads as "size this item automatically".
const CGSize SwiftLegacyUICollectionViewFlowLayoutAutomaticSize = {CGFLOAT_MAX, CGFLOAT_MAX};
