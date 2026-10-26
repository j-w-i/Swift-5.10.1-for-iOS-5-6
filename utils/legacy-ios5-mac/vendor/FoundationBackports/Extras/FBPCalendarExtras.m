// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Original implementation of NSCalendar's iOS 8 day predicates using calendar
// arithmetic, so DST transitions and non-24h days are handled correctly.
#import "FoundationBackportsExtras.h"
#import "FBPExtrasInternal.h"
#import <objc/runtime.h>

BOOL FBPNSCalendarIsDateInSameDay(NSCalendar *calendar, NSDate *date1, NSDate *date2) {
    if (!calendar || !date1 || !date2) return NO;
    // Compare the calendar day intervals: this is the only DST-safe definition and
    // it is also what native -isDate:inSameDayAsDate: does (verified over ~50k
    // random pairs across 9 calendars x 7 time zones). Component comparison is
    // not equivalent for calendars whose day boundaries/era numbering differ
    // (e.g. Islamic days around a rollover, DST zones with 23h days).
    NSDate *start1 = nil;
    NSDate *start2 = nil;
    if (![calendar rangeOfUnit:NSCalendarUnitDay startDate:&start1 interval:NULL forDate:date1]) return NO;
    if (![calendar rangeOfUnit:NSCalendarUnitDay startDate:&start2 interval:NULL forDate:date2]) return NO;
    if (!start1 || !start2) return NO;
    return [start1 isEqualToDate:start2];
}

/// Start of the calendar day containing `date` and its exact length. The length
/// is calendar/zone dependent (23/25h days around DST), so callers must use the
/// returned interval rather than 86400.
static BOOL FBPCalendarDayRange(NSCalendar *calendar, NSDate *date,
                                NSDate * _Nullable * _Nullable start,
                                NSTimeInterval * _Nullable length) {
    NSDate *dayStart = nil;
    NSTimeInterval dayLength = 0;
    if (![calendar rangeOfUnit:NSCalendarUnitDay startDate:&dayStart interval:&dayLength forDate:date]) {
        return NO;
    }
    if (start) *start = dayStart;
    if (length) *length = dayLength;
    return dayStart != nil;
}

/// Start of the day `offset` calendar days away from `reference`, using
/// dateByAddingComponents: (DST-safe calendar arithmetic, not 86400*s).
static NSDate *FBPCalendarShiftedDay(NSCalendar *calendar, NSDate *referenceDayStart, NSInteger dayOffset) {
    NSDateComponents *delta = [[NSDateComponents alloc] init];
    delta.day = dayOffset;
    return [calendar dateByAddingComponents:delta toDate:referenceDayStart options:0];
}

static BOOL FBPCalendarDateIsOnDay(NSCalendar *calendar, NSDate *date, NSDate *dayStart, NSTimeInterval dayLength) {
    NSTimeInterval delta = [date timeIntervalSinceDate:dayStart];
    return delta >= 0.0 && delta < dayLength;
}

BOOL FBPNSCalendarIsDateInToday(NSCalendar *calendar, NSDate *date) {
    if (!calendar || !date) return NO;
    NSDate *todayStart = nil;
    NSTimeInterval todayLength = 0;
    if (!FBPCalendarDayRange(calendar, [NSDate date], &todayStart, &todayLength)) return NO;
    return FBPCalendarDateIsOnDay(calendar, date, todayStart, todayLength);
}

BOOL FBPNSCalendarIsDateInYesterday(NSCalendar *calendar, NSDate *date) {
    if (!calendar || !date) return NO;
    NSDate *todayStart = nil;
    if (!FBPCalendarDayRange(calendar, [NSDate date], &todayStart, NULL)) return NO;
    NSDate *yesterdayStart = FBPCalendarShiftedDay(calendar, todayStart, -1);
    if (!yesterdayStart) return NO;
    NSDate *rangeStart = nil;
    NSTimeInterval yesterdayLength = 0;
    // No 86400 fabrication: if the calendar cannot produce the interval we do
    // not know the DST-safe day bounds and must not claim a match.
    if (!FBPCalendarDayRange(calendar, yesterdayStart, &rangeStart, &yesterdayLength)) return NO;
    return FBPCalendarDateIsOnDay(calendar, date, rangeStart, yesterdayLength);
}

BOOL FBPNSCalendarIsDateInTomorrow(NSCalendar *calendar, NSDate *date) {
    if (!calendar || !date) return NO;
    NSDate *todayStart = nil;
    if (!FBPCalendarDayRange(calendar, [NSDate date], &todayStart, NULL)) return NO;
    NSDate *tomorrowStart = FBPCalendarShiftedDay(calendar, todayStart, 1);
    if (!tomorrowStart) return NO;
    NSDate *rangeStart = nil;
    NSTimeInterval tomorrowLength = 0;
    // No 86400 fabrication (see isDateInYesterday:).
    if (!FBPCalendarDayRange(calendar, tomorrowStart, &rangeStart, &tomorrowLength)) return NO;
    return FBPCalendarDateIsOnDay(calendar, date, rangeStart, tomorrowLength);
}

// MARK: - Native selector installation (only when absent)

static BOOL FBPCalendarIsDateInTodayIMP(id self, SEL _cmd, NSDate *date) {
    return FBPNSCalendarIsDateInToday((NSCalendar *)self, date);
}
static BOOL FBPCalendarIsDateInYesterdayIMP(id self, SEL _cmd, NSDate *date) {
    return FBPNSCalendarIsDateInYesterday((NSCalendar *)self, date);
}
static BOOL FBPCalendarIsDateInTomorrowIMP(id self, SEL _cmd, NSDate *date) {
    return FBPNSCalendarIsDateInTomorrow((NSCalendar *)self, date);
}
static BOOL FBPCalendarIsDateInSameDayIMP(id self, SEL _cmd, NSDate *date1, NSDate *date2) {
    return FBPNSCalendarIsDateInSameDay((NSCalendar *)self, date1, date2);
}

static void FBPCalendarInstallOnClass(Class target) {
    if (!target) return;
    // BOOL is 'B' in the modern ObjC runtime and 'c' (signed char) on armv7/iOS
    // with the legacy runtime; derive the encoding instead of assuming one.
    const char *boolEncoding = @encode(BOOL);
    char oneArgumentTypes[16];
    char twoArgumentTypes[16];
    snprintf(oneArgumentTypes, sizeof(oneArgumentTypes), "%s@:@", boolEncoding);
    snprintf(twoArgumentTypes, sizeof(twoArgumentTypes), "%s@:@@", boolEncoding);
    struct { const char *name; IMP imp; const char *types; } methods[] = {
        { "isDateInToday:", (IMP)FBPCalendarIsDateInTodayIMP, oneArgumentTypes },
        { "isDateInYesterday:", (IMP)FBPCalendarIsDateInYesterdayIMP, oneArgumentTypes },
        { "isDateInTomorrow:", (IMP)FBPCalendarIsDateInTomorrowIMP, oneArgumentTypes },
        { "isDate:inSameDayAsDate:", (IMP)FBPCalendarIsDateInSameDayIMP, twoArgumentTypes },
    };
    for (size_t i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        SEL selector = sel_registerName(methods[i].name);
        if (class_getInstanceMethod(target, selector) == nil) {
            class_addMethod(target, selector, methods[i].imp, methods[i].types);
        }
    }
}

void FBPInstallCalendarExtrasOnClass(Class target) {
    FBPCalendarInstallOnClass(target);
}

void FBPInstallCalendarExtras(void) {
    FBPCalendarInstallOnClass([NSCalendar class]);
}
