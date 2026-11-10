//
//  UICSceneLifecycle.m
//  UIKitBackports runtime
//
//  The UIScene lifecycle (iOS 13) for the legacy runtime: UIScene, UIWindowScene,
//  UISceneSession, UISceneConfiguration, UISceneConnectionOptions, UIOpenURLContext,
//  UISceneOpenURLOptions, UISceneActivationConditions and the supporting option
//  classes, plus the launch / foreground / background / URL / user-activity driver
//  that UIKit itself provides from iOS 13.
//
//  Shape of the implementation
//  ---------------------------
//  * Behaviour was modelled on Apple's real UIKit, observed through the iOS 27
//    simulator (class shapes, defaults, descriptions, delegate ordering and
//    notification ordering). Where the legacy OS cannot reproduce something the
//    difference is listed in SCENE-LIFECYCLE.md rather than hidden.
//  * Each class is written once as an ivar-free "template" and cloned under
//    Apple's real name ONLY when the running UIKit lacks that class. On iOS 13+
//    nothing is registered and nothing is driven: Apple's classes are used.
//  * State lives in an associated dictionary, so the clones carry no ivars and
//    cannot disagree with a template about object layout.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Exported constants (values identical to UIKit's)

NSString *const SwiftLegacyUISceneWillConnectNotification = @"UISceneWillConnectNotification";
NSString *const SwiftLegacyUISceneDidDisconnectNotification = @"UISceneDidDisconnectNotification";
NSString *const SwiftLegacyUISceneDidActivateNotification = @"UISceneDidActivateNotification";
NSString *const SwiftLegacyUISceneWillDeactivateNotification = @"UISceneWillDeactivateNotification";
NSString *const SwiftLegacyUISceneWillEnterForegroundNotification = @"UISceneWillEnterForegroundNotification";
NSString *const SwiftLegacyUISceneDidEnterBackgroundNotification = @"UISceneDidEnterBackgroundNotification";
NSString *const SwiftLegacyUIWindowSceneSessionRoleApplication = @"UIWindowSceneSessionRoleApplication";
NSString *const SwiftLegacyUIWindowSceneSessionRoleExternalDisplay = @"UIWindowSceneSessionRoleExternalDisplay";
NSString *const SwiftLegacyUISceneErrorDomain = @"UISceneErrorDomain";

#pragma mark - Shared helpers

static const void *UICStateKey = &UICStateKey;

static NSMutableDictionary *UICS(id object) {
    NSMutableDictionary *state = objc_getAssociatedObject(object, UICStateKey);
    if (!state) {
        state = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(object, UICStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}
static id UICGet(id object, NSString *key) { return [UICS(object) objectForKey:key]; }
static void UICSet(id object, NSString *key, id value) {
    if (value) [UICS(object) setObject:value forKey:key]; else [UICS(object) removeObjectForKey:key];
}
static id UICUnretained(id object, NSString *key) {
    return [(NSValue *)UICGet(object, key) nonretainedObjectValue];
}
static void UICSetUnretained(id object, NSString *key, id value) {
    UICSet(object, key, value ? [NSValue valueWithNonretainedObject:value] : nil);
}
static NSString *UICNewUUIDString(void) {
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    NSString *string = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, uuid);
    CFRelease(uuid);
    return string;
}
static Class UICClass(NSString *name) { return NSClassFromString(name); }
static BOOL UICResponds(id object, SEL selector) { return object && [object respondsToSelector:selector]; }

typedef NS_ENUM(NSInteger, UICActivationState) {
    UICActivationUnattached = -1, UICActivationForegroundActive = 0,
    UICActivationForegroundInactive = 1, UICActivationBackground = 2,
};
static NSString *UICStateName(NSInteger state) {
    switch (state) {
        case UICActivationForegroundActive: return @"UISceneActivationStateForegroundActive";
        case UICActivationForegroundInactive: return @"UISceneActivationStateForegroundInactive";
        case UICActivationBackground: return @"UISceneActivationStateBackground";
        default: return @"UISceneActivationStateUnattached";
    }
}

#pragma mark - UISceneConfiguration

@interface UICSceneConfigurationT : NSObject <NSCopying, NSSecureCoding>
@property(nonatomic, readonly) NSString *name;
@property(nonatomic, readonly) NSString *role;
@property(nonatomic) Class sceneClass;
@property(nonatomic) Class delegateClass;
@property(nonatomic, strong) id storyboard;
@end
@implementation UICSceneConfigurationT
@dynamic name, role, sceneClass, delegateClass, storyboard;
+ (instancetype)configurationWithName:(NSString *)name sessionRole:(NSString *)role {
    return [[self alloc] initWithName:name sessionRole:role];
}
- (instancetype)init { return [self initWithName:nil sessionRole:SwiftLegacyUIWindowSceneSessionRoleApplication]; }
- (instancetype)initWithName:(NSString *)name { return [self initWithName:name sessionRole:SwiftLegacyUIWindowSceneSessionRoleApplication]; }
- (instancetype)initWithName:(NSString *)name sessionRole:(NSString *)role {
    if ((self = [super init])) { UICSet(self, @"name", [name copy]); UICSet(self, @"role", [role copy]); }
    return self;
}
- (NSString *)name { return UICGet(self, @"name"); }
- (NSString *)role { return UICGet(self, @"role"); }
- (Class)sceneClass { return UICGet(self, @"sceneClass"); }
- (void)setSceneClass:(Class)value { UICSet(self, @"sceneClass", (id)value); }
- (Class)delegateClass { return UICGet(self, @"delegateClass"); }
- (void)setDelegateClass:(Class)value { UICSet(self, @"delegateClass", (id)value); }
- (id)storyboard { return UICGet(self, @"storyboard"); }
- (void)setStoryboard:(id)value { UICSet(self, @"storyboard", value); }
- (id)copyWithZone:(NSZone *)zone {
    id copy = [[[self class] allocWithZone:zone] initWithName:self.name sessionRole:self.role];
    [copy setSceneClass:self.sceneClass]; [copy setDelegateClass:self.delegateClass]; [copy setStoryboard:self.storyboard];
    return copy;
}
- (BOOL)isEqual:(id)other {
    if (other == self) return YES;
    if (![other isKindOfClass:[self class]]) return NO;
    NSString *a = self.name, *b = [other name];
    return (a == b || [a isEqual:b]) && [self.role isEqual:UICGet(other, @"role")];
}
- (NSUInteger)hash { return [self.name hash] ^ [self.role hash]; }
- (NSString *)description {
    // Apple prints a missing name as a null pointer ("name: 0x0"); reproduced.
    NSString *name = self.name ? [NSString stringWithFormat:@"\"%@\"", self.name] : @"0x0";
    return [NSString stringWithFormat:@"<%@: %p; name: %@>", NSStringFromClass([self class]), self, name];
}
- (NSString *)debugDescription { return [self description]; }
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.name forKey:@"UISceneConfigurationName"];
    [coder encodeObject:self.role forKey:@"UISceneConfigurationRole"];
    if (self.sceneClass) [coder encodeObject:NSStringFromClass(self.sceneClass) forKey:@"UISceneClassName"];
    if (self.delegateClass) [coder encodeObject:NSStringFromClass(self.delegateClass) forKey:@"UISceneDelegateClassName"];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [self initWithName:[coder decodeObjectOfClass:[NSString class] forKey:@"UISceneConfigurationName"]
                  sessionRole:[coder decodeObjectOfClass:[NSString class] forKey:@"UISceneConfigurationRole"]];
    NSString *sceneName = [coder decodeObjectOfClass:[NSString class] forKey:@"UISceneClassName"];
    NSString *delegateName = [coder decodeObjectOfClass:[NSString class] forKey:@"UISceneDelegateClassName"];
    if (sceneName) self.sceneClass = NSClassFromString(sceneName);
    if (delegateName) self.delegateClass = NSClassFromString(delegateName);
    return self;
}
@end

#pragma mark - UISceneActivationConditions

@interface UICSceneActivationConditionsT : NSObject <NSCopying, NSSecureCoding>
@property(nonatomic, copy) NSPredicate *canActivateForTargetContentIdentifierPredicate;
@property(nonatomic, copy) NSPredicate *prefersToActivateForTargetContentIdentifierPredicate;
@end
@implementation UICSceneActivationConditionsT
@dynamic canActivateForTargetContentIdentifierPredicate, prefersToActivateForTargetContentIdentifierPredicate;
- (instancetype)init {
    if ((self = [super init])) {
        UICSet(self, @"can", [NSPredicate predicateWithValue:YES]);
        UICSet(self, @"prefers", [NSPredicate predicateWithValue:NO]);
    }
    return self;
}
- (NSPredicate *)canActivateForTargetContentIdentifierPredicate { return UICGet(self, @"can"); }
- (void)setCanActivateForTargetContentIdentifierPredicate:(NSPredicate *)p { UICSet(self, @"can", [p copy]); }
- (NSPredicate *)prefersToActivateForTargetContentIdentifierPredicate { return UICGet(self, @"prefers"); }
- (void)setPrefersToActivateForTargetContentIdentifierPredicate:(NSPredicate *)p { UICSet(self, @"prefers", [p copy]); }
- (id)copyWithZone:(NSZone *)zone {
    id copy = [[[self class] allocWithZone:zone] init];
    [copy setCanActivateForTargetContentIdentifierPredicate:self.canActivateForTargetContentIdentifierPredicate];
    [copy setPrefersToActivateForTargetContentIdentifierPredicate:self.prefersToActivateForTargetContentIdentifierPredicate];
    return copy;
}
- (BOOL)isEqual:(id)other {
    if (other == self) return YES;
    if (![other isKindOfClass:[self class]]) return NO;
    return [self.canActivateForTargetContentIdentifierPredicate isEqual:[other canActivateForTargetContentIdentifierPredicate]] &&
           [self.prefersToActivateForTargetContentIdentifierPredicate isEqual:[other prefersToActivateForTargetContentIdentifierPredicate]];
}
- (NSUInteger)hash { return [self.canActivateForTargetContentIdentifierPredicate hash] ^ [self.prefersToActivateForTargetContentIdentifierPredicate hash]; }
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p can=%@, prefers=%@>", NSStringFromClass([self class]), self,
            self.canActivateForTargetContentIdentifierPredicate, self.prefersToActivateForTargetContentIdentifierPredicate];
}
+ (BOOL)supportsSecureCoding { return YES; }
+ (BOOL)accessInstanceVariablesDirectly { return NO; }
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.canActivateForTargetContentIdentifierPredicate forKey:@"canActivate"];
    [coder encodeObject:self.prefersToActivateForTargetContentIdentifierPredicate forKey:@"prefers"];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [self init])) {
        NSPredicate *can = [coder decodeObjectOfClass:[NSPredicate class] forKey:@"canActivate"];
        NSPredicate *prefers = [coder decodeObjectOfClass:[NSPredicate class] forKey:@"prefers"];
        if (can) self.canActivateForTargetContentIdentifierPredicate = can;
        if (prefers) self.prefersToActivateForTargetContentIdentifierPredicate = prefers;
    }
    return self;
}
@end

#pragma mark - UISceneSession

@interface UICSceneSessionT : NSObject <NSSecureCoding>
@property(nonatomic, readonly) id scene;
@property(nonatomic, readonly) NSString *role;
@property(nonatomic, readonly, copy) id configuration;
@property(nonatomic, readonly) NSString *persistentIdentifier;
@property(nonatomic, strong) NSUserActivity *stateRestorationActivity;
@property(nonatomic, copy) NSDictionary *userInfo;
@end
@implementation UICSceneSessionT
@dynamic scene, role, configuration, persistentIdentifier, stateRestorationActivity, userInfo;
- (instancetype)_initWithUICRole:(NSString *)role configuration:(id)configuration identifier:(NSString *)identifier {
    if ((self = [super init])) {
        UICSet(self, @"role", [role copy]);
        UICSet(self, @"configuration", configuration);
        UICSet(self, @"identifier", identifier ?: UICNewUUIDString());
    }
    return self;
}
- (id)scene { return UICUnretained(self, @"scene"); }
- (void)_uic_setScene:(id)scene { UICSetUnretained(self, @"scene", scene); }
- (void)_uic_setConfiguration:(id)configuration { UICSet(self, @"configuration", configuration); }
- (NSString *)role { return UICGet(self, @"role"); }
- (id)configuration { return [UICGet(self, @"configuration") copy]; }
- (NSString *)persistentIdentifier { return UICGet(self, @"identifier"); }
- (NSUserActivity *)stateRestorationActivity { return UICGet(self, @"activity"); }
- (void)setStateRestorationActivity:(NSUserActivity *)value { UICSet(self, @"activity", value); }
- (NSDictionary *)userInfo { return UICGet(self, @"userInfo") ?: [NSDictionary dictionary]; }
- (void)setUserInfo:(NSDictionary *)value { UICSet(self, @"userInfo", [value copy]); }
- (NSUInteger)hash { return [self.persistentIdentifier hash]; }
- (BOOL)isEqual:(id)other {
    return other == self || ([other isKindOfClass:[self class]] && [self.persistentIdentifier isEqual:[other persistentIdentifier]]);
}
- (NSString *)description {
    id scene = self.scene;
    return [NSString stringWithFormat:@"<%@: %p; role: %@; persistentIdentifier: %@; scene: %@; configuration: <%@: %p>; userInfo: %@>",
            NSStringFromClass([self class]), self, self.role, self.persistentIdentifier,
            scene ? [NSString stringWithFormat:@"<%@: %p>", NSStringFromClass([scene class]), scene] : @"(nil)",
            NSStringFromClass([UICGet(self, @"configuration") class]), UICGet(self, @"configuration"), self.userInfo];
}
- (NSString *)debugDescription { return [self description]; }
+ (BOOL)supportsSecureCoding { return YES; }
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.role forKey:@"role"];
    [coder encodeObject:self.persistentIdentifier forKey:@"persistentIdentifier"];
    [coder encodeObject:UICGet(self, @"configuration") forKey:@"configuration"];
    if (UICGet(self, @"userInfo")) [coder encodeObject:UICGet(self, @"userInfo") forKey:@"userInfo"];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    return [self _initWithUICRole:[coder decodeObjectOfClass:[NSString class] forKey:@"role"]
                     configuration:[coder decodeObjectOfClass:UICClass(@"UISceneConfiguration") forKey:@"configuration"]
                        identifier:[coder decodeObjectOfClass:[NSString class] forKey:@"persistentIdentifier"]];
}
@end

#pragma mark - UISceneOpenURLOptions / UIOpenURLContext

@interface UICSceneOpenURLOptionsT : NSObject
@property(nonatomic, readonly) NSString *sourceApplication;
@property(nonatomic, readonly) id annotation;
@property(nonatomic, readonly) BOOL openInPlace;
@property(nonatomic, readonly) id eventAttribution;
@end
@implementation UICSceneOpenURLOptionsT
@dynamic sourceApplication, annotation, openInPlace, eventAttribution;
- (instancetype)_initWithUICSource:(NSString *)source annotation:(id)annotation openInPlace:(BOOL)inPlace {
    if ((self = [super init])) {
        UICSet(self, @"source", source); UICSet(self, @"annotation", annotation);
        UICSet(self, @"inPlace", @(inPlace));
    }
    return self;
}
- (NSString *)sourceApplication { return UICGet(self, @"source"); }
- (id)annotation { return UICGet(self, @"annotation"); }
- (BOOL)openInPlace { return [UICGet(self, @"inPlace") boolValue]; }
- (id)eventAttribution { return nil; }
- (NSUInteger)hash { return [self.sourceApplication hash] ^ (NSUInteger)self.openInPlace; }
- (BOOL)isEqual:(id)other {
    if (other == self) return YES;
    if (![other isKindOfClass:[self class]]) return NO;
    NSString *a = self.sourceApplication, *b = [other sourceApplication];
    id x = self.annotation, y = [other annotation];
    return (a == b || [a isEqual:b]) && (x == y || [x isEqual:y]) && self.openInPlace == [other openInPlace];
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p; sourceApplication: %@; annotation: %@; openInPlace: %@>",
            NSStringFromClass([self class]), self, self.sourceApplication, self.annotation, self.openInPlace ? @"YES" : @"NO"];
}
@end

@interface UICOpenURLContextT : NSObject
@property(nonatomic, readonly, copy) NSURL *URL;
@property(nonatomic, readonly) id options;
@end
@implementation UICOpenURLContextT
@dynamic URL, options;
- (instancetype)initWithURL:(NSURL *)url options:(id)options {
    if ((self = [super init])) { UICSet(self, @"URL", [url copy]); UICSet(self, @"options", options); }
    return self;
}
- (NSURL *)URL { return UICGet(self, @"URL"); }
- (id)options { return UICGet(self, @"options"); }
- (NSDictionary *)optionsDictionary {
    id options = self.options; NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if ([options sourceApplication]) [d setObject:[options sourceApplication] forKey:@"UIApplicationOpenURLOptionsSourceApplicationKey"];
    if ([options annotation]) [d setObject:[options annotation] forKey:@"UIApplicationOpenURLOptionsAnnotationKey"];
    [d setObject:@([options openInPlace]) forKey:@"UIApplicationOpenURLOptionsOpenInPlaceKey"];
    return d;
}
- (NSUInteger)hash { return [self.URL hash] ^ [self.options hash]; }
- (BOOL)isEqual:(id)other {
    if (other == self) return YES;
    if (![other isKindOfClass:[self class]]) return NO;
    return [self.URL isEqual:[other URL]] && [self.options isEqual:UICGet(other, @"options")];
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p; URL: %@; options: %@>", NSStringFromClass([self class]), self, self.URL, self.options];
}
@end

#pragma mark - UISceneConnectionOptions

@interface UICSceneConnectionOptionsT : NSObject
@property(nonatomic, readonly, copy) NSSet *URLContexts;
@property(nonatomic, readonly) NSString *sourceApplication;
@property(nonatomic, readonly) NSString *handoffUserActivityType;
@property(nonatomic, readonly, copy) NSSet *userActivities;
@property(nonatomic, readonly) id notificationResponse;
@property(nonatomic, readonly) id shortcutItem;
@property(nonatomic, readonly) id cloudKitShareMetadata;
@property(nonatomic, readonly) id sceneAccessoryUserInfo;
@end
@implementation UICSceneConnectionOptionsT
@dynamic URLContexts, sourceApplication, handoffUserActivityType, userActivities, notificationResponse, shortcutItem, cloudKitShareMetadata, sceneAccessoryUserInfo;
- (void)_uic_setValue:(id)value forKey:(NSString *)key { UICSet(self, key, value); }
- (NSSet *)URLContexts { return UICGet(self, @"URLContexts") ?: [NSSet set]; }
- (NSString *)sourceApplication { return UICGet(self, @"sourceApplication"); }
- (NSString *)handoffUserActivityType { return UICGet(self, @"handoff"); }
- (NSSet *)userActivities { return UICGet(self, @"userActivities") ?: [NSSet set]; }
- (id)notificationResponse { return UICGet(self, @"notificationResponse"); }
- (id)shortcutItem { return UICGet(self, @"shortcutItem"); }
- (id)cloudKitShareMetadata { return nil; }
- (id)sceneAccessoryUserInfo { return nil; }
- (NSString *)description {
    // Apple's description is that of an (empty) settings dictionary.
    return @"{\n}";
}
@end

#pragma mark - Small option classes

@interface UICSceneSizeRestrictionsT : NSObject
@property(nonatomic) CGSize minimumSize;
@property(nonatomic) CGSize maximumSize;
@property(nonatomic) BOOL allowsFullScreen;
@end
@implementation UICSceneSizeRestrictionsT
@dynamic minimumSize, maximumSize, allowsFullScreen;
- (CGSize)minimumSize { NSValue *v = UICGet(self, @"min"); return v ? [v CGSizeValue] : CGSizeZero; }
- (void)setMinimumSize:(CGSize)size { UICSet(self, @"min", [NSValue valueWithCGSize:size]); }
- (CGSize)maximumSize { NSValue *v = UICGet(self, @"max"); return v ? [v CGSizeValue] : CGSizeZero; }
- (void)setMaximumSize:(CGSize)size { UICSet(self, @"max", [NSValue valueWithCGSize:size]); }
- (BOOL)allowsFullScreen { return [UICGet(self, @"full") boolValue]; }
- (void)setAllowsFullScreen:(BOOL)value { UICSet(self, @"full", @(value)); }
@end

@interface UICSceneDestructionRequestOptionsT : NSObject @end
@implementation UICSceneDestructionRequestOptionsT @end

@interface UICWindowSceneDestructionRequestOptionsT : UICSceneDestructionRequestOptionsT
@property(nonatomic) NSInteger windowDismissalAnimation;
@end
@implementation UICWindowSceneDestructionRequestOptionsT
@dynamic windowDismissalAnimation;
- (NSInteger)windowDismissalAnimation { return [UICGet(self, @"animation") integerValue]; }
- (void)setWindowDismissalAnimation:(NSInteger)value { UICSet(self, @"animation", @(value)); }
@end

@interface UICSceneActivationRequestOptionsT : NSObject <NSCopying>
@property(nonatomic, strong) id requestingScene;
@property(nonatomic) BOOL preserveLayout;
@property(nonatomic) NSInteger collectionJoinBehavior;
@end
@implementation UICSceneActivationRequestOptionsT
@dynamic requestingScene, preserveLayout, collectionJoinBehavior;
- (id)requestingScene { return UICGet(self, @"scene"); }
- (void)setRequestingScene:(id)value { UICSet(self, @"scene", value); }
- (BOOL)preserveLayout { return [UICGet(self, @"layout") boolValue]; }
- (void)setPreserveLayout:(BOOL)value { UICSet(self, @"layout", @(value)); }
- (NSInteger)collectionJoinBehavior { return [UICGet(self, @"join") integerValue]; }
- (void)setCollectionJoinBehavior:(NSInteger)value { UICSet(self, @"join", @(value)); }
- (id)copyWithZone:(NSZone *)zone {
    id copy = [[[self class] allocWithZone:zone] init];
    [UICS(copy) setDictionary:UICS(self)];
    return copy;
}
@end

@interface UICWindowSceneActivationRequestOptionsT : UICSceneActivationRequestOptionsT
@property(nonatomic) NSUInteger preferredPresentationStyle;
@property(nonatomic, copy) id placement;
@end
@implementation UICWindowSceneActivationRequestOptionsT
@dynamic preferredPresentationStyle, placement;
- (NSUInteger)preferredPresentationStyle { return [UICGet(self, @"style") unsignedIntegerValue]; }
- (void)setPreferredPresentationStyle:(NSUInteger)value { UICSet(self, @"style", @(value)); }
- (id)placement { return UICGet(self, @"placement"); }
- (void)setPlacement:(id)value { UICSet(self, @"placement", [value copy]); }
@end

@interface UICWindowSceneActivationConfigurationT : NSObject <NSCopying>
@property(nonatomic, readonly) NSUserActivity *userActivity;
@property(nonatomic, strong) id options;
@property(nonatomic, strong) id preview;
@end
@implementation UICWindowSceneActivationConfigurationT
@dynamic userActivity, options, preview;
- (instancetype)initWithUserActivity:(NSUserActivity *)activity {
    if ((self = [super init])) UICSet(self, @"activity", activity);
    return self;
}
- (NSUserActivity *)userActivity { return UICGet(self, @"activity"); }
- (id)options { return UICGet(self, @"options"); }
- (void)setOptions:(id)value { UICSet(self, @"options", value); }
- (id)preview { return UICGet(self, @"preview"); }
- (void)setPreview:(id)value { UICSet(self, @"preview", value); }
- (id)copyWithZone:(NSZone *)zone {
    id copy = [[[self class] allocWithZone:zone] initWithUserActivity:self.userActivity];
    [copy setOptions:self.options]; [copy setPreview:self.preview];
    return copy;
}
@end

#pragma mark - Window scene coordinate space

@interface UICWindowSceneCoordinateSpaceT : NSObject
- (CGRect)bounds;
- (CGPoint)convertPoint:(CGPoint)point toCoordinateSpace:(id)space;
- (CGPoint)convertPoint:(CGPoint)point fromCoordinateSpace:(id)space;
- (CGRect)convertRect:(CGRect)rect toCoordinateSpace:(id)space;
- (CGRect)convertRect:(CGRect)rect fromCoordinateSpace:(id)space;
@end
@implementation UICWindowSceneCoordinateSpaceT
- (CGRect)bounds { return [[UIScreen mainScreen] bounds]; }
// The scene space is the screen's: points are already screen coordinates. A UIView
// target is reached through its own conversion with the screen as the source.
- (CGPoint)convertPoint:(CGPoint)point toCoordinateSpace:(id)space {
    if ([space isKindOfClass:[UIView class]]) return [(UIView *)space convertPoint:point fromView:nil];
    return point;
}
- (CGPoint)convertPoint:(CGPoint)point fromCoordinateSpace:(id)space {
    if ([space isKindOfClass:[UIView class]]) return [(UIView *)space convertPoint:point toView:nil];
    return point;
}
- (CGRect)convertRect:(CGRect)rect toCoordinateSpace:(id)space {
    if ([space isKindOfClass:[UIView class]]) return [(UIView *)space convertRect:rect fromView:nil];
    return rect;
}
- (CGRect)convertRect:(CGRect)rect fromCoordinateSpace:(id)space {
    if ([space isKindOfClass:[UIView class]]) return [(UIView *)space convertRect:rect toView:nil];
    return rect;
}
@end

#pragma mark - UIStatusBarManager

@interface UICStatusBarManagerT : NSObject
@property(nonatomic, strong) id windowScene;
@end
@implementation UICStatusBarManagerT
@dynamic windowScene;
- (instancetype)initWithScene:(id)scene { if ((self = [super init])) UICSetUnretained(self, @"scene", scene); return self; }
- (id)windowScene { return UICUnretained(self, @"scene"); }
- (void)setWindowScene:(id)scene { UICSetUnretained(self, @"scene", scene); }
- (BOOL)isStatusBarHidden { return [UIApplication sharedApplication].statusBarHidden; }
- (UIStatusBarStyle)statusBarStyle { return [UIApplication sharedApplication].statusBarStyle; }
- (CGRect)statusBarFrame { return [UIApplication sharedApplication].statusBarFrame; }
- (CGFloat)statusBarHeight { return CGRectGetHeight(self.statusBarFrame); }
- (CGFloat)defaultStatusBarHeight { return CGRectGetHeight([UIApplication sharedApplication].statusBarFrame); }
@end

#pragma mark - UIScene

static NSString *UICSceneDescription(id scene) {
    id session = [scene session];
    return [NSString stringWithFormat:@"<%@: %p; role: %@; persistentIdentifier: %@; activationState: %@>",
            NSStringFromClass([scene class]), scene, UICGet(session, @"role"), UICGet(session, @"identifier"),
            UICStateName((NSInteger)[scene activationState])];
}

@interface UICSceneT : UIResponder
@property(nonatomic, readonly) id session;
@property(nonatomic, strong) id delegate;
@property(nonatomic, readonly) NSInteger activationState;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *subtitle;
@property(nonatomic, strong) id activationConditions;
@end
@implementation UICSceneT
@dynamic session, delegate, activationState, title, subtitle, activationConditions;
- (instancetype)initWithSession:(id)session connectionOptions:(id)options {
    if ((self = [super init])) {
        UICSet(self, @"session", session);
        UICSet(self, @"state", @(UICActivationUnattached));
        UICSet(self, @"conditions", [[UICClass(@"UISceneActivationConditions") alloc] init]);
    }
    return self;
}
- (id)session { return UICGet(self, @"session"); }
- (id)delegate { return UICGet(self, @"delegate"); }
- (void)setDelegate:(id)delegate { UICSet(self, @"delegate", delegate); }
- (NSInteger)activationState { return [UICGet(self, @"state") integerValue]; }
- (void)_uic_setActivationState:(NSInteger)state { UICSet(self, @"state", @(state)); }
- (NSString *)title { return UICGet(self, @"title") ?: @""; }
- (void)setTitle:(NSString *)title { UICSet(self, @"title", [title copy]); }
- (NSString *)subtitle { return UICGet(self, @"subtitle"); }
- (void)setSubtitle:(NSString *)subtitle { UICSet(self, @"subtitle", [subtitle copy]); }
- (id)activationConditions { return UICGet(self, @"conditions"); }
- (void)setActivationConditions:(id)value { UICSet(self, @"conditions", value); }
- (UIResponder *)nextResponder { return [UIApplication sharedApplication]; }
- (void)openURL:(NSURL *)url options:(id)options completionHandler:(void (^)(BOOL))completion {
    BOOL ok = [[UIApplication sharedApplication] openURL:url];
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(ok); });
}
- (NSString *)description { return UICSceneDescription(self); }
- (NSString *)debugDescription { return UICSceneDescription(self); }
@end

#pragma mark - UIWindowScene

@interface UICWindowSceneT : UICSceneT
@property(nonatomic, readonly) UIScreen *screen;
@property(nonatomic, readonly) UIInterfaceOrientation interfaceOrientation;
@property(nonatomic, readonly) id coordinateSpace;
@property(nonatomic, readonly) id traitCollection;
@property(nonatomic, readonly) id sizeRestrictions;
@property(nonatomic, readonly) NSArray *windows;
@property(nonatomic, readonly) UIWindow *keyWindow;
@property(nonatomic, weak) id activityItemsConfigurationSource;
@end
@implementation UICWindowSceneT
@dynamic screen, interfaceOrientation, coordinateSpace, traitCollection, sizeRestrictions, windows, keyWindow, activityItemsConfigurationSource;
- (UIScreen *)screen { return [UIScreen mainScreen]; }
- (UIInterfaceOrientation)interfaceOrientation { return [UIApplication sharedApplication].statusBarOrientation; }
- (id)coordinateSpace {
    id space = UICGet(self, @"space");
    if (!space) {
        // iOS 8+ screens vend a native coordinate space; older systems use the
        // backport's equivalent (class name matches Apple's private one).
        Class native = UICClass(@"_UIWindowSceneCoordinateSpace");
        space = [[native alloc] init];
        UICSet(self, @"space", space);
    }
    return space;
}
- (id)traitCollection {
    Class traits = UICClass(@"UITraitCollection");   // iOS 8+; absent before
    return traits ? [(id)self.screen valueForKey:@"traitCollection"] : nil;
}
- (id)sizeRestrictions { return nil; }
- (NSArray *)windows {
    NSMutableArray *result = [NSMutableArray array];
    for (UIWindow *window in [UIApplication sharedApplication].windows)
        if (UICUnretained(window, @"windowScene") == self) [result addObject:window];
    return result;
}
- (UIWindow *)keyWindow {
    UIWindow *key = [UIApplication sharedApplication].keyWindow;
    return (key && UICUnretained(key, @"windowScene") == self) ? key : nil;
}
- (id)activityItemsConfigurationSource { return UICUnretained(self, @"aics"); }
- (void)setActivityItemsConfigurationSource:(id)value { UICSetUnretained(self, @"aics", value); }
- (id)statusBarManager {
    id manager = UICGet(self, @"statusBarManager");
    if (!manager) {
        manager = [[UICClass(@"UIStatusBarManager") alloc] initWithScene:self];
        UICSet(self, @"statusBarManager", manager);
    }
    return manager;
}
@end

#pragma mark - UIWindow additions

@interface UICWindowAdditions : NSObject @end
@implementation UICWindowAdditions
- (id)initWithWindowScene:(id)scene {
    UIWindow *window = [(UIWindow *)(id)self initWithFrame:[UIScreen mainScreen].bounds];
    if (window) UICSetUnretained(window, @"windowScene", scene);
    return (id)window;
}
- (id)windowScene { return UICUnretained(self, @"windowScene"); }
- (void)setWindowScene:(id)scene { UICSetUnretained(self, @"windowScene", scene); }
@end

static IMP UICOriginalWindowNextResponder;
static id UICWindowNextResponder(id self, SEL _cmd) {
    id scene = UICUnretained(self, @"windowScene");
    return scene ?: ((id (*)(id, SEL))UICOriginalWindowNextResponder)(self, _cmd);
}

#pragma mark - UIApplication additions

static BOOL UICSceneMode;                 // YES once a scene manifest has been connected
static id UICScene_;                      // the single connected scene
static NSDictionary *UICManifest;

@interface UICApplicationAdditions : NSObject @end
@implementation UICApplicationAdditions
- (NSSet *)connectedScenes { return UICScene_ ? [NSSet setWithObject:UICScene_] : [NSSet set]; }
- (NSSet *)openSessions { return UICScene_ ? [NSSet setWithObject:[UICScene_ session]] : [NSSet set]; }
- (BOOL)supportsMultipleScenes {
    return [[UICManifest objectForKey:@"UIApplicationSupportsMultipleScenes"] boolValue];
}
- (void)requestSceneSessionActivation:(id)session userActivity:(NSUserActivity *)activity options:(id)options
                         errorHandler:(void (^)(NSError *))errorHandler {
    if (!errorHandler) return;
    NSError *error = [NSError errorWithDomain:SwiftLegacyUISceneErrorDomain code:0
        userInfo:[NSDictionary dictionaryWithObject:@"The current device does not support multiple scenes." forKey:NSLocalizedDescriptionKey]];
    dispatch_async(dispatch_get_main_queue(), ^{ errorHandler(error); });
}
- (void)requestSceneSessionDestruction:(id)session options:(id)options errorHandler:(void (^)(NSError *))errorHandler {
    if (!errorHandler) return;
    NSError *error = [NSError errorWithDomain:SwiftLegacyUISceneErrorDomain code:0 userInfo:nil];
    dispatch_async(dispatch_get_main_queue(), ^{ errorHandler(error); });
}
- (void)requestSceneSessionRefresh:(id)session {}
@end

#pragma mark - Class registration (only when UIKit lacks the class)

static void UICCopyMethods(Class from, Class to) {
    unsigned count = 0;
    Method *methods = class_copyMethodList(from, &count);
    for (unsigned i = 0; i < count; i++)
        class_addMethod(to, method_getName(methods[i]), method_getImplementation(methods[i]), method_getTypeEncoding(methods[i]));
    free(methods);
}
static void UICCopyProtocols(Class from, Class to) {
    unsigned count = 0;
    Protocol *__unsafe_unretained *protocols = class_copyProtocolList(from, &count);
    for (unsigned i = 0; i < count; i++) class_addProtocol(to, protocols[i]);
    free(protocols);
}
static void UICCopyProperties(Class from, Class to) {
    unsigned count = 0;
    objc_property_t *properties = class_copyPropertyList(from, &count);
    for (unsigned i = 0; i < count; i++) {
        unsigned attributeCount = 0;
        objc_property_attribute_t *attributes = property_copyAttributeList(properties[i], &attributeCount);
        class_addProperty(to, property_getName(properties[i]), attributes, attributeCount);
        free(attributes);
    }
    free(properties);
}
/// Registers `name` as a clone of `templateClass` unless UIKit already has it.
static Class UICRegister(const char *name, Class superclass, Class templateClass) {
    Class existing = objc_getClass(name);
    if (existing) return existing;
    Class created = objc_allocateClassPair(superclass, name, 0);
    if (!created) return Nil;
    UICCopyMethods(templateClass, created);
    UICCopyMethods(object_getClass(templateClass), object_getClass(created));
    UICCopyProtocols(templateClass, created);
    UICCopyProperties(templateClass, created);
    objc_registerClassPair(created);
    return created;
}
static void UICAddMissingMethods(Class target, Class template) {
    unsigned count = 0;
    Method *methods = class_copyMethodList(template, &count);
    for (unsigned i = 0; i < count; i++)
        if (!class_getInstanceMethod(target, method_getName(methods[i])))
            class_addMethod(target, method_getName(methods[i]), method_getImplementation(methods[i]), method_getTypeEncoding(methods[i]));
    free(methods);
}

#pragma mark - Class lookup for Info.plist names

/// Info.plist names may be "Module.Class" for Swift classes, whose Objective-C
/// runtime name is the mangled "_TtC<n>Module<n>Class". Both spellings resolve.
static Class UICResolveClass(NSString *name) {
    if (!name.length) return Nil;
    Class direct = NSClassFromString(name);
    if (direct) return direct;
    NSArray *parts = [name componentsSeparatedByString:@"."];
    if (parts.count == 2) {
        NSString *mangled = [NSString stringWithFormat:@"_TtC%lu%@%lu%@", (unsigned long)[[parts objectAtIndex:0] length], [parts objectAtIndex:0],
                             (unsigned long)[[parts objectAtIndex:1] length], [parts objectAtIndex:1]];
        return NSClassFromString(mangled);
    }
    return Nil;
}

#pragma mark - Delegate dispatch

static void UICSend1(id target, SEL selector, id a) {
    if (UICResponds(target, selector)) ((void (*)(id, SEL, id))objc_msgSend)(target, selector, a);
}
static void UICPost(NSString *name, id scene) {
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:scene];
}
static id UICSceneDelegate(void) { return [UICScene_ delegate]; }

#pragma mark - Application delegate adaptation

static BOOL UICConnectPending;
static NSDictionary *UICPendingLaunch;
static void UICConnectScene(NSDictionary *launchOptions);
/// UIKit connects the scene before any activation callback. Our connect is queued behind the
/// launch notification's other observers, so an activation that arrives first connects it now.
static void UICEnsureConnected(void) {
    if (!UICConnectPending) return;
    UICConnectPending = NO;
    NSDictionary *launch = UICPendingLaunch; UICPendingLaunch = nil;
    UICConnectScene(launch);
}

typedef struct { SEL selector; IMP original; } UICWrapped;
static UICWrapped UICAppWrapped[8];
static NSUInteger UICAppWrappedCount;

static IMP UICOriginalFor(SEL selector) {
    for (NSUInteger i = 0; i < UICAppWrappedCount; i++) if (UICAppWrapped[i].selector == selector) return UICAppWrapped[i].original;
    return NULL;
}
// UIKit does not call the application-level lifecycle callbacks of an app that
// uses scenes; the scene delegate receives them instead. The wrappers keep the
// original implementation for non-scene operation.
static void UICAppLifecycle(id self, SEL _cmd, id application) {
    if (UICSceneMode) { UICEnsureConnected(); return; }
    IMP original = UICOriginalFor(_cmd);
    if (original) ((void (*)(id, SEL, id))original)(self, _cmd, application);
}
static void UICWrapLifecycle(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || UICAppWrappedCount >= 8) return;
    UICAppWrapped[UICAppWrappedCount++] = (UICWrapped){ selector, method_getImplementation(method) };
    class_replaceMethod(cls, selector, (IMP)UICAppLifecycle, method_getTypeEncoding(method));
}

static IMP UICOpenSource, UICOpenOptions, UICContinue, UICShortcut, UICWillContinue, UICDidFail, UICDidUpdate;

static id UICMakeURLContext(NSURL *url, NSString *source, id annotation, BOOL inPlace) {
    id options = [[UICClass(@"UISceneOpenURLOptions") alloc] _initWithUICSource:source annotation:annotation openInPlace:inPlace];
    return [[UICClass(@"UIOpenURLContext") alloc] initWithURL:url options:options];
}
static BOOL UICDeliverURL(NSURL *url, NSString *source, id annotation, BOOL inPlace) {
    id delegate = UICSceneDelegate();
    SEL selector = @selector(scene:openURLContexts:);
    if (!UICResponds(delegate, selector)) return NO;
    NSSet *contexts = [NSSet setWithObject:UICMakeURLContext(url, source, annotation, inPlace)];
    ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, selector, UICScene_, contexts);
    return YES;
}
static BOOL UICAppOpenSource(id self, SEL _cmd, id app, NSURL *url, NSString *source, id annotation) {
    if (UICSceneMode) return UICDeliverURL(url, source, annotation, NO);
    return UICOpenSource ? ((BOOL (*)(id, SEL, id, id, id, id))UICOpenSource)(self, _cmd, app, url, source, annotation) : NO;
}
static BOOL UICAppOpenOptions(id self, SEL _cmd, id app, NSURL *url, NSDictionary *options) {
    if (UICSceneMode)
        return UICDeliverURL(url, [options objectForKey:@"UIApplicationOpenURLOptionsSourceApplicationKey"],
                             [options objectForKey:@"UIApplicationOpenURLOptionsAnnotationKey"],
                             [[options objectForKey:@"UIApplicationOpenURLOptionsOpenInPlaceKey"] boolValue]);
    return UICOpenOptions ? ((BOOL (*)(id, SEL, id, id, id))UICOpenOptions)(self, _cmd, app, url, options) : NO;
}
static BOOL UICAppContinue(id self, SEL _cmd, id app, NSUserActivity *activity, void (^handler)(NSArray *)) {
    if (UICSceneMode) {
        id delegate = UICSceneDelegate();
        if (!UICResponds(delegate, @selector(scene:continueUserActivity:))) return NO;
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, @selector(scene:continueUserActivity:), UICScene_, activity);
        return YES;
    }
    return UICContinue ? ((BOOL (*)(id, SEL, id, id, id))UICContinue)(self, _cmd, app, activity, handler) : NO;
}
static BOOL UICAppWillContinue(id self, SEL _cmd, id app, NSString *type) {
    if (UICSceneMode) {
        id delegate = UICSceneDelegate();
        if (!UICResponds(delegate, @selector(scene:willContinueUserActivityWithType:))) return NO;
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, @selector(scene:willContinueUserActivityWithType:), UICScene_, type);
        return YES;
    }
    return UICWillContinue ? ((BOOL (*)(id, SEL, id, id))UICWillContinue)(self, _cmd, app, type) : NO;
}
static void UICAppDidFail(id self, SEL _cmd, id app, NSString *type, NSError *error) {
    if (UICSceneMode) {
        id delegate = UICSceneDelegate();
        if (UICResponds(delegate, @selector(scene:didFailToContinueUserActivityWithType:error:)))
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, @selector(scene:didFailToContinueUserActivityWithType:error:), UICScene_, type, error);
    } else if (UICDidFail) ((void (*)(id, SEL, id, id, id))UICDidFail)(self, _cmd, app, type, error);
}
static void UICAppDidUpdate(id self, SEL _cmd, id app, NSUserActivity *activity) {
    if (UICSceneMode) {
        id delegate = UICSceneDelegate();
        if (UICResponds(delegate, @selector(scene:didUpdateUserActivity:)))
            ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, @selector(scene:didUpdateUserActivity:), UICScene_, activity);
    } else if (UICDidUpdate) ((void (*)(id, SEL, id, id))UICDidUpdate)(self, _cmd, app, activity);
}
static void UICAppShortcut(id self, SEL _cmd, id app, id item, void (^completion)(BOOL)) {
    if (UICSceneMode) {
        id delegate = UICSceneDelegate();
        SEL selector = @selector(windowScene:performActionForShortcutItem:completionHandler:);
        if (UICResponds(delegate, selector)) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, selector, UICScene_, item, completion);
            return;
        }
        if (completion) completion(NO);
        return;
    }
    if (UICShortcut) ((void (*)(id, SEL, id, id, id))UICShortcut)(self, _cmd, app, item, completion);
    else if (completion) completion(NO);
}
/// Replaces `selector` on the delegate's class (remembering the original), or adds it.
static void UICRoute(Class cls, SEL selector, IMP implementation, const char *types, IMP *original) {
    Method existing = class_getInstanceMethod(cls, selector);
    if (existing) {
        *original = method_getImplementation(existing);
        class_replaceMethod(cls, selector, implementation, method_getTypeEncoding(existing));
    } else {
        *original = NULL;
        class_addMethod(cls, selector, implementation, types);
    }
}
static NSMutableSet *UICAdaptedClasses;
static void UICAdaptApplicationDelegate(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    if (!UICAdaptedClasses) UICAdaptedClasses = [NSMutableSet set];
    NSString *key = NSStringFromClass(cls);
    if ([UICAdaptedClasses containsObject:key]) return;
    [UICAdaptedClasses addObject:key];
    UICWrapLifecycle(cls, @selector(applicationDidBecomeActive:));
    UICWrapLifecycle(cls, @selector(applicationWillResignActive:));
    UICWrapLifecycle(cls, @selector(applicationDidEnterBackground:));
    UICWrapLifecycle(cls, @selector(applicationWillEnterForeground:));
    UICRoute(cls, @selector(application:openURL:sourceApplication:annotation:), (IMP)UICAppOpenSource, "B@:@@@@", &UICOpenSource);
    UICRoute(cls, @selector(application:openURL:options:), (IMP)UICAppOpenOptions, "B@:@@@", &UICOpenOptions);
    UICRoute(cls, @selector(application:continueUserActivity:restorationHandler:), (IMP)UICAppContinue, "B@:@@@?", &UICContinue);
    UICRoute(cls, @selector(application:willContinueUserActivityWithType:), (IMP)UICAppWillContinue, "B@:@@", &UICWillContinue);
    UICRoute(cls, @selector(application:didFailToContinueUserActivityWithType:error:), (IMP)UICAppDidFail, "v@:@@@", &UICDidFail);
    UICRoute(cls, @selector(application:didUpdateUserActivity:), (IMP)UICAppDidUpdate, "v@:@@", &UICDidUpdate);
    UICRoute(cls, @selector(application:performActionForShortcutItem:completionHandler:), (IMP)UICAppShortcut, "v@:@@@?", &UICShortcut);
}

#pragma mark - Scene driver

static BOOL UICPostingForegroundNotification;
static UIInterfaceOrientation UICPreviousOrientation;

static NSDictionary *UICConfigurationDictionary(NSString *name) {
    NSArray *configs = [[UICManifest objectForKey:@"UISceneConfigurations"] objectForKey:SwiftLegacyUIWindowSceneSessionRoleApplication];
    for (NSDictionary *config in configs)
        if (!name || [[config objectForKey:@"UISceneConfigurationName"] isEqual:name]) return config;
    return configs.count ? [configs objectAtIndex:0] : nil;
}
static id UICMakeConfiguration(NSDictionary *plist, NSString *role) {
    id config = [[UICClass(@"UISceneConfiguration") alloc] initWithName:[plist objectForKey:@"UISceneConfigurationName"] sessionRole:role];
    if ([plist objectForKey:@"UISceneClassName"]) [config setSceneClass:UICResolveClass([plist objectForKey:@"UISceneClassName"])];
    if ([plist objectForKey:@"UISceneDelegateClassName"]) [config setDelegateClass:UICResolveClass([plist objectForKey:@"UISceneDelegateClassName"])];
    return config;
}
static id UICMakeConnectionOptions(NSDictionary *launch) {
    id options = [[UICClass(@"UISceneConnectionOptions") alloc] init];
    NSURL *url = [launch objectForKey:UIApplicationLaunchOptionsURLKey];
    NSString *source = [launch objectForKey:UIApplicationLaunchOptionsSourceApplicationKey];
    if (url) {
        [options _uic_setValue:[NSSet setWithObject:UICMakeURLContext(url, source, [launch objectForKey:UIApplicationLaunchOptionsAnnotationKey], NO)] forKey:@"URLContexts"];
        [options _uic_setValue:source forKey:@"sourceApplication"];
    }
    NSDictionary *activityInfo = [launch objectForKey:@"UIApplicationLaunchOptionsUserActivityDictionaryKey"];
    NSString *type = [activityInfo objectForKey:@"UIApplicationLaunchOptionsUserActivityTypeKey"];
    if (type) [options _uic_setValue:type forKey:@"handoff"];
    id shortcut = [launch objectForKey:@"UIApplicationLaunchOptionsShortcutItemKey"];
    if (shortcut) [options _uic_setValue:shortcut forKey:@"shortcutItem"];
    return options;
}

static void UICConnectScene(NSDictionary *launchOptions) {
    UIApplication *application = [UIApplication sharedApplication];
    id appDelegate = application.delegate;
    NSDictionary *defaultPlist = UICConfigurationDictionary(nil);
    NSString *role = SwiftLegacyUIWindowSceneSessionRoleApplication;
    id initial = UICMakeConfiguration(defaultPlist ?: [NSDictionary dictionary], role);
    id session = [[UICClass(@"UISceneSession") alloc] _initWithUICRole:role configuration:initial identifier:nil];
    id options = UICMakeConnectionOptions(launchOptions);

    id configuration = initial;
    SEL configure = @selector(application:configurationForConnectingSceneSession:options:);
    if (UICResponds(appDelegate, configure)) {
        id returned = ((id (*)(id, SEL, id, id, id))objc_msgSend)(appDelegate, configure, application, session, options);
        if (returned) configuration = returned;
    }
    // UIKit resolves a returned configuration against the manifest entry of the same name:
    // classes the app did not set explicitly come from Info.plist.
    {
        NSDictionary *entry = UICConfigurationDictionary([configuration name]);
        if (entry && [[entry objectForKey:@"UISceneConfigurationName"] isEqual:[configuration name]] ) {
            if (![configuration sceneClass] && [entry objectForKey:@"UISceneClassName"])
                [configuration setSceneClass:UICResolveClass([entry objectForKey:@"UISceneClassName"])];
            if (![configuration delegateClass] && [entry objectForKey:@"UISceneDelegateClassName"])
                [configuration setDelegateClass:UICResolveClass([entry objectForKey:@"UISceneDelegateClassName"])];
        }
    }
    [session _uic_setConfiguration:configuration];

    Class sceneClass = [configuration sceneClass] ?: UICClass(@"UIWindowScene");
    id scene = [[sceneClass alloc] initWithSession:session connectionOptions:options];
    UICScene_ = scene;
    UICSceneMode = YES;
    UICPreviousOrientation = application.statusBarOrientation;

    Class delegateClass = [configuration delegateClass];
    id delegate = delegateClass ? [[delegateClass alloc] init] : nil;
    if (delegate) [scene setDelegate:delegate];

    // A configuration storyboard (or the plist's UISceneStoryboardFile) is loaded the
    // way UIKit does: its initial controller becomes the root of a scene window that
    // is handed to the delegate's `window` property.
    NSString *storyboardName = [defaultPlist objectForKey:@"UISceneStoryboardFile"];
    if ([configuration name] && ![[configuration name] isEqual:[defaultPlist objectForKey:@"UISceneConfigurationName"]])
        storyboardName = [UICConfigurationDictionary([configuration name]) objectForKey:@"UISceneStoryboardFile"];
    if (storyboardName && UICResponds(delegate, @selector(setWindow:)) && [delegate respondsToSelector:@selector(window)]
        && ![delegate window]) {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:storyboardName bundle:nil];
        UIViewController *root = [storyboard instantiateInitialViewController];
        UIWindow *window = ((id (*)(id, SEL, id))objc_msgSend)([UIWindow alloc], sel_registerName("initWithWindowScene:"), scene);
        window.rootViewController = root;
        [delegate setWindow:window];
        [window makeKeyAndVisible];
    }

    if (UICResponds(delegate, @selector(scene:willConnectToSession:options:)))
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, @selector(scene:willConnectToSession:options:), scene, session, options);
    [session _uic_setScene:scene];
    UICPost(SwiftLegacyUISceneWillConnectNotification, scene);

    // A cold launch enters the foreground inactive, then activates.
    UICSend1(delegate, @selector(sceneWillEnterForeground:), scene);
    [scene _uic_setActivationState:UICActivationForegroundInactive];
    UICPost(SwiftLegacyUISceneWillEnterForegroundNotification, scene);
    UICPostingForegroundNotification = YES;
    [[NSNotificationCenter defaultCenter] postNotificationName:UIApplicationWillEnterForegroundNotification object:application];
    UICPostingForegroundNotification = NO;
    if (application.applicationState == UIApplicationStateActive) {
        [scene _uic_setActivationState:UICActivationForegroundActive];
        UICSend1(delegate, @selector(sceneDidBecomeActive:), scene);
        UICPost(SwiftLegacyUISceneDidActivateNotification, scene);
    }
}

static void UICDidFinishLaunching(NSNotification *note) {
    if (UICSceneMode) return;
    UICManifest = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIApplicationSceneManifest"];
    if (![UICManifest isKindOfClass:[NSDictionary class]] || !UICConfigurationDictionary(nil)) { UICManifest = nil; return; }
    UICAdaptApplicationDelegate([UIApplication sharedApplication].delegate);   // no-op when already adapted
    // UIKit connects after the launch notification has been delivered to every observer.
    UICSceneMode = YES;               // from here the application-level callbacks belong to the scene
    UICConnectPending = YES;
    UICPendingLaunch = [note.userInfo copy];
    dispatch_async(dispatch_get_main_queue(), ^{ UICEnsureConnected(); });
}
static void UICDidBecomeActive(NSNotification *note) {
    UICEnsureConnected();
    if (!UICSceneMode || !UICScene_ || (NSInteger)[UICScene_ activationState] == (NSInteger)UICActivationForegroundActive) return;
    [UICScene_ _uic_setActivationState:UICActivationForegroundActive];
    UICSend1(UICSceneDelegate(), @selector(sceneDidBecomeActive:), UICScene_);
    UICPost(SwiftLegacyUISceneDidActivateNotification, UICScene_);
}
static void UICWillResignActive(NSNotification *note) {
    UICEnsureConnected();
    if (!UICSceneMode || !UICScene_) return;
    UICSend1(UICSceneDelegate(), @selector(sceneWillResignActive:), UICScene_);
    [UICScene_ _uic_setActivationState:UICActivationForegroundInactive];
    UICPost(SwiftLegacyUISceneWillDeactivateNotification, UICScene_);
}
static void UICDidEnterBackground(NSNotification *note) {
    if (!UICSceneMode || !UICScene_) return;
    [UICScene_ _uic_setActivationState:UICActivationBackground];
    id delegate = UICSceneDelegate();
    UICSend1(delegate, @selector(sceneDidEnterBackground:), UICScene_);
    if (UICResponds(delegate, @selector(stateRestorationActivityForScene:))) {
        NSUserActivity *activity = ((id (*)(id, SEL, id))objc_msgSend)(delegate, @selector(stateRestorationActivityForScene:), UICScene_);
        [[UICScene_ session] setStateRestorationActivity:activity];
    }
    UICPost(SwiftLegacyUISceneDidEnterBackgroundNotification, UICScene_);
}
static void UICWillEnterForeground(NSNotification *note) {
    if (!UICSceneMode || !UICScene_ || UICPostingForegroundNotification) return;
    UICSend1(UICSceneDelegate(), @selector(sceneWillEnterForeground:), UICScene_);
    [UICScene_ _uic_setActivationState:UICActivationForegroundInactive];
    UICPost(SwiftLegacyUISceneWillEnterForegroundNotification, UICScene_);
}
static void UICWillTerminate(NSNotification *note) {
    if (!UICSceneMode || !UICScene_) return;
    UICSend1(UICSceneDelegate(), @selector(sceneDidDisconnect:), UICScene_);
    UICPost(SwiftLegacyUISceneDidDisconnectNotification, UICScene_);
}
static void UICStatusBarOrientationChanged(NSNotification *note) {
    if (!UICSceneMode || !UICScene_) return;
    id delegate = UICSceneDelegate();
    SEL selector = @selector(windowScene:didUpdateCoordinateSpace:interfaceOrientation:traitCollection:);
    UIInterfaceOrientation previous = UICPreviousOrientation;
    UICPreviousOrientation = [UIApplication sharedApplication].statusBarOrientation;
    if (previous == UICPreviousOrientation || !UICResponds(delegate, selector)) return;
    ((void (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(delegate, selector, UICScene_, [UICScene_ coordinateSpace], previous, [UICScene_ traitCollection]);
}

#pragma mark - Installation

static void UICObserve(NSString *name, void (*handler)(NSNotification *)) {
    [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                  usingBlock:^(NSNotification *note) { handler(note); }];
}

/// Public entry: registers the scene classes (only those UIKit lacks) and arms the
/// driver. Called from the backports image constructor.
static IMP UICOriginalSetDelegate;
static BOOL UICManifestPresent(void) {
    id manifest = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIApplicationSceneManifest"];
    return [manifest isKindOfClass:[NSDictionary class]];
}
static void UICSetDelegate(id self, SEL _cmd, id delegate) {
    // UIKit records which optional delegate methods exist at assignment, so the
    // scene routing must be in place before the original setter runs.
    if (delegate && UICManifestPresent()) UICAdaptApplicationDelegate(delegate);
    ((void (*)(id, SEL, id))UICOriginalSetDelegate)(self, _cmd, delegate);
}

void UICInstallUserActivity(void);
void UICInstallSceneLifecycle(void) {
    UICInstallUserActivity();
    if (objc_getClass("UIScene")) return;   // iOS 13+: Apple's implementation is used as-is.

    Class responder = objc_getClass("UIResponder");
    Class object = objc_getClass("NSObject");
    UICRegister("UISceneConfiguration", object, [UICSceneConfigurationT class]);
    UICRegister("UISceneActivationConditions", object, [UICSceneActivationConditionsT class]);
    UICRegister("UISceneSession", object, [UICSceneSessionT class]);
    UICRegister("UISceneOpenURLOptions", object, [UICSceneOpenURLOptionsT class]);
    UICRegister("UIOpenURLContext", object, [UICOpenURLContextT class]);
    UICRegister("UISceneConnectionOptions", object, [UICSceneConnectionOptionsT class]);
    UICRegister("UISceneSizeRestrictions", object, [UICSceneSizeRestrictionsT class]);
    Class destruction = UICRegister("UISceneDestructionRequestOptions", object, [UICSceneDestructionRequestOptionsT class]);
    UICRegister("UIWindowSceneDestructionRequestOptions", destruction, [UICWindowSceneDestructionRequestOptionsT class]);
    Class activation = UICRegister("UISceneActivationRequestOptions", object, [UICSceneActivationRequestOptionsT class]);
    UICRegister("UIWindowSceneActivationRequestOptions", activation, [UICWindowSceneActivationRequestOptionsT class]);
    UICRegister("UIWindowSceneActivationConfiguration", object, [UICWindowSceneActivationConfigurationT class]);
    UICRegister("_UIWindowSceneCoordinateSpace", object, [UICWindowSceneCoordinateSpaceT class]);
    UICRegister("UIStatusBarManager", object, [UICStatusBarManagerT class]);
    Class scene = UICRegister("UIScene", responder, [UICSceneT class]);
    UICRegister("UIWindowScene", scene, [UICWindowSceneT class]);

    Class window = objc_getClass("UIWindow");
    UICAddMissingMethods(window, [UICWindowAdditions class]);
    Method next = class_getInstanceMethod(window, @selector(nextResponder));
    if (next && !UICOriginalWindowNextResponder)
        UICOriginalWindowNextResponder = method_setImplementation(next, (IMP)UICWindowNextResponder);
    UICAddMissingMethods(objc_getClass("UIApplication"), [UICApplicationAdditions class]);

    Method setter = class_getInstanceMethod(objc_getClass("UIApplication"), @selector(setDelegate:));
    if (setter && !UICOriginalSetDelegate)
        UICOriginalSetDelegate = method_setImplementation(setter, (IMP)UICSetDelegate);
    UICObserve(UIApplicationDidFinishLaunchingNotification, UICDidFinishLaunching);
    UICObserve(UIApplicationDidBecomeActiveNotification, UICDidBecomeActive);
    UICObserve(UIApplicationWillResignActiveNotification, UICWillResignActive);
    UICObserve(UIApplicationDidEnterBackgroundNotification, UICDidEnterBackground);
    UICObserve(UIApplicationWillEnterForegroundNotification, UICWillEnterForeground);
    UICObserve(UIApplicationWillTerminateNotification, UICWillTerminate);
    UICObserve(UIApplicationDidChangeStatusBarOrientationNotification, UICStatusBarOrientationChanged);
    // Interface orientation also changes through view-controller rotation and setStatusBarOrientation:,
    // which do not always post the status-bar notification; the device-orientation signal covers them.
    UICObserve(UIDeviceOrientationDidChangeNotification, UICStatusBarOrientationChanged);
    UICObserve(UIWindowDidBecomeVisibleNotification, UICStatusBarOrientationChanged);
}

#pragma mark - NSUserActivity (iOS 8) model

@interface UICUserActivityT : NSObject
@property(nonatomic, readonly, copy) NSString *activityType;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSDictionary *userInfo;
@property(nonatomic, assign) BOOL needsSave;
@property(nonatomic, copy) NSURL *webpageURL;
@property(nonatomic, assign) BOOL supportsContinuationStreams;
@property(nonatomic, weak) id delegate;
@end
@implementation UICUserActivityT
@dynamic activityType, title, userInfo, needsSave, webpageURL, supportsContinuationStreams, delegate;
- (instancetype)initWithActivityType:(NSString *)type {
    if ((self = [super init])) UICSet(self, @"type", [type copy]);
    return self;
}
- (NSString *)activityType { return UICGet(self, @"type"); }
- (NSString *)title { return UICGet(self, @"title"); }
- (void)setTitle:(NSString *)value { UICSet(self, @"title", [value copy]); }
- (NSDictionary *)userInfo { return UICGet(self, @"userInfo"); }
- (void)setUserInfo:(NSDictionary *)value { UICSet(self, @"userInfo", [value copy]); }
- (void)addUserInfoEntriesFromDictionary:(NSDictionary *)other {
    NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:self.userInfo ?: [NSDictionary dictionary]];
    [merged addEntriesFromDictionary:other];
    UICSet(self, @"userInfo", merged);
}
- (BOOL)needsSave { return [UICGet(self, @"needsSave") boolValue]; }
- (void)setNeedsSave:(BOOL)value { UICSet(self, @"needsSave", @(value)); }
- (NSURL *)webpageURL { return UICGet(self, @"webpageURL"); }
- (void)setWebpageURL:(NSURL *)value { UICSet(self, @"webpageURL", [value copy]); }
- (BOOL)supportsContinuationStreams { return [UICGet(self, @"streams") boolValue]; }
- (void)setSupportsContinuationStreams:(BOOL)value { UICSet(self, @"streams", @(value)); }
- (id)delegate { return UICUnretained(self, @"delegate"); }
- (void)setDelegate:(id)value { UICSetUnretained(self, @"delegate", value); }
- (void)becomeCurrent {}
- (void)invalidate {}
@end

void UICInstallUserActivity(void) {
    if (objc_getClass("NSUserActivity")) return;
    UICRegister("NSUserActivity", objc_getClass("NSObject"), [UICUserActivityT class]);
}
