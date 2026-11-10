// Author-owned toolchain integration. See THIRD-PARTY-NOTICES.md.
#import "UIKitBackports.h"
#import "UICVisualFormat.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdarg.h>
#import <CoreText/CoreText.h>

// Deferred Swift-bridge installation (defined with the image constructor below).
static void UICEnsureSwiftBridge(void);

NSDictionary *UICDictionaryOfVariableBindings(NSString *names, id firstValue, ...) {
    NSArray *keys = [names componentsSeparatedByString:@","];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    va_list arguments; va_start(arguments, firstValue); id value = firstValue;
    for (NSString *raw in keys) {
        if (!value) { va_end(arguments); [NSException raise:NSInvalidArgumentException format:@"Nil value in variable bindings: %@", names]; }
        NSString *key = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [result setObject:value forKey:key]; value = va_arg(arguments, id);
    }
    va_end(arguments); return result;
}

extern id UICLegacyGuideProxyView(id item);
static UIView *UICConstraintItem(id item) {
    if (item && ![item isKindOfClass:[UIView class]] && ![item isKindOfClass:[UICLayoutGuide class]]) {
        id proxy = UICLegacyGuideProxyView(item);
        if (proxy) return proxy;
    }
    return [item isKindOfClass:[UICLayoutGuide class]] ? [(UICLayoutGuide *)item proxyView] : item;
}
id UICMakeConstraint(id first, NSInteger attribute, NSInteger relation, id second, NSInteger secondAttribute, CGFloat multiplier, CGFloat constant) {
    UICEnsureSwiftBridge();
    Class cls = NSClassFromString(@"NSLayoutConstraint");
    SEL selector = @selector(initWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:);
    if (!cls || !class_getInstanceMethod(cls, selector))
        [NSException raise:NSInternalInconsistencyException format:@"Auto Layout runtime not installed"];
    typedef id (*Initializer)(id, SEL, id, NSInteger, NSInteger, id, NSInteger, CGFloat, CGFloat);
    return ((Initializer)objc_msgSend)([cls alloc], selector, UICConstraintItem(first), attribute, relation,
                                     UICConstraintItem(second), secondAttribute, multiplier, constant);
}
static id UICConstraintFactory(id cls, SEL command, id first, NSInteger attribute, NSInteger relation, id second, NSInteger secondAttribute, CGFloat multiplier, CGFloat constant) {
    return UICMakeConstraint(first, attribute, relation, second, secondAttribute, multiplier, constant);
}
static id (*UICNativeConstraintFactory)(id, SEL, id, NSInteger, NSInteger, id, NSInteger, CGFloat, CGFloat);
static id UICUnwrappingConstraintFactory(id cls, SEL command, id first, NSInteger attribute, NSInteger relation, id second, NSInteger secondAttribute, CGFloat multiplier, CGFloat constant) {
    return UICNativeConstraintFactory(cls, command, UICConstraintItem(first), attribute, relation, UICConstraintItem(second), secondAttribute, multiplier, constant);
}
static id UICVisualFormatFactory(id cls, SEL command, NSString *format, NSUInteger options, NSDictionary *metrics, NSDictionary *views) {
    return UICConstraintsWithVisualFormat(format, options, metrics, views);
}
// The native factory (iOS 6+) rejects the backport guide object ("Constraint items must each be a
// view or layout guide"); route it through the guide's proxy view. Pure Objective-C runtime work, so
// it is safe from the image constructor and runs before any Swift code can build a constraint.
static void UICInstallConstraintItemUnwrapping(void) {
    Class cls = NSClassFromString(@"NSLayoutConstraint");
    SEL factory = @selector(constraintWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:);
    Method native = cls ? class_getClassMethod(cls, factory) : NULL;
    if (!native || UICNativeConstraintFactory) return;
    UICNativeConstraintFactory = (id (*)(id, SEL, id, NSInteger, NSInteger, id, NSInteger, CGFloat, CGFloat))method_getImplementation(native);
    method_setImplementation(native, (IMP)UICUnwrappingConstraintFactory);
}
void UICInstallConstraintClassMethods(void) {
    Class cls = NSClassFromString(@"NSLayoutConstraint");
    if (!cls) return;
    // Strictly additive: native iOS 6 implementations always win.
    SEL factory = @selector(constraintWithItem:attribute:relatedBy:toItem:attribute:multiplier:constant:);
    SEL vfl = @selector(constraintsWithVisualFormat:options:metrics:views:);
    if (!class_getClassMethod(cls, factory)) class_addMethod(object_getClass(cls), factory, (IMP)UICConstraintFactory, "@@:@ii@iff");
    else UICInstallConstraintItemUnwrapping();
    if (!class_getClassMethod(cls, vfl)) class_addMethod(object_getClass(cls), vfl, (IMP)UICVisualFormatFactory, "@@:@I@@");
}

@implementation UICLayoutAnchor
- (id)constraintEqualToAnchor:(UICLayoutAnchor *)other { return [self constraintEqualToAnchor:other constant:0]; }
- (id)constraintEqualToAnchor:(UICLayoutAnchor *)other constant:(CGFloat)value { return UICMakeConstraint(self.item, self.attribute, 0, other.item, other.attribute, 1, value); }
- (id)constraintGreaterThanOrEqualToAnchor:(UICLayoutAnchor *)other { return [self constraintGreaterThanOrEqualToAnchor:other constant:0]; }
- (id)constraintGreaterThanOrEqualToAnchor:(UICLayoutAnchor *)other constant:(CGFloat)value { return UICMakeConstraint(self.item, self.attribute, 1, other.item, other.attribute, 1, value); }
- (id)constraintLessThanOrEqualToAnchor:(UICLayoutAnchor *)other { return [self constraintLessThanOrEqualToAnchor:other constant:0]; }
- (id)constraintLessThanOrEqualToAnchor:(UICLayoutAnchor *)other constant:(CGFloat)value { return UICMakeConstraint(self.item, self.attribute, -1, other.item, other.attribute, 1, value); }
@end
@implementation UICXAxisAnchor @end
@implementation UICYAxisAnchor @end
@implementation UICLayoutDimension
- (id)constraintEqualToConstant:(CGFloat)value { return UICMakeConstraint(self.item, self.attribute, 0, nil, 0, 1, value); }
- (id)constraintGreaterThanOrEqualToConstant:(CGFloat)value { return UICMakeConstraint(self.item, self.attribute, 1, nil, 0, 1, value); }
- (id)constraintLessThanOrEqualToConstant:(CGFloat)value { return UICMakeConstraint(self.item, self.attribute, -1, nil, 0, 1, value); }
- (id)constraintEqualToAnchor:(UICLayoutDimension *)other multiplier:(CGFloat)multiplier { return [self constraintEqualToAnchor:other multiplier:multiplier constant:0]; }
- (id)constraintEqualToAnchor:(UICLayoutDimension *)other multiplier:(CGFloat)multiplier constant:(CGFloat)value { return UICMakeConstraint(self.item, self.attribute, 0, other.item, other.attribute, multiplier, value); }
- (id)constraintGreaterThanOrEqualToAnchor:(UICLayoutDimension *)other multiplier:(CGFloat)multiplier { return [self constraintGreaterThanOrEqualToAnchor:other multiplier:multiplier constant:0]; }
- (id)constraintGreaterThanOrEqualToAnchor:(UICLayoutDimension *)other multiplier:(CGFloat)multiplier constant:(CGFloat)value { return UICMakeConstraint(self.item, self.attribute, 1, other.item, other.attribute, multiplier, value); }
- (id)constraintLessThanOrEqualToAnchor:(UICLayoutDimension *)other multiplier:(CGFloat)multiplier { return [self constraintLessThanOrEqualToAnchor:other multiplier:multiplier constant:0]; }
- (id)constraintLessThanOrEqualToAnchor:(UICLayoutDimension *)other multiplier:(CGFloat)multiplier constant:(CGFloat)value { return UICMakeConstraint(self.item, self.attribute, -1, other.item, other.attribute, multiplier, value); }
@end
static id UICAnchor(id item, NSInteger attribute) {
    Class cls = (attribute == 7 || attribute == 8) ? [UICLayoutDimension class] :
                (attribute == 3 || attribute == 4 || attribute == 10) ? [UICYAxisAnchor class] : [UICXAxisAnchor class];
    UICLayoutAnchor *anchor = [cls new]; anchor.item = item; anchor.attribute = attribute; return anchor;
}
#define UIC_ANCHOR_GETTERS \
- (id)leftAnchor { return UICAnchor(self, 1); } \
- (id)rightAnchor { return UICAnchor(self, 2); } \
- (id)topAnchor { return UICAnchor(self, 3); } \
- (id)bottomAnchor { return UICAnchor(self, 4); } \
- (id)leadingAnchor { return UICAnchor(self, 5); } \
- (id)trailingAnchor { return UICAnchor(self, 6); } \
- (id)widthAnchor { return UICAnchor(self, 7); } \
- (id)heightAnchor { return UICAnchor(self, 8); } \
- (id)centerXAnchor { return UICAnchor(self, 9); } \
- (id)centerYAnchor { return UICAnchor(self, 10); }
@implementation UICLayoutGuide {
    UIView *_proxyView;
}
- (instancetype)init { if ((self = [super init])) { _proxyView = [UIView new]; _proxyView.hidden = YES; _proxyView.userInteractionEnabled = NO; } return self; }
- (instancetype)initWithCoder:(NSCoder *)coder { self = [self init]; if (self) self.identifier = [coder decodeObjectForKey:@"identifier"]; return self; }
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:self.identifier forKey:@"identifier"]; }
- (UIView *)proxyView { return _proxyView; }
- (CGRect)layoutFrame { [self.owningView layoutIfNeeded]; return _proxyView.frame; }
UIC_ANCHOR_GETTERS
@end
static char guidesKey, marginsGuideKey, marginsKey, refreshKey;
void UICAddLayoutGuide(UIView *view, UICLayoutGuide *guide) {
    if (guide.owningView == view) return;
    if (guide.owningView) UICRemoveLayoutGuide(guide.owningView, guide);
    NSMutableArray *guides = objc_getAssociatedObject(view, &guidesKey);
    if (!guides) { guides = [NSMutableArray array]; objc_setAssociatedObject(view, &guidesKey, guides, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    [guides addObject:guide]; guide.owningView = view;
    guide.proxyView.frame = view.bounds; guide.proxyView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [view addSubview:guide.proxyView];
}
void UICRemoveLayoutGuide(UIView *view, UICLayoutGuide *guide) {
    if (guide.owningView != view) return;
    [(NSMutableArray *)objc_getAssociatedObject(view, &guidesKey) removeObjectIdenticalTo:guide];
    [guide.proxyView removeFromSuperview]; guide.owningView = nil;
}
static UIEdgeInsets UICMargins(UIView *view) {
    NSValue *value = objc_getAssociatedObject(view, &marginsKey);
    return value ? [value UIEdgeInsetsValue] : UIEdgeInsetsMake(8, 8, 8, 8);
}
@interface UICViewAdditions : NSObject @end
@implementation UICViewAdditions
UIC_ANCHOR_GETTERS
- (NSArray *)layoutGuides { return [objc_getAssociatedObject(self, &guidesKey) copy] ?: @[]; }
- (void)addLayoutGuide:(UICLayoutGuide *)guide { UICAddLayoutGuide((UIView *)(id)self, guide); }
- (void)removeLayoutGuide:(UICLayoutGuide *)guide { UICRemoveLayoutGuide((UIView *)(id)self, guide); }
- (UIEdgeInsets)layoutMargins { return UICMargins((UIView *)(id)self); }
- (void)setLayoutMargins:(UIEdgeInsets)value {
    objc_setAssociatedObject(self, &marginsKey, [NSValue valueWithUIEdgeInsets:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UICLayoutGuide *guide = objc_getAssociatedObject(self, &marginsGuideKey);
    if (guide) guide.proxyView.frame = UIEdgeInsetsInsetRect([(UIView *)(id)self bounds], value);
    [(id)self layoutMarginsDidChange];
}
- (void)layoutMarginsDidChange { [(UIView *)(id)self setNeedsLayout]; }
- (UICLayoutGuide *)layoutMarginsGuide {
    UICLayoutGuide *guide = objc_getAssociatedObject(self, &marginsGuideKey);
    if (!guide) {
        guide = [UICLayoutGuide new]; UICAddLayoutGuide((UIView *)(id)self, guide);
        UIEdgeInsets insets = [(id)self layoutMargins];
        guide.proxyView.frame = UIEdgeInsetsInsetRect([(UIView *)(id)self bounds], insets);
        objc_setAssociatedObject(self, &marginsGuideKey, guide, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return guide;
}
@end

@interface UICRefreshControl ()
@property(nonatomic, readwrite, getter=isRefreshing) BOOL refreshing;
- (void)attachToScrollView:(UIScrollView *)scroll;
@end
@implementation UICRefreshControl {
    UIActivityIndicatorView *_spinner;
    UILabel *_title;
    __weak UIScrollView *_scroll;
    BOOL _observing;
}
- (instancetype)init { return [self initWithFrame:CGRectMake(0, -60, 320, 60)]; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
        _spinner.hidesWhenStopped = YES; [self addSubview:_spinner];
        _title = [UILabel new]; _title.textAlignment = UITextAlignmentCenter; _title.backgroundColor = [UIColor clearColor]; [self addSubview:_title];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    } return self;
}
- (void)layoutSubviews { [super layoutSubviews]; _spinner.center = CGPointMake(CGRectGetMidX(self.bounds), 18); _title.frame = CGRectMake(0, 30, CGRectGetWidth(self.bounds), 25); }
- (void)setAttributedTitle:(NSAttributedString *)value { _attributedTitle = value; _title.text = [value string]; }
- (void)setTintColor:(UIColor *)value { _tintColor = value; _spinner.color = value; _title.textColor = value; }
- (void)beginRefreshing { if (self.refreshing) return; self.refreshing = YES; [_spinner startAnimating]; }
- (void)endRefreshing { self.refreshing = NO; [_spinner stopAnimating]; }
- (void)attachToScrollView:(UIScrollView *)scroll {
    if (_observing) { [_scroll removeObserver:self forKeyPath:@"contentOffset"]; _observing = NO; }
    _scroll = scroll;
    if (scroll) { [scroll addObserver:self forKeyPath:@"contentOffset" options:0 context:&refreshKey]; _observing = YES; }
}
- (void)observeValueForKeyPath:(NSString *)path ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &refreshKey) { [super observeValueForKeyPath:path ofObject:object change:change context:context]; return; }
    if (!self.refreshing && !_scroll.dragging && _scroll.contentOffset.y + _scroll.contentInset.top < -60) {
        [self beginRefreshing]; [self sendActionsForControlEvents:UIControlEventValueChanged];
    }
}
- (void)dealloc { if (_observing && _scroll) [_scroll removeObserver:self forKeyPath:@"contentOffset"]; }
@end
@interface UICScrollAdditions : NSObject @end
@implementation UICScrollAdditions
- (id)refreshControl { return objc_getAssociatedObject(self, &refreshKey); }
- (void)setRefreshControl:(UICRefreshControl *)control {
    UICRefreshControl *old = objc_getAssociatedObject(self, &refreshKey);
    if ([old isKindOfClass:[UICRefreshControl class]]) [old attachToScrollView:nil];
    [old removeFromSuperview];
    objc_setAssociatedObject(self, &refreshKey, control, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (control) {
        [(UIScrollView *)(id)self addSubview:control]; control.frame = CGRectMake(0, -60, CGRectGetWidth([(UIScrollView *)(id)self bounds]), 60);
        if ([control isKindOfClass:[UICRefreshControl class]]) [control attachToScrollView:(UIScrollView *)(id)self];
    }
}
@end
@implementation UICStackView
// The compiler binds `UIStackView` to this facade at build time because the deployment target is
// below iOS 9. On a system that ships the real UIStackView (iOS 9+), hand out the real class so the
// app gets Apple's implementation, not OAStackView. Only exact instances are redirected: an app
// subclass of UICStackView keeps its own class and the facade behaviour.
+ (instancetype)allocWithZone:(NSZone *)zone {
    if (self == [UICStackView class]) {
        Class native = NSClassFromString(@"UIStackView");
        if (native && native != self) return [native allocWithZone:zone];
    }
    return [super allocWithZone:zone];
}
- (instancetype)initWithArrangedSubviews:(NSArray *)views { UICEnsureSwiftBridge(); return [super initWithArrangedSubviews:views]; }
- (instancetype)initWithFrame:(CGRect)frame { UICEnsureSwiftBridge(); return [super initWithFrame:frame]; }
- (instancetype)initWithCoder:(NSCoder *)coder { UICEnsureSwiftBridge(); return [super initWithCoder:coder]; }
@end
// Genuine UIKit drawing API (iOS 7+) implemented for the legacy runtime. UIKit
// attribute names are the same strings CoreText consumes (NSFont/NSColor/
// NSUnderline), so the measurement is the real text system's own.
@interface UICStringDrawingAdditions : NSObject
- (CGSize)sizeWithAttributes:(NSDictionary *)attributes;
@end

@implementation UICStringDrawingAdditions
- (CGSize)sizeWithAttributes:(NSDictionary *)attributes {
    NSAttributedString *text = [[NSAttributedString alloc]
        initWithString:(NSString *)(id)self attributes:attributes];
    CTLineRef line = CTLineCreateWithAttributedString((CFAttributedStringRef)text);
    if (!line) return CGSizeZero;
    CGFloat ascent = 0, descent = 0, leading = 0;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CFRelease(line);
    return CGSizeMake((CGFloat)ceil(width), (CGFloat)ceil(ascent + descent + leading));
}
@end

static void UICInstallMissingMethods(Class target, Class template) {
    unsigned count = 0; Method *methods = class_copyMethodList(template, &count);
    for (unsigned i = 0; i < count; i++) {
        SEL selector = method_getName(methods[i]);
        if (!class_getInstanceMethod(target, selector)) class_addMethod(target, selector, method_getImplementation(methods[i]), method_getTypeEncoding(methods[i]));
    }
    free(methods);
}
// The Swift half of the bridge is deliberately NOT installed from a dyld image
// initializer and NOT from anything UIKit runs during application startup. On the
// legacy runtime, Swift-level work (bridging, dynamic casts, stdlib thunks) is
// only safe once the application is fully up. Installation is therefore triggered
// by the first real Auto Layout use, which is app code by definition.
static int UICBootstrapState = 0;  // 0 = pending, 1 = installed

static void UICEnsureSwiftBridge(void) {
    if (__sync_bool_compare_and_swap(&UICBootstrapState, 0, 1))
        UICLegacyInitializeAutoLayout();
}


// Full-screen layout default (iOS < 7 only).
//
// Source written for modern iOS expects a view controller's view to extend under
// the status bar: from iOS 7 `edgesForExtendedLayout` defaults to `.all`, and safe-area
// code (`safeAreaInsets.top` = status bar height) is written against that. iOS 5/6 default
// `wantsFullScreenLayout` to NO and inset the view below the status bar, which shifts every
// controller 20 pt down relative to the modern layout. The default is therefore YES here;
// an explicit `wantsFullScreenLayout = ...` from the app is always honoured, and the original
// setter still runs so UIKit relays out exactly as it does natively.
static const void *UICWantsFullScreenKey = &UICWantsFullScreenKey;
static void (*UICOriginalSetWantsFullScreen)(id, SEL, BOOL);
static BOOL UICWantsFullScreenLayoutGetter(id self, SEL _cmd) {
    NSNumber *explicitValue = objc_getAssociatedObject(self, UICWantsFullScreenKey);
    return explicitValue ? [explicitValue boolValue] : YES;
}
static void UICSetWantsFullScreenLayout(id self, SEL _cmd, BOOL value) {
    objc_setAssociatedObject(self, UICWantsFullScreenKey, [NSNumber numberWithBool:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (UICOriginalSetWantsFullScreen) UICOriginalSetWantsFullScreen(self, _cmd, value);
}
static void UICInstallFullScreenLayoutDefault(void) {
    // iOS 7.0 is CoreFoundation 847.20; earlier systems have the property and the old default.
    if (kCFCoreFoundationVersionNumber >= 847.20) return;
    Class controller = objc_getClass("UIViewController");
    SEL getterSelector = sel_registerName("wantsFullScreenLayout");
    SEL setterSelector = sel_registerName("setWantsFullScreenLayout:");
    Method getter = class_getInstanceMethod(controller, getterSelector);
    Method setter = class_getInstanceMethod(controller, setterSelector);
    if (!getter || !setter || UICOriginalSetWantsFullScreen) return;
    UICOriginalSetWantsFullScreen = (void (*)(id, SEL, BOOL))method_getImplementation(setter);
    method_setImplementation(getter, (IMP)UICWantsFullScreenLayoutGetter);
    method_setImplementation(setter, (IMP)UICSetWantsFullScreenLayout);
}

// iOS 7-10 inset the first scroll view of a view controller by the bars
// (`automaticallyAdjustsScrollViewInsets` defaults to YES). iOS 11 replaced that with
// `contentInsetAdjustmentBehavior`, which only insets a scroll view that really overlaps a safe
// area. Source written for iOS 11+ (nested collection views inside styled containers) therefore
// gets a spurious extra status-bar/nav-bar inset on iOS 7-10: sidebar icons start 20pt too low.
// The default is NO below iOS 11 so layout matches the native iOS 11+ result; an explicit
// assignment by the app is always honoured.
static const void *UICAutoAdjustKey = &UICAutoAdjustKey;
static BOOL UICAutoAdjustGetter(id self, SEL _cmd) {
    NSNumber *explicitValue = objc_getAssociatedObject(self, UICAutoAdjustKey);
    return explicitValue ? [explicitValue boolValue] : NO;
}
static void (*UICOriginalSetAutoAdjust)(id, SEL, BOOL);
static void UICSetAutoAdjust(id self, SEL _cmd, BOOL value) {
    objc_setAssociatedObject(self, UICAutoAdjustKey, [NSNumber numberWithBool:value], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (UICOriginalSetAutoAdjust) UICOriginalSetAutoAdjust(self, _cmd, value);
}
static void UICInstallAutoAdjustDefault(void) {
    if (kCFCoreFoundationVersionNumber >= 1443.00) return;   // iOS 11+: property is inert
    Class controller = objc_getClass("UIViewController");
    SEL getterSel = sel_registerName("automaticallyAdjustsScrollViewInsets");
    SEL setterSel = sel_registerName("setAutomaticallyAdjustsScrollViewInsets:");
    Method getter = controller ? class_getInstanceMethod(controller, getterSel) : NULL;
    Method setter = controller ? class_getInstanceMethod(controller, setterSel) : NULL;
    if (!getter || !setter) return;                           // iOS < 7 has no such behaviour
    UICOriginalSetAutoAdjust = (void (*)(id, SEL, BOOL))method_getImplementation(setter);
    method_setImplementation(getter, (IMP)UICAutoAdjustGetter);
    method_setImplementation(setter, (IMP)UICSetAutoAdjust);
}

// iOS 11 `UIView.safeAreaLayoutGuide` on systems that have Apple's own UILayoutGuide (iOS 9, 10).
// No armv7 system implements safe areas, and there the safe area equals the view's bounds, so the
// guide is Apple's native guide pinned to the view's edges with native anchors. Below iOS 9 the
// backport guide class provides the same property (Swift overlay), so this is only installed when
// the native guide class exists but the property does not.
static const void *UICSafeAreaGuideKey = &UICSafeAreaGuideKey;
static id UICNativeSafeAreaLayoutGuide(id self, SEL _cmd) {
    id guide = objc_getAssociatedObject(self, UICSafeAreaGuideKey);
    if (guide) return guide;
    Class guideClass = objc_getClass("UILayoutGuide");
    guide = [[guideClass alloc] init];
    ((void (*)(id, SEL, id))objc_msgSend)(self, sel_registerName("addLayoutGuide:"), guide);
    id (*anchor)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    void (*pin)(id, SEL, BOOL) = (void (*)(id, SEL, BOOL))objc_msgSend;
    const char *names[] = {"topAnchor", "bottomAnchor", "leadingAnchor", "trailingAnchor"};
    for (int i = 0; i < 4; i++) {
        id mine = anchor(guide, sel_registerName(names[i]));
        id theirs = anchor(self, sel_registerName(names[i]));
        id constraint = ((id (*)(id, SEL, id))objc_msgSend)(mine, sel_registerName("constraintEqualToAnchor:"), theirs);
        pin(constraint, sel_registerName("setActive:"), YES);
    }
    objc_setAssociatedObject(self, UICSafeAreaGuideKey, guide, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return guide;
}
static void UICInstallNativeSafeAreaGuide(void) {
    Class view = objc_getClass("UIView");
    if (!objc_getClass("UILayoutGuide") || !view) return;           // below iOS 9: Swift overlay provides it
    SEL selector = sel_registerName("safeAreaLayoutGuide");
    if (class_getInstanceMethod(view, selector)) return;            // iOS 11+: Apple's own
    class_addMethod(view, selector, (IMP)UICNativeSafeAreaLayoutGuide, "@@:");
}

// Semantic backgrounds are light-appearance colors on systems without dynamic
// appearance. Install only missing class selectors so modern UIKit stays native.
static id UICSystemBackground(id self, SEL cmd) { return [UIColor whiteColor]; }
static id UICSecondarySystemBackground(id self, SEL cmd) {
    return [UIColor colorWithRed:242.0/255.0 green:242.0/255.0 blue:247.0/255.0 alpha:1.0];
}
static void UICInstallSemanticBackgroundColors(void) {
    Class meta = object_getClass(objc_getClass("UIColor"));
    const char *white[] = {"systemBackgroundColor", "tertiarySystemBackgroundColor",
        "secondarySystemGroupedBackgroundColor"};
    const char *gray[] = {"secondarySystemBackgroundColor", "systemGroupedBackgroundColor",
        "tertiarySystemGroupedBackgroundColor"};
    for (unsigned i = 0; i < sizeof(white)/sizeof(white[0]); ++i) {
        SEL sel = sel_registerName(white[i]);
        if (!class_getInstanceMethod(meta, sel)) class_addMethod(meta, sel, (IMP)UICSystemBackground, "@@:");
    }
    for (unsigned i = 0; i < sizeof(gray)/sizeof(gray[0]); ++i) {
        SEL sel = sel_registerName(gray[i]);
        if (!class_getInstanceMethod(meta, sel)) class_addMethod(meta, sel, (IMP)UICSecondarySystemBackground, "@@:");
    }
}

__attribute__((constructor)) static void UICInstallBackportMethods(void) {
    @autoreleasepool {
        // Constructor work is limited to Objective-C runtime registration: no
        // Foundation objects, no Swift calls, no message sends to UIKit.
        if (!objc_getClass("UILayoutGuide") || !objc_getClass("NSLayoutAnchor"))
            UICInstallMissingMethods([UIView class], [UICViewAdditions class]);
        UICInstallMissingMethods([UIScrollView class], [UICScrollAdditions class]);
        UICInstallMissingMethods([NSString class], [UICStringDrawingAdditions class]);
        UICInstallFullScreenLayoutDefault();
        UICInstallAutoAdjustDefault();
        UICInstallNativeSafeAreaGuide();
        UICInstallSemanticBackgroundColors();
        UICInstallConstraintItemUnwrapping();
    }
}
