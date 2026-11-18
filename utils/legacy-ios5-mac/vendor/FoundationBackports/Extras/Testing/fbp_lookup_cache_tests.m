// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Host tests for FBPClassLookupCache.m: FBPCachedLookUpClass against libobjc's objc_lookUpClass, which
// classes it caches (image classes only), reuse of the caller's name buffer, and concurrent use.
// The Mach-O slot patching needs lazy symbol pointers (iOS 5-7 images) and is covered on device.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <pthread.h>
#import "../FBPExtrasInternal.h"

static int gChecks, gFailures;
static void Check(BOOL ok, NSString *what) { gChecks++; if (!ok) { gFailures++; printf("FAIL: %s\n", what.UTF8String); } }

// Untyped lookups, as the cache sees them: ARC must not retain classes (some roots lack -retain).
static void *(*const Native)(const char *) = (void *(*)(const char *))(void *)objc_lookUpClass;
#define Cached FBPCachedLookUpClass

static unsigned gFallbackCalls;
static void *CountingFallback(const char *name) {
    __atomic_fetch_add(&gFallbackCalls, 1, __ATOMIC_RELAXED);
    return Native(name);
}

static NSArray<NSString *> *ImageClassNames(unsigned limit) {
    unsigned count = 0;
    __unsafe_unretained Class *classes = objc_copyClassList(&count);
    NSMutableArray *names = [NSMutableArray array];
    for (unsigned i = 0; i < count && names.count < limit; i++)
        if (class_getImageName(classes[i])) [names addObject:@(class_getName(classes[i]))];
    free(classes);
    return names;
}

static void TestMatchesNative(NSArray<NSString *> *names) {
    unsigned mismatches = 0;
    for (NSString *name in names)
        if (Cached(name.UTF8String) != Native(name.UTF8String)) mismatches++;
    Check(mismatches == 0, [NSString stringWithFormat:@"first lookups match objc_lookUpClass (%u of %lu differ)", mismatches, (unsigned long)names.count]);

    unsigned before = gFallbackCalls;
    mismatches = 0;
    for (NSString *name in names)
        if (Cached(name.UTF8String) != Native(name.UTF8String)) mismatches++;
    unsigned misses = gFallbackCalls - before;
    Check(mismatches == 0, @"cached lookups match objc_lookUpClass");
    // A few names can fall outside their hash's probe window and stay uncached; that only costs a lookup.
    Check(misses * 20 < names.count, [NSString stringWithFormat:@"repeat lookups are served from the cache (%u of %lu missed)", misses, (unsigned long)names.count]);
    unsigned entries = 0;
    FBPClassLookupCacheStatistics(NULL, &entries);
    Check(entries > 0 && entries <= names.count, [NSString stringWithFormat:@"entry count is sane (%u)", entries]);
}

static void TestNotCached(void) {
    unsigned before = gFallbackCalls;
    Check(!Cached(NULL) && !Cached("FBPNoSuchClass_8f3a") && !Cached("FBPNoSuchClass_8f3a"), @"NULL and unknown names return Nil");
    Check(gFallbackCalls - before == 3, @"Nil results are not cached (a class can appear later)");

    const char *name = "FBPLookupCacheDynamicClass";
    __unsafe_unretained Class first = objc_allocateClassPair([NSObject class], name, 0);
    objc_registerClassPair(first);
    Check(Cached(name) == (__bridge void *)first && Cached(name) == (__bridge void *)first, @"dynamic class found");
    objc_disposeClassPair(first);
    Check(!Cached(name), @"disposed dynamic class is gone (it was never cached)");
    __unsafe_unretained Class second = objc_allocateClassPair([NSObject class], name, 0);
    objc_registerClassPair(second);
    Check(Cached(name) == (__bridge void *)second, @"a new class with a reused name is found");
    objc_disposeClassPair(second);
}

static void TestReusedBuffer(void) {
    // NSClassFromString-style callers pass the same stack buffer with different contents.
    char buffer[64];
    strlcpy(buffer, "NSString", sizeof buffer);
    void *string = Cached(buffer);
    strlcpy(buffer, "NSArray", sizeof buffer);
    void *array = Cached(buffer);
    strlcpy(buffer, "NSString", sizeof buffer);
    Check(string == (__bridge void *)[NSString class] && array == (__bridge void *)[NSArray class] &&
          Cached(buffer) == (__bridge void *)[NSString class],
          @"cache keys on the name's contents, not the caller's pointer");
}

static NSArray<NSString *> *gThreadNames;
static unsigned gThreadMismatches;
static void *Hammer(void *context) {
    unsigned offset = (unsigned)(uintptr_t)context;
    for (unsigned round = 0; round < 20; round++)
        for (NSUInteger i = 0; i < gThreadNames.count; i++) {
            const char *name = gThreadNames[(i + offset * 37) % gThreadNames.count].UTF8String;
            if (Cached(name) != Native(name)) __atomic_fetch_add(&gThreadMismatches, 1, __ATOMIC_RELAXED);
        }
    return NULL;
}

static void TestConcurrent(NSArray<NSString *> *names) {
    gThreadNames = names;
    pthread_t threads[6];
    for (uintptr_t i = 0; i < 6; i++) pthread_create(&threads[i], NULL, Hammer, (void *)i);
    for (int i = 0; i < 6; i++) pthread_join(threads[i], NULL);
    Check(gThreadMismatches == 0, [NSString stringWithFormat:@"concurrent first use agrees with objc_lookUpClass (%u mismatches)", gThreadMismatches]);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        FBPSetClassLookupFallbackForTesting(CountingFallback);
        if (argc > 1 && strcmp(argv[1], "--concurrency-only") == 0) {
            TestConcurrent(ImageClassNames(1500));
            printf("%s: lookup cache concurrency-only: %d checks, %d failures\n", gFailures ? "FAIL" : "PASS", gChecks, gFailures);
            return gFailures != 0;
        }
        TestMatchesNative(ImageClassNames(600));
        TestNotCached();
        TestReusedBuffer();
        TestConcurrent(ImageClassNames(1500));
        printf("%s: lookup cache: %d checks, %d failures\n", gFailures ? "FAIL" : "PASS", gChecks, gFailures);
        return gFailures != 0;
    }
}
