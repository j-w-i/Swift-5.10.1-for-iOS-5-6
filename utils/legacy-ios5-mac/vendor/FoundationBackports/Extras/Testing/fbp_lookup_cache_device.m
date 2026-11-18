// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Device test for FBPClassLookupCache.m (iPod touch 3G, iOS 5.1.1). Build it twice with the Xcode 13.4.1
// clang, -target armv7-apple-ios5.0 -fno-objc-arc (classes must never be retained), crt1.3.1.o and
// -lswiftFoundation from the toolchain: once with -Wl,-force_load,<Xcode>/usr/lib/arc/libarclite_iphoneos.a,
// as any ARC target with an iOS 5 deployment links it, and once without. Run next to the toolchain's
// runtime dylibs as `./test arclite` or `./test plain`; expect "ALL PASS". 2026-11-18:
// isEqualToString: 1848 -> 1247 ns (ARCLite) and 1625 -> 1249 ns (plain);
// objc_lookUpClass("NSString") 863 -> 293 ns and 691 -> 292 ns.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <pthread.h>
#include <mach/mach_time.h>
__attribute__((objc_runtime_name("_TtC3Foo3Bar")))
@interface FooBar : NSObject @end
@implementation FooBar @end

static int failures;
#define CHECK(c, ...) do { BOOL ok_ = (c); printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); if (!ok_) failures++; } while (0)
static double ns(uint64_t t) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)t * tb.numer / tb.denom; }
#define N 100000
static double IsEqualCost(void) {
    NSString *a = [[NSMutableString stringWithString:@"channel_message_create_1234567890"] copy];
    NSString *b = [[NSMutableString stringWithString:@"channel_message_create_1234567890"] copy];
    double best = 1e9;
    for (int round = 0; round < 3; round++) {
        volatile long sink = 0;
        uint64_t t0 = mach_absolute_time();
        for (int i = 0; i < N; i++) sink += [a isEqualToString:b];
        double cost = ns(mach_absolute_time() - t0) / N;
        if (cost < best) best = cost;
    }
    [a release]; [b release];
    return best;
}
static double LookUpCost(void) {
    double best = 1e9;
    for (int round = 0; round < 3; round++) {
        volatile long sink = 0;
        uint64_t t0 = mach_absolute_time();
        for (int i = 0; i < N; i++) sink += (long)objc_lookUpClass("NSString");
        double cost = ns(mach_absolute_time() - t0) / N;
        if (cost < best) best = cost;
    }
    return best;
}

typedef struct { const char *name; Class expected; } Probe;
static Probe *gProbes; static unsigned gProbeCount, gThreadMismatches;
static void *Hammer(void *context) {
    @autoreleasepool {
    for (unsigned round = 0; round < 10; round++)
        for (unsigned i = 0; i < gProbeCount; i++) {
            Probe p = gProbes[(i + (uintptr_t)context * 13) % gProbeCount];
            Class viaLookUp = objc_lookUpClass(p.name), viaFoundation = NSClassFromString([NSString stringWithUTF8String:p.name]);
            if (viaLookUp != p.expected || viaFoundation != p.expected) {
                if (__sync_fetch_and_add(&gThreadMismatches, 1) < 6)
                    printf("  mismatch %s: lookUp=%s NSClassFromString=%s expected=%p real=%s\n", p.name,
                           viaLookUp ? object_getClassName((id)viaLookUp) : "nil", viaFoundation ? "found" : "nil", p.expected,
                           ((const char *(*)(Class))dlsym(RTLD_DEFAULT, "class_getName"))(p.expected));
            }
        }
    }
    return NULL;
}

static void Semantics(const char *phase, BOOL arclite) {
    // "Module.Class" names resolve only through ARCLite's wrapper; with the cache in front that must not change.
    Class foo = [FooBar class];
    CHECK(objc_lookUpClass("Foo.Bar") == (arclite ? foo : Nil), "%s: objc_lookUpClass(\"Foo.Bar\") %s", phase, arclite ? "finds _TtC3Foo3Bar (ARCLite)" : "is Nil (no ARCLite)");
    CHECK(NSClassFromString(@"Foo.Bar") == (arclite ? foo : Nil), "%s: NSClassFromString(@\"Foo.Bar\") (Foundation's call)", phase);
    CHECK(objc_lookUpClass("_TtC3Foo3Bar") == foo && objc_lookUpClass("NSString") == [NSString class], "%s: plain names", phase);
    CHECK(objc_lookUpClass("FBPNoSuchClass_77") == Nil && NSClassFromString(@"FBPNoSuchClass_77") == Nil, "%s: unknown name is Nil", phase);
    const char *dynamicName = "FBPDeviceDynamicClass";
    Class first = objc_allocateClassPair([NSObject class], dynamicName, 0);
    objc_registerClassPair(first);
    BOOL found = objc_lookUpClass(dynamicName) == first && NSClassFromString(@"FBPDeviceDynamicClass") == first;
    objc_disposeClassPair(first);
    BOOL gone = objc_lookUpClass(dynamicName) == Nil;
    Class second = objc_allocateClassPair([NSObject class], dynamicName, 0);
    objc_registerClassPair(second);
    BOOL reused = objc_lookUpClass(dynamicName) == second;
    objc_disposeClassPair(second);
    CHECK(found && gone && reused, "%s: dynamic class found, gone after dispose, new class under the reused name found", phase);
}

int main(int argc, char **argv) { @autoreleasepool {
    BOOL arclite = argc > 1 && strcmp(argv[1], "arclite") == 0;
    void (*stats)(unsigned *, unsigned *) = dlsym(RTLD_DEFAULT, "FBPClassLookupCacheStatistics");
    CHECK(stats != NULL, "libswiftFoundation exports the cache");
    if (!stats) return 1;
    unsigned patched = 0, entries = 0;
    stats(&patched, &entries);
    CHECK(patched == 0, "nothing patched before the main queue runs (%u)", patched);
    Semantics("before", arclite);
    double equalBefore = IsEqualCost(), lookUpBefore = LookUpCost();

    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);   // drains the main queue: installs the cache
    stats(&patched, &entries);
    CHECK(patched >= 3, "cache installed in %u lazy pointers", patched);
    Semantics("after", arclite);

    unsigned count = 0;
    Class *classes = objc_copyClassList(&count);
    gProbes = calloc(count, sizeof *gProbes);
    unsigned mismatches = 0;
    for (unsigned i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        // objc_getClass is not cached: the cached lookup must give exactly its answer (nil for classes that
        // are not registered by name, such as ARCLite's own __ARCLite__).
        Class uncached = objc_getClass(name);
        if (objc_lookUpClass(name) != uncached) mismatches++;
        if (uncached && class_getImageName(classes[i]) && gProbeCount < 400) gProbes[gProbeCount++] = (Probe){name, uncached};
    }
    free(classes);
    CHECK(mismatches == 0, "cached objc_lookUpClass == uncached objc_getClass for all %u class names", count);
    pthread_t threads[4];
    for (uintptr_t i = 0; i < 4; i++) pthread_create(&threads[i], NULL, Hammer, (void *)i);
    Hammer((void *)9);
    for (int i = 0; i < 4; i++) pthread_join(threads[i], NULL);
    CHECK(gThreadMismatches == 0, "5 threads x %u names: objc_lookUpClass and NSClassFromString agree", gProbeCount);
    stats(&patched, &entries);

    double equalAfter = IsEqualCost(), lookUpAfter = LookUpCost();
    printf("isEqualToString: %.0f ns -> %.0f ns; objc_lookUpClass(\"NSString\"): %.0f ns -> %.0f ns; %u cached classes\n",
           equalBefore, equalAfter, lookUpBefore, lookUpAfter, entries);
    CHECK(equalAfter < equalBefore, "isEqualToString: is faster with the cache");
    printf("%s\n", failures ? "FAILED" : "ALL PASS");
    return failures != 0;
}}
