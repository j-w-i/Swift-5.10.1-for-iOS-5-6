// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Host differential tests for FBPSubscriptExtras.m: every FBP entry point against the native subscript methods
// (macOS Foundation has them), including the exceptions they raise, plus the installer's only-when-absent rule.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "../FoundationBackportsExtras.h"
#import "../FBPExtrasInternal.h"

static int gChecks, gFailures;
static void Check(BOOL ok, NSString *what) { gChecks++; if (!ok) { gFailures++; printf("FAIL: %s\n", what.UTF8String); } }

/// Runs a block and returns the name of the exception it raised, or @"" when it returned normally.
static NSString *Raised(void (^block)(void)) {
    @try { block(); } @catch (NSException *e) { return e.name; }
    return @"";
}

static void TestArrays(void) {
    NSArray *source = @[@"a", @"b", @"c"];
    for (NSUInteger i = 0; i < source.count; i++)
        Check([FBPNSArrayObjectAtIndexedSubscript(source, i) isEqual:[source objectAtIndexedSubscript:i]], @"array get matches native");
    Check([Raised(^{ FBPNSArrayObjectAtIndexedSubscript(source, 3); }) isEqual:Raised(^{ (void)[source objectAtIndexedSubscript:3]; })],
          @"array get past the end raises the native exception");

    NSMutableArray *fbp = [source mutableCopy], *native = [source mutableCopy];
    FBPNSMutableArraySetObjectAtIndexedSubscript(fbp, @"B", 1); [native setObject:@"B" atIndexedSubscript:1];
    FBPNSMutableArraySetObjectAtIndexedSubscript(fbp, @"d", 3); [native setObject:@"d" atIndexedSubscript:3];  // append at count
    Check([fbp isEqual:native] && fbp.count == 4, @"array replace and append-at-count match native");
    Check([Raised(^{ FBPNSMutableArraySetObjectAtIndexedSubscript(fbp, @"x", 9); }) isEqual:Raised(^{ [native setObject:@"x" atIndexedSubscript:9]; })],
          @"array set past the end raises the native exception");
    id nothing = nil;
    NSString *fbpNil = Raised(^{ FBPNSMutableArraySetObjectAtIndexedSubscript(fbp, nothing, 0); });
    NSString *nativeNil = Raised(^{ [native setObject:nothing atIndexedSubscript:0]; });
    Check(fbpNil.length > 0 && [fbpNil isEqual:nativeNil], [NSString stringWithFormat:@"array set nil raises like native (%@ vs %@)", fbpNil, nativeNil]);
    Check([fbp isEqual:native], @"failed array writes leave the array unchanged, like native");
}

static void TestDictionaries(void) {
    NSDictionary *source = @{@"k": @1, @2: @"two"};
    for (id key in @[@"k", @2, @"missing"])
        Check([FBPNSDictionaryObjectForKeyedSubscript(source, key) ?: NSNull.null isEqual:[source objectForKeyedSubscript:key] ?: NSNull.null],
              @"dictionary get matches native");
    NSMutableDictionary *fbp = [source mutableCopy], *native = [source mutableCopy];
    NSMutableString *key = [@"mutable" mutableCopy];
    FBPNSMutableDictionarySetObjectForKeyedSubscript(fbp, @"v", key); [native setObject:@"v" forKeyedSubscript:key];
    [key appendString:@"-changed"];  // keys are copied, so the stored key keeps its value
    Check([fbp isEqual:native] && fbp[@"mutable"] != nil, @"dictionary set copies its key like native");
    FBPNSMutableDictionarySetObjectForKeyedSubscript(fbp, nil, @"k"); [native setObject:nil forKeyedSubscript:@"k"];
    Check([fbp isEqual:native] && fbp[@"k"] == nil, @"dictionary set nil removes the key like current native Foundation");
    id nothing = nil;
    Check([Raised(^{ FBPNSMutableDictionarySetObjectForKeyedSubscript(fbp, @"v", nothing); }) isEqual:Raised(^{ [native setObject:@"v" forKeyedSubscript:nothing]; })],
          @"dictionary set with a nil key raises like native");
}

static void TestOrderedSets(void) {
    NSOrderedSet *source = [NSOrderedSet orderedSetWithArray:@[@"a", @"b", @"c"]];
    for (NSUInteger i = 0; i < source.count; i++)
        Check([FBPNSOrderedSetObjectAtIndexedSubscript(source, i) isEqual:[source objectAtIndexedSubscript:i]], @"ordered set get matches native");
    Check([Raised(^{ FBPNSOrderedSetObjectAtIndexedSubscript(source, 5); }) isEqual:Raised(^{ (void)[source objectAtIndexedSubscript:5]; })],
          @"ordered set get past the end raises the native exception");
    NSMutableOrderedSet *fbp = [source mutableCopy], *native = [source mutableCopy];
    FBPNSMutableOrderedSetSetObjectAtIndexedSubscript(fbp, @"B", 1); [native setObject:@"B" atIndexedSubscript:1];
    FBPNSMutableOrderedSetSetObjectAtIndexedSubscript(fbp, @"d", 3); [native setObject:@"d" atIndexedSubscript:3];
    FBPNSMutableOrderedSetSetObjectAtIndexedSubscript(fbp, @"a", 4); [native setObject:@"a" atIndexedSubscript:4];  // already a member
    FBPNSMutableOrderedSetSetObjectAtIndexedSubscript(fbp, @"c", 0); [native setObject:@"c" atIndexedSubscript:0];  // member elsewhere
    Check([fbp isEqual:native], [NSString stringWithFormat:@"ordered set writes match native (%@ vs %@)", fbp.array, native.array]);
    Check([Raised(^{ FBPNSMutableOrderedSetSetObjectAtIndexedSubscript(fbp, @"x", 9); }) isEqual:Raised(^{ [native setObject:@"x" atIndexedSubscript:9]; })],
          @"ordered set set past the end raises the native exception");
}

// A class with the primitive methods but no subscript methods: what NSArray & co. look like on iOS 5.
@interface FBPTestCollectionHost : NSObject { @public NSMutableArray *_items; NSMutableDictionary *_map; } @end
@implementation FBPTestCollectionHost
- (instancetype)init { if ((self = [super init])) { _items = [NSMutableArray array]; _map = [NSMutableDictionary dictionary]; } return self; }
- (NSUInteger)count { return _items.count; }
- (id)objectAtIndex:(NSUInteger)i { return [_items objectAtIndex:i]; }
- (void)addObject:(id)o { [_items addObject:o]; }
- (void)insertObject:(id)o atIndex:(NSUInteger)i { [_items insertObject:o atIndex:i]; }
- (void)replaceObjectAtIndex:(NSUInteger)i withObject:(id)o { [_items replaceObjectAtIndex:i withObject:o]; }
- (id)objectForKey:(id)k { return [_map objectForKey:k]; }
- (void)setObject:(id)o forKey:(id)k { [_map setObject:o forKey:k]; }
- (void)removeObjectForKey:(id)k { [_map removeObjectForKey:k]; }
@end

static NSString *Shape(const char *encoding) {
    // Drop the frame offsets ("@24@0:8Q16" -> "@@:Q") so encodings compare across compilers.
    NSMutableString *s = [NSMutableString string];
    for (const char *c = encoding; *c; c++) if (*c < '0' || *c > '9') [s appendFormat:@"%c", *c];
    return s;
}

static void TestInstaller(void) {
    Class host = [FBPTestCollectionHost class];
    SEL get = sel_registerName("objectAtIndexedSubscript:"), set = sel_registerName("setObject:atIndexedSubscript:");
    SEL keyGet = sel_registerName("objectForKeyedSubscript:"), keySet = sel_registerName("setObject:forKeyedSubscript:");
    Check(!class_getInstanceMethod(host, get) && !class_getInstanceMethod(host, keySet), @"test host starts without subscript methods");
    FBPInstallSubscriptExtrasOnClasses(host, host, host, host, nil, nil);
    FBPTestCollectionHost *h = [FBPTestCollectionHost new];
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(h, set, @"first", 0);   // append at count
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(h, set, @"second", 1);
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(h, set, @"FIRST", 0);   // replace
    id got = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(h, get, 0);
    Check([got isEqual:@"FIRST"] && h->_items.count == 2, @"installed indexed subscripts work on a class that lacked them");
    ((void (*)(id, SEL, id, id))objc_msgSend)(h, keySet, @"v", @"k");
    Check([((id (*)(id, SEL, id))objc_msgSend)(h, keyGet, @"k") isEqual:@"v"], @"installed keyed subscripts work");
    ((void (*)(id, SEL, id, id))objc_msgSend)(h, keySet, nil, @"k");
    Check(h->_map.count == 0, @"installed keyed set with nil removes");

    struct { Class cls; SEL sel; } natives[] = {
        {[NSArray class], get}, {[NSMutableArray class], set}, {[NSDictionary class], keyGet},
        {[NSMutableDictionary class], keySet}, {[NSOrderedSet class], get}, {[NSMutableOrderedSet class], set} };
    IMP before[6];
    for (int i = 0; i < 6; i++) before[i] = method_getImplementation(class_getInstanceMethod(natives[i].cls, natives[i].sel));
    FBPInstallSubscriptExtras();
    for (int i = 0; i < 6; i++) {
        Method m = class_getInstanceMethod(natives[i].cls, natives[i].sel);
        Check(method_getImplementation(m) == before[i], [NSString stringWithFormat:@"native -[%@ %@] is not replaced", natives[i].cls, NSStringFromSelector(natives[i].sel)]);
        Method installed = class_getInstanceMethod(host, natives[i].sel);
        if (installed)
            Check([Shape(method_getTypeEncoding(installed)) isEqual:Shape(method_getTypeEncoding(m))],
                  [NSString stringWithFormat:@"%@ type encoding %s matches native %s", NSStringFromSelector(natives[i].sel), method_getTypeEncoding(installed), method_getTypeEncoding(m)]);
    }
}

int main(void) {
    @autoreleasepool {
        TestArrays();
        TestDictionaries();
        TestOrderedSets();
        TestInstaller();
        printf("%s: subscripts: %d checks, %d failures\n", gFailures == 0 ? "PASS" : "FAIL", gChecks, gFailures);
        return gFailures == 0 ? 0 : 1;
    }
}
