//
//  NSIndexPath+PSTCollectionViewAdditions.m
//  PSTCollectionView
//
//  Copyright (c) 2013 Peter Steinberger. All rights reserved.
//

#import "NSIndexPath+PSTCollectionViewAdditions.h"

#if __IPHONE_OS_VERSION_MIN_REQUIRED < 60000
#import <objc/runtime.h>

// Do not use category method definitions: they override UIKit's own iOS 6+
// implementations when this iOS 5-targeted dylib is loaded on a newer OS.
static NSIndexPath *PSTIndexPathForItem(id self, SEL command, NSInteger item, NSInteger section) {
    return [NSIndexPath indexPathForRow:item inSection:section];
}

static NSInteger PSTIndexPathItem(NSIndexPath *self, SEL command) {
    return self.row;
}

__attribute__((constructor)) static void PSTInstallIndexPathAdditions(void) {
    Class cls = [NSIndexPath class];
    Class meta = object_getClass(cls);
    SEL create = @selector(indexPathForItem:inSection:);
    SEL item = @selector(item);
    if (!class_getClassMethod(cls, create))
        class_addMethod(meta, create, (IMP)PSTIndexPathForItem, "@@:ii");
    if (!class_getInstanceMethod(cls, item))
        class_addMethod(cls, item, (IMP)PSTIndexPathItem, "i@:");
}
#endif
