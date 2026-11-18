// Original implementation.
//
// +appearanceWhenContainedInInstancesOfClasses: (iOS 9) below iOS 9.
//
// iOS 5-8 only have the nil-terminated variadic +appearanceWhenContainedIn:, which Swift cannot call
// (variadic Objective-C methods are not imported). The array form forwards the classes, in order, to
// the variadic method, so the proxy is UIKit's own: on iOS 5.1.1 the same container path returns the
// same proxy object, an empty path returns the +appearance proxy, and a class that is not a
// UIAppearanceContainer raises UIKit's own exception (checked on device).
//
// Installed on UIView and UIBarItem, the two UIKit classes that adopt UIAppearance, with
// class_addMethod only when the class lacks the method, so iOS 9+ keeps its native one.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

void UICInstallAppearanceContainment(void);

// Containment paths are a handful of classes deep in practice; UIKit walks the view's superviews.
enum { UICMaxAppearanceContainers = 15 };

static id UICAppearanceWhenContainedInInstancesOfClasses(id self, SEL _cmd, NSArray *containerTypes) {
    NSUInteger count = [containerTypes count];
    if (count > UICMaxAppearanceContainers)
        [NSException raise:NSInvalidArgumentException
                    format:@"+[%@ %s] supports at most %d container classes before iOS 9 (got %lu)",
                           self, sel_getName(_cmd), UICMaxAppearanceContainers, (unsigned long)count];
    // nil-terminated: the variadic method stops at the first nil, so the unused trailing slots are never read.
    __unsafe_unretained Class containers[UICMaxAppearanceContainers + 1] = {Nil};
    for (NSUInteger i = 0; i < count; i++) {
        id container = [containerTypes objectAtIndex:i];
        if (!container || !class_isMetaClass(object_getClass(container)))   // object_isClass is iOS 8
            [NSException raise:NSInvalidArgumentException format:@"+[%@ %s]: %@ is not a class", self, sel_getName(_cmd), container];
        containers[i] = (Class)container;
    }
    id (*variadic)(id, SEL, Class, ...) = (id (*)(id, SEL, Class, ...))objc_msgSend;
    return variadic(self, sel_registerName("appearanceWhenContainedIn:"),
                    containers[0], containers[1], containers[2], containers[3], containers[4], containers[5],
                    containers[6], containers[7], containers[8], containers[9], containers[10], containers[11],
                    containers[12], containers[13], containers[14], containers[15]);
}

void UICInstallAppearanceContainment(void) {
    SEL variadic = sel_registerName("appearanceWhenContainedIn:");
    SEL array = sel_registerName("appearanceWhenContainedInInstancesOfClasses:");
    const char *classNames[] = {"UIView", "UIBarItem"};
    for (unsigned i = 0; i < sizeof classNames / sizeof classNames[0]; i++) {
        Class meta = object_getClass(objc_getClass(classNames[i]));
        if (!meta || !class_getInstanceMethod(meta, variadic) || class_getInstanceMethod(meta, array)) continue;
        class_addMethod(meta, array, (IMP)UICAppearanceWhenContainedInInstancesOfClasses, "@@:@");
    }
}
