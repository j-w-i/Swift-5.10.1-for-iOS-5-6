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

    // The iOS 9 accessors, only where UIKit does not already have them.
    SEL visible = sel_registerName("visibleSupplementaryViewsOfKind:");
    if (!class_getInstanceMethod(collectionView, visible))
        class_addMethod(collectionView, visible, (IMP)UICVisibleSupplementaryViews, "@@:@");
    SEL paths = sel_registerName("indexPathsForVisibleSupplementaryElementsOfKind:");
    if (!class_getInstanceMethod(collectionView, paths))
        class_addMethod(collectionView, paths, (IMP)UICIndexPathsForVisibleSupplementaryElements, "@@:@");
}

#pragma mark - UICollectionViewFlowLayoutAutomaticSize (iOS 10)

// Same value UIKit exports: the largest CGSize, which a flow layout reads as "size this item automatically".
const CGSize SwiftLegacyUICollectionViewFlowLayoutAutomaticSize = {CGFLOAT_MAX, CGFLOAT_MAX};
