// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Original implementation; no FoundationCompatKit implementation is copied.
//
// Missing-native Foundation APIs needed by an iOS 5 deployment:
//   * NSCalendar -isDateInToday:/-isDateInYesterday:/-isDateInTomorrow:/
//     -isDate:inSameDayAsDate: (iOS 8)
//   * NSString -stringByAddingPercentEncodingWithAllowedCharacters: and
//     -stringByRemovingPercentEncoding (iOS 7)
//   * NSCharacterSet +URL*AllowedCharacterSet (iOS 7)
//
// Implementations live on distinct FBP-named classes/functions so host
// differential tests can call them directly and compare with native Foundation.
// The native-name selectors are installed with class_addMethod only when the
// running OS lacks them.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs every missing native selector (class_addMethod only when absent).
/// Also called from a +load so linking the archive is enough.
FOUNDATION_EXPORT void FBPInstallFoundationExtras(void);

// MARK: - NSCalendar (explicit entry points used by host tests and the overlay)

FOUNDATION_EXPORT BOOL FBPNSCalendarIsDateInToday(NSCalendar *calendar, NSDate *date);
FOUNDATION_EXPORT BOOL FBPNSCalendarIsDateInYesterday(NSCalendar *calendar, NSDate *date);
FOUNDATION_EXPORT BOOL FBPNSCalendarIsDateInTomorrow(NSCalendar *calendar, NSDate *date);
FOUNDATION_EXPORT BOOL FBPNSCalendarIsDateInSameDay(NSCalendar *calendar, NSDate *date1, NSDate *date2);

// MARK: - NSString percent encoding (UTF-8, native signatures)

FOUNDATION_EXPORT NSString * _Nullable FBPNSStringAddingPercentEncoding(NSString *string,
                                                                        NSCharacterSet *allowedCharacters);
FOUNDATION_EXPORT NSString * _Nullable FBPNSStringRemovingPercentEncoding(NSString *string);

// MARK: - NSCharacterSet URL allowed sets (exact native ASCII sets, cached)

FOUNDATION_EXPORT NSCharacterSet *FBPURLUserAllowedCharacterSet(void);
FOUNDATION_EXPORT NSCharacterSet *FBPURLPasswordAllowedCharacterSet(void);
FOUNDATION_EXPORT NSCharacterSet *FBPURLHostAllowedCharacterSet(void);
FOUNDATION_EXPORT NSCharacterSet *FBPURLPathAllowedCharacterSet(void);
FOUNDATION_EXPORT NSCharacterSet *FBPURLQueryAllowedCharacterSet(void);
FOUNDATION_EXPORT NSCharacterSet *FBPURLFragmentAllowedCharacterSet(void);

NS_ASSUME_NONNULL_END
