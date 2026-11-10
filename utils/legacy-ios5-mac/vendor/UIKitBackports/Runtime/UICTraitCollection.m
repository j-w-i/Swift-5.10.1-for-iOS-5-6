//
//  UICTraitCollection.m
//  UIKitBackports runtime
//
//  UITraitCollection (iOS 8) and the trait plumbing around it for the legacy runtime.
//
//  Behaviour was modelled on Apple's real class, observed through the iOS 27 simulator: unspecified
//  defaults, later-wins merging, containsTraitsInCollection:, equality/hash, description format,
//  secure coding, and how a screen, window, view hierarchy and child view controllers resolve traits.
//  The class is registered ONLY when UIKit lacks it, so iOS 8+ always uses Apple's implementation.
//
//  Size classes before iOS 8: every device that cannot run iOS 8 is a small iPhone/iPod (compact
//  width, compact height only in landscape) or an iPad (regular/regular), which is exactly what the
//  system reports for those devices once it has size classes.
//
//  Not replicated: Apple's private traits (image dynamic range, HDR headroom, scene capture state,
//  list/tab-accessory environments) and the dynamic-appearance / image-configuration categories.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Exported content size category constants (values identical to UIKit's)

NSString *const SwiftLegacyUIContentSizeCategoryUnspecified = @"_UICTContentSizeCategoryUnspecified";
NSString *const SwiftLegacyUIContentSizeCategoryExtraSmall = @"UICTContentSizeCategoryXS";
NSString *const SwiftLegacyUIContentSizeCategorySmall = @"UICTContentSizeCategoryS";
NSString *const SwiftLegacyUIContentSizeCategoryMedium = @"UICTContentSizeCategoryM";
NSString *const SwiftLegacyUIContentSizeCategoryLarge = @"UICTContentSizeCategoryL";
NSString *const SwiftLegacyUIContentSizeCategoryExtraLarge = @"UICTContentSizeCategoryXL";
NSString *const SwiftLegacyUIContentSizeCategoryExtraExtraLarge = @"UICTContentSizeCategoryXXL";
NSString *const SwiftLegacyUIContentSizeCategoryExtraExtraExtraLarge = @"UICTContentSizeCategoryXXXL";
NSString *const SwiftLegacyUIContentSizeCategoryAccessibilityMedium = @"UICTContentSizeCategoryAccessibilityM";
NSString *const SwiftLegacyUIContentSizeCategoryAccessibilityLarge = @"UICTContentSizeCategoryAccessibilityL";
NSString *const SwiftLegacyUIContentSizeCategoryAccessibilityExtraLarge = @"UICTContentSizeCategoryAccessibilityXL";
NSString *const SwiftLegacyUIContentSizeCategoryAccessibilityExtraExtraLarge = @"UICTContentSizeCategoryAccessibilityXXL";
NSString *const SwiftLegacyUIContentSizeCategoryAccessibilityExtraExtraExtraLarge = @"UICTContentSizeCategoryAccessibilityXXXL";

#pragma mark - Trait storage

typedef struct {
    NSInteger idiom, style, direction, horizontal, vertical, force, gamut, contrast, level, weight, active;
    double scale;
    CFTypeRef category;       // retained NSString, NULL when unspecified
} UICTraits;

static ptrdiff_t UICTraitOffset;
static inline UICTraits *UICT(id object) {
    return (UICTraits *)((char *)(__bridge void *)object + UICTraitOffset);
}
static void UICTraitsReset(UICTraits *t) {
    memset(t, 0, sizeof(*t));
    t->idiom = -1; t->direction = -1; t->gamut = -1; t->contrast = -1; t->level = -1; t->weight = -1; t->active = -1;
}
static BOOL UICTraitsEqual(const UICTraits *a, const UICTraits *b) {
    if (a->idiom != b->idiom || a->style != b->style || a->direction != b->direction ||
        a->horizontal != b->horizontal || a->vertical != b->vertical || a->force != b->force ||
        a->gamut != b->gamut || a->contrast != b->contrast || a->level != b->level ||
        a->weight != b->weight || a->active != b->active || a->scale != b->scale) return NO;
    if (a->category == b->category) return YES;
    if (!a->category || !b->category) return NO;
    return [(__bridge NSString *)a->category isEqualToString:(__bridge NSString *)b->category];
}
static Class UICTraitClass(void) { return NSClassFromString(@"UITraitCollection"); }
static id UICTraitsNew(void) { return [[UICTraitClass() alloc] init]; }

#pragma mark - Description names

static NSString *UICIdiomName(NSInteger v) {
    switch (v) { case 0: return @"Phone"; case 1: return @"Pad"; case 2: return @"TV"; case 3: return @"CarPlay"; case 5: return @"Mac"; default: return @"Unspecified"; }
}
static NSString *UICSizeClassName(NSInteger v) { return v == 1 ? @"Compact" : (v == 2 ? @"Regular" : @"Unspecified"); }

#pragma mark - UITraitCollection template (cloned under Apple's name only when absent)

@interface UICTraitCollectionT : NSObject <NSCopying, NSSecureCoding>
@end

@implementation UICTraitCollectionT
- (instancetype)init {
    if ((self = [super init])) UICTraitsReset(UICT(self));
    return self;
}
- (void)dealloc {
    UICTraits *t = UICT(self);
    if (t->category) { CFRelease(t->category); t->category = NULL; }
}
- (NSInteger)userInterfaceIdiom { return UICT(self)->idiom; }
- (NSInteger)userInterfaceStyle { return UICT(self)->style; }
- (NSInteger)layoutDirection { return UICT(self)->direction; }
- (NSInteger)horizontalSizeClass { return UICT(self)->horizontal; }
- (NSInteger)verticalSizeClass { return UICT(self)->vertical; }
- (NSInteger)forceTouchCapability { return UICT(self)->force; }
- (NSInteger)displayGamut { return UICT(self)->gamut; }
- (NSInteger)accessibilityContrast { return UICT(self)->contrast; }
- (NSInteger)userInterfaceLevel { return UICT(self)->level; }
- (NSInteger)legibilityWeight { return UICT(self)->weight; }
- (NSInteger)activeAppearance { return UICT(self)->active; }
- (CGFloat)displayScale { return (CGFloat)UICT(self)->scale; }
- (NSString *)preferredContentSizeCategory {
    CFTypeRef c = UICT(self)->category;
    return c ? (__bridge NSString *)c : SwiftLegacyUIContentSizeCategoryUnspecified;
}

#define UIC_FACTORY(NAME, FIELD, TYPE) \
+ (instancetype)traitCollectionWith##NAME:(TYPE)value { id t = UICTraitsNew(); UICT(t)->FIELD = value; return t; }
UIC_FACTORY(UserInterfaceIdiom, idiom, NSInteger)
UIC_FACTORY(UserInterfaceStyle, style, NSInteger)
UIC_FACTORY(LayoutDirection, direction, NSInteger)
UIC_FACTORY(HorizontalSizeClass, horizontal, NSInteger)
UIC_FACTORY(VerticalSizeClass, vertical, NSInteger)
UIC_FACTORY(ForceTouchCapability, force, NSInteger)
UIC_FACTORY(DisplayGamut, gamut, NSInteger)
UIC_FACTORY(AccessibilityContrast, contrast, NSInteger)
UIC_FACTORY(UserInterfaceLevel, level, NSInteger)
UIC_FACTORY(LegibilityWeight, weight, NSInteger)
UIC_FACTORY(ActiveAppearance, active, NSInteger)
+ (instancetype)traitCollectionWithDisplayScale:(CGFloat)scale { id t = UICTraitsNew(); UICT(t)->scale = scale; return t; }
+ (instancetype)traitCollectionWithPreferredContentSizeCategory:(NSString *)category {
    id t = UICTraitsNew();
    if (category && ![category isEqualToString:SwiftLegacyUIContentSizeCategoryUnspecified])
        UICT(t)->category = CFBridgingRetain([category copy]);
    return t;
}
+ (instancetype)traitCollectionWithTraitsFromCollections:(NSArray *)collections {
    id result = UICTraitsNew();
    UICTraits *r = UICT(result);
    for (id other in collections) {
        if (![other isKindOfClass:UICTraitClass()]) continue;
        const UICTraits *o = UICT(other);
        if (o->idiom != -1) r->idiom = o->idiom;
        if (o->style != 0) r->style = o->style;
        if (o->direction != -1) r->direction = o->direction;
        if (o->horizontal != 0) r->horizontal = o->horizontal;
        if (o->vertical != 0) r->vertical = o->vertical;
        if (o->force != 0) r->force = o->force;
        if (o->gamut != -1) r->gamut = o->gamut;
        if (o->contrast != -1) r->contrast = o->contrast;
        if (o->level != -1) r->level = o->level;
        if (o->weight != -1) r->weight = o->weight;
        if (o->active != -1) r->active = o->active;
        if (o->scale != 0) r->scale = o->scale;
        if (o->category) {
            if (r->category) CFRelease(r->category);
            r->category = CFRetain(o->category);
        }
    }
    return result;
}
- (BOOL)containsTraitsInCollection:(id)other {
    if (!other) return YES;
    const UICTraits *s = UICT(self), *o = UICT(other);
    if (o->idiom != -1 && o->idiom != s->idiom) return NO;
    if (o->style != 0 && o->style != s->style) return NO;
    if (o->direction != -1 && o->direction != s->direction) return NO;
    if (o->horizontal != 0 && o->horizontal != s->horizontal) return NO;
    if (o->vertical != 0 && o->vertical != s->vertical) return NO;
    if (o->force != 0 && o->force != s->force) return NO;
    if (o->gamut != -1 && o->gamut != s->gamut) return NO;
    if (o->contrast != -1 && o->contrast != s->contrast) return NO;
    if (o->level != -1 && o->level != s->level) return NO;
    if (o->weight != -1 && o->weight != s->weight) return NO;
    if (o->active != -1 && o->active != s->active) return NO;
    if (o->scale != 0 && o->scale != s->scale) return NO;
    if (o->category && !(s->category && [(__bridge NSString *)o->category isEqualToString:(__bridge NSString *)s->category])) return NO;
    return YES;
}
- (BOOL)isEqual:(id)other {
    if (other == self) return YES;
    if (![other isKindOfClass:UICTraitClass()]) return NO;
    return UICTraitsEqual(UICT(self), UICT(other));
}
- (NSUInteger)hash {
    const UICTraits *t = UICT(self);
    NSUInteger h = (NSUInteger)(t->idiom + 7);
    h = h * 31 + (NSUInteger)t->style; h = h * 31 + (NSUInteger)(t->direction + 3);
    h = h * 31 + (NSUInteger)t->horizontal; h = h * 31 + (NSUInteger)t->vertical;
    h = h * 31 + (NSUInteger)t->force; h = h * 31 + (NSUInteger)(t->gamut + 3);
    h = h * 31 + (NSUInteger)(t->contrast + 3); h = h * 31 + (NSUInteger)(t->level + 3);
    h = h * 31 + (NSUInteger)(t->weight + 3); h = h * 31 + (NSUInteger)(t->active + 3);
    h = h * 31 + (NSUInteger)(t->scale * 4);
    if (t->category) h = h * 31 + [(__bridge NSString *)t->category hash];
    return h;
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (NSString *)description {
    const UICTraits *t = UICT(self);
    NSMutableArray *parts = [NSMutableArray array];
    if (t->idiom != -1) [parts addObject:[NSString stringWithFormat:@"UserInterfaceIdiom = %@", UICIdiomName(t->idiom)]];
    if (t->scale != 0) [parts addObject:[NSString stringWithFormat:@"DisplayScale = %g", t->scale]];
    if (t->gamut != -1) [parts addObject:[NSString stringWithFormat:@"DisplayGamut = %@", t->gamut == 1 ? @"P3" : @"SRGB"]];
    if (t->horizontal != 0) [parts addObject:[NSString stringWithFormat:@"HorizontalSizeClass = %@", UICSizeClassName(t->horizontal)]];
    if (t->vertical != 0) [parts addObject:[NSString stringWithFormat:@"VerticalSizeClass = %@", UICSizeClassName(t->vertical)]];
    if (t->style != 0) [parts addObject:[NSString stringWithFormat:@"UserInterfaceStyle = %@", t->style == 2 ? @"Dark" : @"Light"]];
    if (t->direction != -1) [parts addObject:[NSString stringWithFormat:@"UserInterfaceLayoutDirection = %@", t->direction == 1 ? @"RTL" : @"LTR"]];
    if (t->force != 0) [parts addObject:[NSString stringWithFormat:@"ForceTouchCapability = %@", t->force == 2 ? @"Available" : @"Unavailable"]];
    if (t->category) {
        NSString *name = (__bridge NSString *)t->category;
        if ([name hasPrefix:@"UICTContentSizeCategory"]) name = [name substringFromIndex:[@"UICTContentSizeCategory" length]];
        [parts addObject:[NSString stringWithFormat:@"PreferredContentSizeCategory = %@", name]];
    }
    if (t->contrast != -1) [parts addObject:[NSString stringWithFormat:@"AccessibilityContrast = %@", t->contrast == 1 ? @"High" : @"Normal"]];
    if (t->level != -1) [parts addObject:[NSString stringWithFormat:@"UserInterfaceLevel = %@", t->level == 1 ? @"Elevated" : @"Base"]];
    if (t->weight != -1) [parts addObject:[NSString stringWithFormat:@"LegibilityWeight = %@", t->weight == 1 ? @"Bold" : @"Default"]];
    if (t->active != -1) [parts addObject:[NSString stringWithFormat:@"ActiveAppearance = %@", t->active == 1 ? @"Active" : @"Inactive"]];
    return [NSString stringWithFormat:@"<%@: %p; %@>", NSStringFromClass([self class]), self, [parts componentsJoinedByString:@", "]];
}
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)c {
    const UICTraits *t = UICT(self);
    [c encodeInteger:t->idiom forKey:@"UITraitUserInterfaceIdiom"]; [c encodeInteger:t->style forKey:@"UITraitUserInterfaceStyle"];
    [c encodeInteger:t->direction forKey:@"UITraitLayoutDirection"]; [c encodeInteger:t->horizontal forKey:@"UITraitHorizontalSizeClass"];
    [c encodeInteger:t->vertical forKey:@"UITraitVerticalSizeClass"]; [c encodeInteger:t->force forKey:@"UITraitForceTouchCapability"];
    [c encodeInteger:t->gamut forKey:@"UITraitDisplayGamut"]; [c encodeInteger:t->contrast forKey:@"UITraitAccessibilityContrast"];
    [c encodeInteger:t->level forKey:@"UITraitUserInterfaceLevel"]; [c encodeInteger:t->weight forKey:@"UITraitLegibilityWeight"];
    [c encodeInteger:t->active forKey:@"UITraitActiveAppearance"]; [c encodeDouble:t->scale forKey:@"UITraitDisplayScale"];
    if (t->category) [c encodeObject:(__bridge NSString *)t->category forKey:@"UITraitPreferredContentSizeCategory"];
}
- (instancetype)initWithCoder:(NSCoder *)c {
    if ((self = [self init])) {
        UICTraits *t = UICT(self);
        t->idiom = [c decodeIntegerForKey:@"UITraitUserInterfaceIdiom"]; t->style = [c decodeIntegerForKey:@"UITraitUserInterfaceStyle"];
        t->direction = [c decodeIntegerForKey:@"UITraitLayoutDirection"]; t->horizontal = [c decodeIntegerForKey:@"UITraitHorizontalSizeClass"];
        t->vertical = [c decodeIntegerForKey:@"UITraitVerticalSizeClass"]; t->force = [c decodeIntegerForKey:@"UITraitForceTouchCapability"];
        t->gamut = [c decodeIntegerForKey:@"UITraitDisplayGamut"]; t->contrast = [c decodeIntegerForKey:@"UITraitAccessibilityContrast"];
        t->level = [c decodeIntegerForKey:@"UITraitUserInterfaceLevel"]; t->weight = [c decodeIntegerForKey:@"UITraitLegibilityWeight"];
        t->active = [c decodeIntegerForKey:@"UITraitActiveAppearance"]; t->scale = [c decodeDoubleForKey:@"UITraitDisplayScale"];
        NSString *category = [c decodeObjectForKey:@"UITraitPreferredContentSizeCategory"];
        if (category) t->category = CFBridgingRetain([category copy]);
    }
    return self;
}
@end

#pragma mark - Trait resolution for screens, windows, views and controllers

static id UICMerge(id base, id over) {
    if (!over) return base;
    return [UICTraitClass() traitCollectionWithTraitsFromCollections:[NSArray arrayWithObjects:base, over, nil]];
}
static id UICScreenTraits(void) {
    id t = UICTraitsNew();
    UICTraits *r = UICT(t);
    r->idiom = UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad ? 1 : 0;
    r->scale = [[UIScreen mainScreen] scale];
    r->gamut = 0;                                                    // sRGB hardware
    r->style = 1;                                                    // light
    r->direction = [[UIApplication sharedApplication] userInterfaceLayoutDirection] == UIUserInterfaceLayoutDirectionRightToLeft ? 1 : 0;
    r->force = 1;                                                    // unavailable
    r->category = CFBridgingRetain(SwiftLegacyUIContentSizeCategoryMedium);
    r->contrast = 0; r->level = 0;
    return t;
}
static UIInterfaceOrientation UICTraitOrientationOverride;
static BOOL UICTraitOrientationOverridden;
static UIInterfaceOrientation UICCurrentOrientation(void) {
    return UICTraitOrientationOverridden ? UICTraitOrientationOverride : [[UIApplication sharedApplication] statusBarOrientation];
}
static id UICWindowTraits(void) {
    id t = UICTraitsNew();
    UICTraits *r = UICT(t);
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) { r->horizontal = 2; r->vertical = 2; }
    else { r->horizontal = 1; r->vertical = UIInterfaceOrientationIsLandscape(UICCurrentOrientation()) ? 1 : 2; }
    return UICMerge(UICScreenTraits(), t);
}
/// Traits a scene reports: those of a window on the screen.
id UICSceneTraitCollection(void) { return UICWindowTraits(); }

static const void *UICOverrideKey = &UICOverrideKey;

@interface UICTraitAdditions : NSObject @end
@implementation UICTraitAdditions
- (id)uic_screenTraitCollection { return UICScreenTraits(); }
- (id)uic_windowTraitCollection { return UICWindowTraits(); }
- (id)uic_viewTraitCollection {
    UIView *view = (UIView *)(id)self;
    UIResponder *next = [view nextResponder];
    if ([next isKindOfClass:[UIViewController class]] && [(UIViewController *)next isViewLoaded] && [(UIViewController *)next view] == view)
        return [(id)next traitCollection];
    UIView *parent = [view superview];
    if (parent) return [(id)parent traitCollection];
    if ([view isKindOfClass:[UIWindow class]]) return UICWindowTraits();
    return UICScreenTraits();
}
- (id)uic_controllerTraitCollection {
    UIViewController *controller = (UIViewController *)(id)self;
    UIViewController *parent = [controller parentViewController];
    if (parent) {
        id override = [(id)parent overrideTraitCollectionForChildViewController:controller];
        return UICMerge([(id)parent traitCollection], override);
    }
    UIWindow *window = [controller isViewLoaded] ? [[controller view] window] : nil;
    return window ? UICWindowTraits() : UICScreenTraits();
}
- (void)uic_noopTraitDidChange:(id)previous {}
- (id)uic_overrideForChild:(UIViewController *)child {
    if ([child parentViewController] != (UIViewController *)(id)self) return nil;
    return objc_getAssociatedObject(child, UICOverrideKey);
}
- (void)uic_setOverride:(id)override forChild:(UIViewController *)child {
    objc_setAssociatedObject(child, UICOverrideKey, override, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

#pragma mark - Trait change delivery

static IMP UICDefaultViewDidChange, UICDefaultControllerDidChange;
static BOOL UICOverridesDidChange(id object, IMP defaultImp) {
    Method m = class_getInstanceMethod(object_getClass(object), sel_registerName("traitCollectionDidChange:"));
    return m && method_getImplementation(m) != defaultImp;
}
static void UICDeliverController(UIViewController *controller, UIInterfaceOrientation old) {
    if (UICOverridesDidChange(controller, UICDefaultControllerDidChange)) {
        UICTraitOrientationOverride = old; UICTraitOrientationOverridden = YES;
        id previous = [(id)controller traitCollection];
        UICTraitOrientationOverridden = NO;
        id current = [(id)controller traitCollection];
        if (![previous isEqual:current]) ((void (*)(id, SEL, id))objc_msgSend)(controller, sel_registerName("traitCollectionDidChange:"), previous);
    }
    for (UIViewController *child in [controller childViewControllers]) UICDeliverController(child, old);
}
static void UICDeliverView(UIView *view, UIInterfaceOrientation old) {
    if (UICOverridesDidChange(view, UICDefaultViewDidChange)) {
        UICTraitOrientationOverride = old; UICTraitOrientationOverridden = YES;
        id previous = [(id)view traitCollection];
        UICTraitOrientationOverridden = NO;
        id current = [(id)view traitCollection];
        if (![previous isEqual:current]) ((void (*)(id, SEL, id))objc_msgSend)(view, sel_registerName("traitCollectionDidChange:"), previous);
    }
    for (UIView *sub in [view subviews]) UICDeliverView(sub, old);
}
static UIInterfaceOrientation UICLastOrientation;
static void UICOrientationChanged(NSNotification *note) {
    UIInterfaceOrientation now = [[UIApplication sharedApplication] statusBarOrientation];
    UIInterfaceOrientation old = UICLastOrientation;
    UICLastOrientation = now;
    if (old == now) return;
    for (UIWindow *window in [[UIApplication sharedApplication] windows]) {
        UIViewController *root = [window rootViewController];
        if (root) UICDeliverController(root, old);
        UICDeliverView(window, old);
    }
}

#pragma mark - Installation

static void UICAddIfMissing(Class target, SEL targetSelector, Class template, SEL templateSelector) {
    if (!target || class_getInstanceMethod(target, targetSelector)) return;
    Method m = class_getInstanceMethod(template, templateSelector);
    class_addMethod(target, targetSelector, method_getImplementation(m), method_getTypeEncoding(m));
}

void UICInstallTraitCollection(void) {
    if (objc_getClass("UITraitCollection")) return;      // iOS 8+: Apple's implementation is used as-is.

    Class created = objc_allocateClassPair([NSObject class], "UITraitCollection", 0);
    if (!created) return;
    class_addIvar(created, "_uicTraits", sizeof(UICTraits), 3, "{?=}");
    unsigned count = 0;
    Method *methods = class_copyMethodList([UICTraitCollectionT class], &count);
    for (unsigned i = 0; i < count; i++)
        class_addMethod(created, method_getName(methods[i]), method_getImplementation(methods[i]), method_getTypeEncoding(methods[i]));
    free(methods);
    methods = class_copyMethodList(object_getClass([UICTraitCollectionT class]), &count);
    for (unsigned i = 0; i < count; i++)
        class_addMethod(object_getClass(created), method_getName(methods[i]), method_getImplementation(methods[i]), method_getTypeEncoding(methods[i]));
    free(methods);
    Protocol *__unsafe_unretained *protocols = class_copyProtocolList([UICTraitCollectionT class], &count);
    for (unsigned i = 0; i < count; i++) class_addProtocol(created, protocols[i]);
    free(protocols);
    objc_registerClassPair(created);
    UICTraitOffset = ivar_getOffset(class_getInstanceVariable(created, "_uicTraits"));

    Class tr = [UICTraitAdditions class];
    UICAddIfMissing([UIScreen class], @selector(traitCollection), tr, @selector(uic_screenTraitCollection));
    UICAddIfMissing([UIWindow class], @selector(traitCollection), tr, @selector(uic_windowTraitCollection));
    UICAddIfMissing([UIView class], @selector(traitCollection), tr, @selector(uic_viewTraitCollection));
    UICAddIfMissing([UIViewController class], @selector(traitCollection), tr, @selector(uic_controllerTraitCollection));
    // A window answers as a window, not as a plain view.
    class_replaceMethod([UIWindow class], @selector(traitCollection),
        method_getImplementation(class_getInstanceMethod(tr, @selector(uic_windowTraitCollection))), "@@:");
    UICAddIfMissing([UIView class], sel_registerName("traitCollectionDidChange:"), tr, @selector(uic_noopTraitDidChange:));
    UICAddIfMissing([UIViewController class], sel_registerName("traitCollectionDidChange:"), tr, @selector(uic_noopTraitDidChange:));
    UICDefaultViewDidChange = method_getImplementation(class_getInstanceMethod([UIView class], sel_registerName("traitCollectionDidChange:")));
    UICDefaultControllerDidChange = method_getImplementation(class_getInstanceMethod([UIViewController class], sel_registerName("traitCollectionDidChange:")));
    UICAddIfMissing([UIViewController class], sel_registerName("overrideTraitCollectionForChildViewController:"), tr, @selector(uic_overrideForChild:));
    UICAddIfMissing([UIViewController class], sel_registerName("setOverrideTraitCollection:forChildViewController:"), tr, @selector(uic_setOverride:forChild:));

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification object:nil queue:nil
        usingBlock:^(NSNotification *note) { UICOrientationChanged(note); }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil queue:nil
        usingBlock:^(NSNotification *note) { UICLastOrientation = [[UIApplication sharedApplication] statusBarOrientation]; }];
}
