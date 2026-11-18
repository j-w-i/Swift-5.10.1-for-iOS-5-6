// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Original implementation.
//
// Object subscripting (iOS 6). Clang compiles `array[i]`, `array[i] = x`, `dict[key]` and `dict[key] = x` to these
// four selectors, and Swift imports NSArray/NSMutableArray/NSOrderedSet subscripts from them. iOS 5.1.1 Foundation
// implements none of them (checked on device), and the toolchain does not link Apple's ARCLite, which is what
// normally adds them for an iOS 5 deployment. Installed with class_addMethod only when the running OS lacks the
// selector, so iOS 6+ keeps its native implementations.
#import "FoundationBackportsExtras.h"
#import "FBPExtrasInternal.h"
#import <objc/runtime.h>

id FBPNSArrayObjectAtIndexedSubscript(NSArray *array, NSUInteger index) {
    return [array objectAtIndex:index];
}

void FBPNSMutableArraySetObjectAtIndexedSubscript(NSMutableArray *array, id object, NSUInteger index) {
    // Native: at index == count the object is appended; any other index replaces. A nil object or an index past
    // the end raises the same exceptions as -addObject: / -replaceObjectAtIndex:withObject:.
    if (index == array.count) [array addObject:object];
    else [array replaceObjectAtIndex:index withObject:object];
}

id FBPNSDictionaryObjectForKeyedSubscript(NSDictionary *dictionary, id key) {
    return [dictionary objectForKey:key];
}

void FBPNSMutableDictionarySetObjectForKeyedSubscript(NSMutableDictionary *dictionary, id _Nullable object, id key) {
    // A nil object removes the key, as current Foundation (and Swift's `dict[key] = nil`) does. iOS 6-10 raised.
    if (object) [dictionary setObject:object forKey:key];
    else [dictionary removeObjectForKey:key];
}

id FBPNSOrderedSetObjectAtIndexedSubscript(NSOrderedSet *set, NSUInteger index) {
    return [set objectAtIndex:index];
}

void FBPNSMutableOrderedSetSetObjectAtIndexedSubscript(NSMutableOrderedSet *set, id object, NSUInteger index) {
    // Native: at index == count the object is inserted at the end; any other index replaces.
    if (index == set.count) [set insertObject:object atIndex:index];
    else [set replaceObjectAtIndex:index withObject:object];
}

static id ArrayGetIMP(id self, SEL _cmd, NSUInteger index) { return FBPNSArrayObjectAtIndexedSubscript(self, index); }
static void ArraySetIMP(id self, SEL _cmd, id object, NSUInteger index) { FBPNSMutableArraySetObjectAtIndexedSubscript(self, object, index); }
static id DictionaryGetIMP(id self, SEL _cmd, id key) { return FBPNSDictionaryObjectForKeyedSubscript(self, key); }
static void DictionarySetIMP(id self, SEL _cmd, id object, id key) { FBPNSMutableDictionarySetObjectForKeyedSubscript(self, object, key); }
static id OrderedGetIMP(id self, SEL _cmd, NSUInteger index) { return FBPNSOrderedSetObjectAtIndexedSubscript(self, index); }
static void OrderedSetIMP(id self, SEL _cmd, id object, NSUInteger index) { FBPNSMutableOrderedSetSetObjectAtIndexedSubscript(self, object, index); }

// Selectors are registered by name, not @selector(): the image then carries no reference to an iOS 6 selector,
// which check-ios5-selectors.py would (correctly) report.
static void AddIfAbsent(Class target, const char *name, IMP imp, const char *types) {
    if (!target) return;
    SEL selector = sel_registerName(name);
    if (class_getInstanceMethod(target, selector) == nil) class_addMethod(target, selector, imp, types);
}

void FBPInstallSubscriptExtrasOnClasses(Class array, Class mutableArray, Class dictionary,
                                        Class mutableDictionary, Class orderedSet, Class mutableOrderedSet) {
    // NSUInteger is `unsigned int` on armv7 and `unsigned long` on 64-bit targets.
    static char getIndexed[16], setIndexed[16];
    snprintf(getIndexed, sizeof getIndexed, "@@:%s", @encode(NSUInteger));
    snprintf(setIndexed, sizeof setIndexed, "v@:@%s", @encode(NSUInteger));
    AddIfAbsent(array, "objectAtIndexedSubscript:", (IMP)ArrayGetIMP, getIndexed);
    AddIfAbsent(mutableArray, "setObject:atIndexedSubscript:", (IMP)ArraySetIMP, setIndexed);
    AddIfAbsent(dictionary, "objectForKeyedSubscript:", (IMP)DictionaryGetIMP, "@@:@");
    AddIfAbsent(mutableDictionary, "setObject:forKeyedSubscript:", (IMP)DictionarySetIMP, "v@:@@");
    AddIfAbsent(orderedSet, "objectAtIndexedSubscript:", (IMP)OrderedGetIMP, getIndexed);
    AddIfAbsent(mutableOrderedSet, "setObject:atIndexedSubscript:", (IMP)OrderedSetIMP, setIndexed);
}

void FBPInstallSubscriptExtras(void) {
    FBPInstallSubscriptExtrasOnClasses([NSArray class], [NSMutableArray class], [NSDictionary class],
                                       [NSMutableDictionary class], [NSOrderedSet class], [NSMutableOrderedSet class]);
}
