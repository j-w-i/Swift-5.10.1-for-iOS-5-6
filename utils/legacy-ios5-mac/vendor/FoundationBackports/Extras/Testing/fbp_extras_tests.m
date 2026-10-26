// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Host differential tests for FoundationBackports/Extras.
//
// Everything here calls the FBP implementations directly and compares against the
// native Foundation implementation on the host. It never depends on the native
// selectors being absent (on macOS they are all present; the installer is a
// no-op and that is asserted too).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <pthread.h>
#import "../FoundationBackportsExtras.h"
#import "../FBPExtrasInternal.h"

static int gFailures = 0;
static int gChecks = 0;

static void Fail(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    gFailures++;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
}

static void Check(BOOL condition, NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    gChecks++;
    if (!condition) Fail(@"%@", message);
}

static uint64_t gRandomState = 0x243F6A8885A308D3ULL;
static uint64_t Random64(void) {
    gRandomState ^= gRandomState << 13;
    gRandomState ^= gRandomState >> 7;
    gRandomState ^= gRandomState << 17;
    return gRandomState;
}
static NSUInteger RandomBelow(NSUInteger bound) { return bound ? (NSUInteger)(Random64() % bound) : 0; }

// MARK: - Concurrent first use

// The singleton caches must be safely published: a thread that calls one of the
// getters for the first time while another thread initialises it must see the
// same fully-initialised object. Run this before any other test touches the sets
// so the first initialisation really happens under contention. This is also the
// test run under ThreadSanitizer by run-extras-tests.sh.
typedef struct {
    int index;
    NSCharacterSet *sets[6];
    BOOL consistent;
} FBPConcurrentContext;

// macOS has no pthread_barrier_t; a spin rendezvous is enough for a 16-thread
// first-use test (each thread waits until all have entered the function).
static const int kFBPConcurrentThreads = 16;
static int gFBPConcurrentReadyCount = 0;

static void *FBPConcurrentFirstUseWorker(void *argument) {
    FBPConcurrentContext *context = (FBPConcurrentContext *)argument;
    // Synchronise every thread just before the first getter call.
    __atomic_add_fetch(&gFBPConcurrentReadyCount, 1, __ATOMIC_RELEASE);
    while (__atomic_load_n(&gFBPConcurrentReadyCount, __ATOMIC_ACQUIRE) < kFBPConcurrentThreads) {
        /* rendezvous until every thread has entered the function */
    }
    context->sets[0] = FBPURLUserAllowedCharacterSet();
    context->sets[1] = FBPURLPasswordAllowedCharacterSet();
    context->sets[2] = FBPURLHostAllowedCharacterSet();
    context->sets[3] = FBPURLPathAllowedCharacterSet();
    context->sets[4] = FBPURLQueryAllowedCharacterSet();
    context->sets[5] = FBPURLFragmentAllowedCharacterSet();
    // A second call must return the same singleton (repeat concurrently too).
    context->consistent = FBPURLUserAllowedCharacterSet() == context->sets[0]
        && FBPURLPasswordAllowedCharacterSet() == context->sets[1]
        && FBPURLHostAllowedCharacterSet() == context->sets[2]
        && FBPURLPathAllowedCharacterSet() == context->sets[3]
        && FBPURLQueryAllowedCharacterSet() == context->sets[4]
        && FBPURLFragmentAllowedCharacterSet() == context->sets[5];
    return NULL;
}

static void TestConcurrentFirstUse(void) {
    __atomic_store_n(&gFBPConcurrentReadyCount, 0, __ATOMIC_RELEASE);
    FBPConcurrentContext contexts[kFBPConcurrentThreads];
    pthread_t threads[kFBPConcurrentThreads];
    for (int i = 0; i < kFBPConcurrentThreads; i++) {
        contexts[i].index = i;
        memset(contexts[i].sets, 0, sizeof(contexts[i].sets));
        contexts[i].consistent = NO;
        pthread_create(&threads[i], NULL, FBPConcurrentFirstUseWorker, &contexts[i]);
    }
    for (int i = 0; i < kFBPConcurrentThreads; i++) pthread_join(threads[i], NULL);

    for (int setIndex = 0; setIndex < 6; setIndex++) {
        NSCharacterSet *first = contexts[0].sets[setIndex];
        Check(first != nil, @"concurrent first use returned nil for set %d", setIndex);
        for (int thread = 1; thread < kFBPConcurrentThreads; thread++) {
            Check(contexts[thread].sets[setIndex] == first,
                  @"set %d published different pointers across threads (%p vs %p)",
                  setIndex, contexts[thread].sets[setIndex], first);
            Check(contexts[thread].consistent, @"thread %d saw inconsistent singletons", thread);
        }
    }
    // Correct contents after the concurrent initialisation.
    Check([contexts[0].sets[2] characterIsMember:'['], @"host set missing '['");
    Check(![contexts[0].sets[2] characterIsMember:'@'], @"host set incorrectly contains '@'");
    Check([contexts[0].sets[0] characterIsMember:'!'], @"user set missing '!'");
    Check(![contexts[0].sets[0] characterIsMember:'['], @"user set incorrectly contains '['");
    Check([contexts[0].sets[4] characterIsMember:'?'], @"query set missing '?'");
    Check([contexts[0].sets[4] characterIsMember:':'], @"query set missing ':'");
}

// MARK: - Character sets

static NSCharacterSet *NativeURLSet(SEL selector) {
    return ((NSCharacterSet *(*)(id, SEL))objc_msgSend)([NSCharacterSet class], selector);
}

static NSString *MembershipString(NSCharacterSet *set) {
    NSMutableString *result = [NSMutableString string];
    for (uint32_t value = 0; value < 128; value++) {
        if ([set characterIsMember:(unichar)value]) [result appendFormat:@"%C", (unichar)value];
    }
    return result;
}

static void TestCharacterSets(void) {
    struct { const char *name; NSCharacterSet *(*fbp)(void); SEL nativeSelector; NSString *expected; } sets[] = {
        { "URLUserAllowed", FBPURLUserAllowedCharacterSet, @selector(URLUserAllowedCharacterSet),
          @"!$&'()*+,-.0123456789;=ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~" },
        { "URLPasswordAllowed", FBPURLPasswordAllowedCharacterSet, @selector(URLPasswordAllowedCharacterSet),
          @"!$&'()*+,-.0123456789;=ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~" },
        { "URLHostAllowed", FBPURLHostAllowedCharacterSet, @selector(URLHostAllowedCharacterSet),
          @"!$&'()*+,-.0123456789:;=ABCDEFGHIJKLMNOPQRSTUVWXYZ[]_abcdefghijklmnopqrstuvwxyz~" },
        { "URLPathAllowed", FBPURLPathAllowedCharacterSet, @selector(URLPathAllowedCharacterSet),
          @"!$&'()*+,-./0123456789:;=@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~" },
        { "URLQueryAllowed", FBPURLQueryAllowedCharacterSet, @selector(URLQueryAllowedCharacterSet),
          @"!$&'()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~" },
        { "URLFragmentAllowed", FBPURLFragmentAllowedCharacterSet, @selector(URLFragmentAllowedCharacterSet),
          @"!$&'()*+,-./0123456789:;=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz~" },
    };
    for (size_t i = 0; i < sizeof(sets) / sizeof(sets[0]); i++) {
        NSCharacterSet *fbp = sets[i].fbp();
        NSCharacterSet *native = ((NSCharacterSet *(*)(id, SEL))objc_msgSend)([NSCharacterSet class], sets[i].nativeSelector);
        NSString *fbpASCII = MembershipString(fbp);
        Check([fbpASCII isEqualToString:sets[i].expected], @"%s ascii membership '%@' != expected '%@'", sets[i].name, fbpASCII, sets[i].expected);
        Check([MembershipString(native) isEqualToString:sets[i].expected], @"%s native membership changed on this host", sets[i].name);
        // Exact membership over the whole Unicode range, not just ASCII.
        BOOL mismatch = NO;
        for (uint32_t value = 0; value <= 0x10FFFF && !mismatch; value++) {
            if (value >= 0xD800 && value <= 0xDFFF) continue;
            BOOL a = [fbp longCharacterIsMember:value];
            BOOL b = [native longCharacterIsMember:value];
            if (a != b) {
                Fail(@"%s membership differs at U+%04X: FBP=%d native=%d", sets[i].name, value, a, b);
                mismatch = YES;
            }
        }
        Check(!mismatch, @"%s full-range membership", sets[i].name);
        Check([fbp.bitmapRepresentation isEqualToData:native.bitmapRepresentation], @"%s bitmap != native", sets[i].name);
        // Cached instance.
        Check(sets[i].fbp() == fbp, @"%s set is not cached", sets[i].name);
    }
}

static void TestInstallerOnlyWhenAbsent(void) {
    // On the host every native selector exists: installing must not replace it.
    const char *selectors[] = { "isDateInToday:", "isDateInYesterday:", "isDateInTomorrow:", "isDate:inSameDayAsDate:" };
    IMP before[4]; for (int i = 0; i < 4; i++) before[i] = class_getMethodImplementation([NSCalendar class], sel_registerName(selectors[i]));
    FBPInstallFoundationExtras();
    for (int i = 0; i < 4; i++) {
        IMP after = class_getMethodImplementation([NSCalendar class], sel_registerName(selectors[i]));
        Check(before[i] == after, @"installer replaced native NSCalendar selector %s", selectors[i]);
    }
    // Installing on a class that lacks them adds them exactly once.
    Class synthetic = objc_allocateClassPair([NSObject class], "FBPSyntheticTestCalendar", 0);
    objc_registerClassPair(synthetic);
    FBPInstallCalendarExtrasOnClass(synthetic);
    IMP first = class_getMethodImplementation(synthetic, sel_registerName("isDateInToday:"));
    Check(first != NULL, @"synthetic class did not receive isDateInToday:");
    FBPInstallCalendarExtrasOnClass(synthetic);
    IMP second = class_getMethodImplementation(synthetic, sel_registerName("isDateInToday:"));
    Check(first == second, @"reinstall replaced the FBP IMP");
    // BOOL encoding must be the runtime's (B on modern ObjC, c on armv7/iOS 5).
    Method installed = class_getInstanceMethod(synthetic, sel_registerName("isDateInToday:"));
    const char *installedTypes = method_getTypeEncoding(installed);
    Check(installedTypes != NULL && installedTypes[0] == @encode(BOOL)[0],
          @"installed BOOL encoding '%s' does not match @encode(BOOL) '%s'",
          installedTypes ? installedTypes : "(null)", @encode(BOOL));

    Class syntheticString = objc_allocateClassPair([NSObject class], "FBPSyntheticTestString", 0);
    objc_registerClassPair(syntheticString);
    FBPInstallStringExtrasOnClass(syntheticString);
    Check(class_getInstanceMethod(syntheticString, sel_registerName("stringByRemovingPercentEncoding")) != nil,
          @"synthetic class did not receive stringByRemovingPercentEncoding");
    Class syntheticSet = objc_allocateClassPair([NSObject class], "FBPSyntheticTestCharacterSet", 0);
    objc_registerClassPair(syntheticSet);
    FBPInstallCharacterSetExtrasOnClass(syntheticSet);
    Check(class_getClassMethod(syntheticSet, sel_registerName("URLUserAllowedCharacterSet")) != nil,
          @"synthetic class did not receive URLUserAllowedCharacterSet");
}

// MARK: - Percent encoding

static NSArray<NSCharacterSet *> *AllowedSets(void) {
    NSMutableArray *sets = [NSMutableArray array];
    [sets addObject:NativeURLSet(@selector(URLUserAllowedCharacterSet))];
    [sets addObject:NativeURLSet(@selector(URLPasswordAllowedCharacterSet))];
    [sets addObject:NativeURLSet(@selector(URLHostAllowedCharacterSet))];
    [sets addObject:NativeURLSet(@selector(URLPathAllowedCharacterSet))];
    [sets addObject:NativeURLSet(@selector(URLQueryAllowedCharacterSet))];
    [sets addObject:NativeURLSet(@selector(URLFragmentAllowedCharacterSet))];
    [sets addObject:[NSCharacterSet characterSetWithCharactersInString:@""]];
    [sets addObject:[NSCharacterSet characterSetWithCharactersInString:@"abcXYZ019_-"]];
    NSMutableCharacterSet *nonASCII = [NSMutableCharacterSet characterSetWithCharactersInString:@"ab"];
    [nonASCII addCharactersInString:@"é世"];
    [sets addObject:nonASCII];
    NSMutableCharacterSet *surrogateRange = [NSMutableCharacterSet characterSetWithRange:NSMakeRange(0xD800, 0x800)];
    [sets addObject:surrogateRange];
    return sets;
}

static NSString *RandomString(NSUInteger maxLength) {
    NSUInteger length = RandomBelow(maxLength + 1);
    NSMutableString *string = [NSMutableString string];
    for (NSUInteger i = 0; i < length; i++) {
        uint32_t scalar;
        switch (RandomBelow(5)) {
            case 0: scalar = 0x20 + RandomBelow(0x5F); break;                 // printable ASCII
            case 1: scalar = RandomBelow(0x80); break;                         // ASCII incl. controls
            case 2: scalar = 0x80 + RandomBelow(0x780); break;                 // Latin/Greek/etc
            case 3: scalar = 0x4E00 + RandomBelow(0x100); break;               // CJK
            default: scalar = 0x1F300 + RandomBelow(0x100); break;             // non-BMP
        }
        if (scalar >= 0xD800 && scalar <= 0xDFFF) scalar = 0xE9;
        [string appendFormat:@"%C", (unichar)scalar];
    }
    return string;
}

static void TestPercentEncoding(void) {
    NSArray *sets = AllowedSets();
    // Fixed cases matching Apple's documented behavior.
    Check([FBPNSStringAddingPercentEncoding(@"a b/c?d=e&f+g~h!$'()*;,=:[]@", NSCharacterSet.URLQueryAllowedCharacterSet)
           isEqualToString:@"a%20b/c?d=e&f+g~h!$'()*;,=:%5B%5D@"], @"fixed encode case");
    Check([FBPNSStringAddingPercentEncoding(@"héllo 世界", NSCharacterSet.URLQueryAllowedCharacterSet)
           isEqualToString:@"h%C3%A9llo%20%E4%B8%96%E7%95%8C"], @"fixed unicode encode case");
    Check([FBPNSStringAddingPercentEncoding(@"aébc", [NSCharacterSet characterSetWithCharactersInString:@"aébc"])
           isEqualToString:@"a%C3%A9bc"], @"non-ASCII stays escaped even when in allowed set");
    Check([FBPNSStringAddingPercentEncoding(@"a%b", NSCharacterSet.URLQueryAllowedCharacterSet)
           isEqualToString:@"a%25b"], @"percent itself is escaped");
    Check([[@"a%20b" stringByRemovingPercentEncoding] isEqualToString:@"a b"], @"fixed decode case");
    Check([[@"h%C3%A9llo" stringByRemovingPercentEncoding] isEqualToString:@"héllo"], @"fixed unicode decode case");
    Check([@"a%zzb" stringByRemovingPercentEncoding] == nil, @"invalid percent sequence -> nil");
    Check([@"a%2" stringByRemovingPercentEncoding] == nil, @"incomplete percent sequence -> nil");
    Check([@"a%FFb" stringByRemovingPercentEncoding] == nil, @"invalid UTF-8 -> nil");
    Check([[@"a+b" stringByRemovingPercentEncoding] isEqualToString:@"a+b"], @"plus is not decoded as space");
    Check([@"" stringByRemovingPercentEncoding] != nil, @"empty decode");
    Check([FBPNSStringAddingPercentEncoding(@"", NSCharacterSet.URLQueryAllowedCharacterSet) isEqualToString:@""], @"empty encode");

    // System URL-set rules are keyed to the CF object identity: -copy shares it
    // (still escapes '[' ':' for host / ':' for path), -mutableCopy creates a new
    // CF set (plain membership, brackets preserved). Verify the FBP encoder
    // reproduces exactly that, including for copies of the FBP sets.
    NSString *probe = @"[:]abc/é";
    NSArray *systemSets = @[ NativeURLSet(@selector(URLHostAllowedCharacterSet)),
                             NativeURLSet(@selector(URLPathAllowedCharacterSet)),
                             NativeURLSet(@selector(URLQueryAllowedCharacterSet)) ];
    for (NSCharacterSet *systemSet in systemSets) {
        NSArray *variants = @[ systemSet, [systemSet copy], [systemSet mutableCopy],
                               [systemSet invertedSet], [[systemSet invertedSet] invertedSet] ];
        for (NSCharacterSet *variant in variants) {
            NSString *native = [probe stringByAddingPercentEncodingWithAllowedCharacters:variant];
            NSString *fbp = FBPNSStringAddingPercentEncoding(probe, variant);
            Check((native == nil && fbp == nil) || [native isEqualToString:fbp],
                  @"system-set identity mismatch (%@ variant class %@): native=%@ fbp=%@",
                  systemSet, [variant class], native, fbp);
        }
    }
    // FBP sets are our own CF objects, so on the host native Foundation treats them
    // as plain sets. The backport intentionally gives OUR URL singleton (and its
    // -copy, which shares the CF object) the system URL-component rules so an iOS 5
    // app sees the same result as the native API; -mutableCopy loses the identity
    // and falls back to plain membership, exactly like a native mutableCopy.
    NSArray *fbpSets = @[ FBPURLHostAllowedCharacterSet(), FBPURLPathAllowedCharacterSet(),
                          FBPURLQueryAllowedCharacterSet() ];
    NSArray *nativeEquivalents = @[ NativeURLSet(@selector(URLHostAllowedCharacterSet)),
                                    NativeURLSet(@selector(URLPathAllowedCharacterSet)),
                                    NativeURLSet(@selector(URLQueryAllowedCharacterSet)) ];
    for (NSUInteger index = 0; index < fbpSets.count; index++) {
        NSCharacterSet *fbpSet = fbpSets[index];
        NSCharacterSet *nativeEquivalent = nativeEquivalents[index];
        NSString *systemBehaviour = [probe stringByAddingPercentEncodingWithAllowedCharacters:nativeEquivalent];
        Check([FBPNSStringAddingPercentEncoding(probe, fbpSet) isEqualToString:systemBehaviour],
              @"FBP URL set did not get system rules: fbp=%@ system=%@", fbpSet, systemBehaviour);
        Check([FBPNSStringAddingPercentEncoding(probe, [fbpSet copy]) isEqualToString:systemBehaviour],
              @"FBP URL set copy lost system rules");
        NSString *plainBehaviour = [probe stringByAddingPercentEncodingWithAllowedCharacters:[nativeEquivalent mutableCopy]];
        Check([FBPNSStringAddingPercentEncoding(probe, [fbpSet mutableCopy]) isEqualToString:plainBehaviour],
              @"FBP URL set mutableCopy should use plain membership");
    }
    for (int iteration = 0; iteration < 2000; iteration++) {
        NSString *string = RandomString(24);
        NSUInteger allowedIndex = RandomBelow(sets.count);
        NSCharacterSet *allowed = sets[allowedIndex];
        NSString *native = [string stringByAddingPercentEncodingWithAllowedCharacters:allowed];
        NSString *fbp = FBPNSStringAddingPercentEncoding(string, allowed);
        Check((native == nil && fbp == nil) || [native isEqualToString:fbp],
              @"encode mismatch for '%@' set#%lu (%@): native=%@ fbp=%@", string, (unsigned long)allowedIndex, allowed, native, fbp);
    }
    // Decode fuzz: random strings over a percent/hex/byte alphabet.
    NSString *alphabet = @"0123456789ABCDEFabcdef%+ /?&=#é世";
    for (int iteration = 0; iteration < 4000; iteration++) {
        NSUInteger length = RandomBelow(20);
        NSMutableString *string = [NSMutableString string];
        for (NSUInteger i = 0; i < length; i++) {
            unichar c = [alphabet characterAtIndex:RandomBelow(alphabet.length)];
            [string appendFormat:@"%C", c];
        }
        NSString *native = [string stringByRemovingPercentEncoding];
        NSString *fbp = FBPNSStringRemovingPercentEncoding(string);
        Check((native == nil && fbp == nil) || [native isEqualToString:fbp],
              @"decode mismatch for '%@': native=%@ fbp=%@", string, native, fbp);
    }
}

// MARK: - Calendar predicates

static NSArray<NSString *> *CalendarIdentifiers(void) {
    return @[ NSCalendarIdentifierGregorian, NSCalendarIdentifierBuddhist, NSCalendarIdentifierHebrew,
              NSCalendarIdentifierIslamic, NSCalendarIdentifierIslamicCivil, NSCalendarIdentifierJapanese,
              NSCalendarIdentifierPersian, NSCalendarIdentifierRepublicOfChina, NSCalendarIdentifierISO8601 ];
}

static NSArray<NSString *> *ZoneIdentifiers(void) {
    return @[ @"UTC", @"America/Los_Angeles", @"America/St_Johns", @"Europe/Berlin",
              @"Australia/Sydney", @"Asia/Kathmandu", @"Pacific/Chatham", @"America/Sao_Paulo",
              @"Asia/Tehran", @"Africa/Casablanca" ];
}

static BOOL NativeSameDay(NSCalendar *calendar, NSDate *a, NSDate *b) {
    return [calendar isDate:a inSameDayAsDate:b];
}

static void TestCalendar(void) {
    NSDate *now = [NSDate date];
    NSArray *identifiers = CalendarIdentifiers();
    NSArray *zones = ZoneIdentifiers();
    // Predicates relative to "now": start of today ± DST/day lengths, plus a few
    // days around it, compared against the native implementation for every
    // calendar x timezone combination.
    for (NSString *identifier in identifiers) {
        for (NSString *zoneIdentifier in zones) {
            NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:identifier];
            calendar.timeZone = [NSTimeZone timeZoneWithName:zoneIdentifier];
            if (!calendar) continue;
            NSDate *todayStart = nil; NSTimeInterval todayLength = 0;
            if (![calendar rangeOfUnit:NSCalendarUnitDay startDate:&todayStart interval:&todayLength forDate:now]) continue;
            NSMutableArray *dates = [NSMutableArray array];
            [dates addObject:now];
            [dates addObject:todayStart];
            [dates addObject:[todayStart dateByAddingTimeInterval:-1.0]];
            [dates addObject:[todayStart dateByAddingTimeInterval:todayLength - 1.0]];
            [dates addObject:[todayStart dateByAddingTimeInterval:todayLength]];
            [dates addObject:[todayStart dateByAddingTimeInterval:todayLength + 1.0]];
            for (NSInteger days = -3; days <= 3; days++) {
                if (days == 0) continue;
                NSDateComponents *delta = [[NSDateComponents alloc] init]; delta.day = days;
                NSDate *day = [calendar dateByAddingComponents:delta toDate:todayStart options:0];
                [dates addObject:day];
                [dates addObject:[day dateByAddingTimeInterval:todayLength / 2.0]];
            }
            for (NSDate *date in dates) {
                Check(FBPNSCalendarIsDateInToday(calendar, date) == [calendar isDateInToday:date],
                      @"today mismatch %@/%@ date=%@ native=%d fbp=%d", identifier, zoneIdentifier, date,
                      [calendar isDateInToday:date], FBPNSCalendarIsDateInToday(calendar, date));
                Check(FBPNSCalendarIsDateInYesterday(calendar, date) == [calendar isDateInYesterday:date],
                      @"yesterday mismatch %@/%@ date=%@", identifier, zoneIdentifier, date);
                Check(FBPNSCalendarIsDateInTomorrow(calendar, date) == [calendar isDateInTomorrow:date],
                      @"tomorrow mismatch %@/%@ date=%@", identifier, zoneIdentifier, date);
            }
            // Date pairs across day boundaries and DST transitions.
            for (int iteration = 0; iteration < 60; iteration++) {
                NSDate *a = [dates objectAtIndex:RandomBelow(dates.count)];
                NSDate *b = [dates objectAtIndex:RandomBelow(dates.count)];
                Check(FBPNSCalendarIsDateInSameDay(calendar, a, b) == NativeSameDay(calendar, a, b),
                      @"sameDay mismatch %@/%@ a=%@ b=%@", identifier, zoneIdentifier, a, b);
            }
        }
    }
    // DST transition days explicitly (southern + northern hemisphere).
    NSArray<NSString *> *dstDays = @[ @"2024-04-07T00:30:00Z", @"2024-10-06T00:30:00Z",
                                      @"2025-04-06T00:30:00Z", @"2025-10-05T00:30:00Z",
                                      @"2024-03-10T00:30:00Z", @"2024-11-03T00:30:00Z",
                                      @"2025-03-09T00:30:00Z", @"2025-11-02T00:30:00Z" ];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    formatter.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
    for (NSString *identifier in identifiers) {
        NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:identifier];
        for (NSString *zoneIdentifier in zones) {
            calendar.timeZone = [NSTimeZone timeZoneWithName:zoneIdentifier];
            for (NSString *text in dstDays) {
                NSDate *base = [formatter dateFromString:text];
                for (NSInteger hours = -48; hours <= 48; hours += 6) {
                    NSDate *date = [base dateByAddingTimeInterval:hours * 3600.0];
                    Check(FBPNSCalendarIsDateInSameDay(calendar, date, [date dateByAddingTimeInterval:3600.0])
                          == NativeSameDay(calendar, date, [date dateByAddingTimeInterval:3600.0]),
                          @"DST sameDay mismatch %@/%@ date=%@", identifier, zoneIdentifier, date);
                }
            }
        }
    }
    // nil arguments: FBP is total and returns NO; native may raise.
    NSCalendar *gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    Check(FBPNSCalendarIsDateInToday(gregorian, nil) == NO, @"nil today should be NO");
    Check(FBPNSCalendarIsDateInSameDay(gregorian, nil, now) == NO, @"nil sameDay should be NO");
    for (int i = 0; i < 2; i++) {
        @try { [gregorian isDateInToday:nil]; }
        @catch (NSException *exception) { /* documented native difference: throws */ }
    }
}

// MARK: - Performance

static double Now(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }

static void TestPerformance(void) {
    NSString *sample = @"The quick brown fox jumps over 13 lazy dogs / path?q=hello world&x=é世";
    NSCharacterSet *allowed = NativeURLSet(@selector(URLQueryAllowedCharacterSet));
    NSCalendar *calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
    NSDate *now = [NSDate date];
    NSDate *other = [now dateByAddingTimeInterval:3600.0];
    const int iterations = 200000;
    double t0 = Now();
    for (int i = 0; i < iterations; i++) { (void)FBPNSStringAddingPercentEncoding(sample, allowed); }
    double fbpEncode = (Now() - t0) * 1e9 / iterations;
    NSString *encoded = FBPNSStringAddingPercentEncoding(sample, allowed);
    t0 = Now();
    for (int i = 0; i < iterations; i++) { (void)FBPNSStringRemovingPercentEncoding(encoded); }
    double fbpDecode = (Now() - t0) * 1e9 / iterations;
    t0 = Now();
    for (int i = 0; i < iterations; i++) { (void)[sample stringByAddingPercentEncodingWithAllowedCharacters:allowed]; }
    double nativeEncode = (Now() - t0) * 1e9 / iterations;
    t0 = Now();
    for (int i = 0; i < iterations; i++) { (void)[encoded stringByRemovingPercentEncoding]; }
    double nativeDecode = (Now() - t0) * 1e9 / iterations;
    const int calendarIterations = 100000;
    t0 = Now();
    for (int i = 0; i < calendarIterations; i++) { (void)FBPNSCalendarIsDateInSameDay(calendar, now, other); }
    double fbpSameDay = (Now() - t0) * 1e9 / calendarIterations;
    t0 = Now();
    for (int i = 0; i < calendarIterations; i++) { (void)[calendar isDate:now inSameDayAsDate:other]; }
    double nativeSameDay = (Now() - t0) * 1e9 / calendarIterations;
    t0 = Now();
    for (int i = 0; i < calendarIterations; i++) { (void)FBPNSCalendarIsDateInToday(calendar, now); }
    double fbpToday = (Now() - t0) * 1e9 / calendarIterations;
    t0 = Now();
    for (int i = 0; i < calendarIterations; i++) { (void)[calendar isDateInToday:now]; }
    double nativeToday = (Now() - t0) * 1e9 / calendarIterations;
    NSCharacterSet *fbpSet = FBPURLPathAllowedCharacterSet();
    NSCharacterSet *nativeSet = NativeURLSet(@selector(URLPathAllowedCharacterSet));
    const int membershipIterations = 1000000;
    t0 = Now();
    for (int i = 0; i < membershipIterations; i++) { (void)[fbpSet characterIsMember:(unichar)(i & 0x7F)]; }
    double fbpMembership = (Now() - t0) * 1e9 / membershipIterations;
    t0 = Now();
    for (int i = 0; i < membershipIterations; i++) { (void)[nativeSet characterIsMember:(unichar)(i & 0x7F)]; }
    double nativeMembership = (Now() - t0) * 1e9 / membershipIterations;
    printf("perf: encode fbp=%.1f ns/op native=%.1f ns/op ratio=%.2f\n", fbpEncode, nativeEncode, fbpEncode / nativeEncode);
    printf("perf: decode fbp=%.1f ns/op native=%.1f ns/op ratio=%.2f\n", fbpDecode, nativeDecode, fbpDecode / nativeDecode);
    printf("perf: sameDay fbp=%.1f ns/op native=%.1f ns/op ratio=%.2f\n", fbpSameDay, nativeSameDay, fbpSameDay / nativeSameDay);
    printf("perf: today fbp=%.1f ns/op native=%.1f ns/op ratio=%.2f\n", fbpToday, nativeToday, fbpToday / nativeToday);
    printf("perf: membership fbp=%.2f ns/op native=%.2f ns/op ratio=%.2f\n", fbpMembership, nativeMembership, fbpMembership / nativeMembership);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL concurrencyOnly = argc > 1 && strcmp(argv[1], "--concurrency-only") == 0;
        TestConcurrentFirstUse();
        if (concurrencyOnly) {
            printf("%s: concurrency-only: %d checks, %d failures\n",
                   gFailures == 0 ? "PASS" : "FAIL", gChecks, gFailures);
            return gFailures == 0 ? 0 : 1;
        }
        TestCharacterSets();
        TestInstallerOnlyWhenAbsent();
        TestPercentEncoding();
        TestCalendar();
        TestPerformance();
        printf("%s: %d checks, %d failures\n", gFailures == 0 ? "PASS" : "FAIL", gChecks, gFailures);
        return gFailures == 0 ? 0 : 1;
    }
}
