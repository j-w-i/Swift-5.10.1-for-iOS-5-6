// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
// Original implementation; no FoundationCompatKit implementation is copied.
#import <Foundation/Foundation.h>

// Implementations keep distinct names so host differential tests never call native
// code accidentally. +load installs native-name subclasses only when absent.
@interface FBPURLQueryItem : NSObject <NSCopying, NSSecureCoding>
- (instancetype)initWithName:(NSString *)name value:(NSString *)value;
+ (instancetype)queryItemWithName:(NSString *)name value:(NSString *)value;
@property(readonly, copy) NSString *name;
@property(readonly, copy) NSString *value;
@end

@interface FBPURLComponents : NSObject <NSCopying>
+ (instancetype)componentsWithString:(NSString *)string;
+ (instancetype)componentsWithURL:(NSURL *)url resolvingAgainstBaseURL:(BOOL)resolve;
- (instancetype)initWithString:(NSString *)string;
- (instancetype)initWithURL:(NSURL *)url resolvingAgainstBaseURL:(BOOL)resolve;
@property(nonatomic, copy) NSString *scheme;
@property(nonatomic, copy) NSString *user;
@property(nonatomic, copy) NSString *password;
@property(nonatomic, copy) NSString *host;
@property(nonatomic, copy) NSNumber *port;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, copy) NSString *query;
@property(nonatomic, copy) NSString *fragment;
@property(nonatomic, copy) NSString *percentEncodedUser;
@property(nonatomic, copy) NSString *percentEncodedPassword;
@property(nonatomic, copy) NSString *percentEncodedHost;
@property(nonatomic, copy) NSString *percentEncodedPath;
@property(nonatomic, copy) NSString *percentEncodedQuery;
@property(nonatomic, copy) NSString *percentEncodedFragment;
@property(nonatomic, copy) NSArray *queryItems;
@property(readonly, copy) NSString *string;
@property(readonly, copy) NSURL *URL;
- (NSURL *)URLRelativeToURL:(NSURL *)baseURL;
@end

// Native NSISO8601DateFormatOptions values (NSUInteger, not the prototype's Int).
typedef NS_OPTIONS(NSUInteger, FBPISO8601DateFormatOptions) {
 FBPISOYear=1UL<<0, FBPISOMonth=1UL<<1, FBPISOWeek=1UL<<2,
 FBPISODay=1UL<<4, FBPISOTime=1UL<<5, FBPISOTimeZone=1UL<<6,
 FBPISOSpace=1UL<<7, FBPISODash=1UL<<8, FBPISOColon=1UL<<9,
 FBPISOTZColon=1UL<<10, FBPISOFraction=1UL<<11,
 FBPISOFullDate=FBPISOYear|FBPISOMonth|FBPISODay|FBPISODash,
 FBPISOFullTime=FBPISOTime|FBPISOTimeZone|FBPISOColon|FBPISOTZColon,
 FBPISOInternetDateTime=FBPISOFullDate|FBPISOFullTime
};
@interface FBPISO8601DateFormatter : NSFormatter <NSSecureCoding>
@property(nonatomic, copy) NSTimeZone *timeZone;
@property FBPISO8601DateFormatOptions formatOptions;
- (NSString *)stringFromDate:(NSDate *)date;
- (NSDate *)dateFromString:(NSString *)string;
+ (NSString *)stringFromDate:(NSDate *)date timeZone:(NSTimeZone *)timeZone formatOptions:(FBPISO8601DateFormatOptions)options;
@end

// Explicit entry points also let host tests exercise the missing-selector IMPs.
FOUNDATION_EXPORT NSTimer *FBPTimerWithTimeInterval(NSTimeInterval interval, BOOL repeats, void (^block)(NSTimer *));
FOUNDATION_EXPORT NSTimer *FBPScheduledTimerWithTimeInterval(NSTimeInterval interval, BOOL repeats, void (^block)(NSTimer *));
FOUNDATION_EXPORT NSTimer *FBPTimerWithFireDate(NSDate *date, NSTimeInterval interval, BOOL repeats, void (^block)(NSTimer *));
