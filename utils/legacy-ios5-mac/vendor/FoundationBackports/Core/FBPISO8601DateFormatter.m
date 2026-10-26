// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
#import "FoundationBackportsCore.h"
#import <objc/runtime.h>
// Dynamic messages avoid a strong link to the iOS 10 class while retaining
// correctly typed integer options and identity-preserving FBP allocations.
@protocol FBPISONative <NSObject>
@property(copy) NSTimeZone *timeZone;
@property NSUInteger formatOptions;
- (NSString *)stringFromDate:(NSDate *)date;
- (NSDate *)dateFromString:(NSString *)string;
@end
@implementation FBPISO8601DateFormatter {
 id<FBPISONative> _native;
 BOOL _nativeDirty;
 NSDateFormatter *_formatter;
 NSTimeZone *_timeZone;
 FBPISO8601DateFormatOptions _formatOptions;
}
@synthesize timeZone=_timeZone, formatOptions=_formatOptions;
+ (void)load { if(!objc_getClass("NSISO8601DateFormatter")) { Class c=objc_allocateClassPair(self,"NSISO8601DateFormatter",0); if(c) objc_registerClassPair(c); } }
+ (BOOL)supportsSecureCoding { return YES; }
- (NSTimeZone *)timeZone { @synchronized(self) { return _timeZone; } }
- (FBPISO8601DateFormatOptions)formatOptions { @synchronized(self) { return _formatOptions; } }
- (instancetype)init { if((self=[super init])) {
 _timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0]; _formatOptions=FBPISOInternetDateTime; _nativeDirty=YES;
#if !FBP_FORCE_TEST_RUNTIME
 Class native=objc_getClass("NSISO8601DateFormatter");
 if(native&&![native isSubclassOfClass:[FBPISO8601DateFormatter class]]) _native=[[native alloc] init];
#endif
 } return self; }
// Called under the same lock as fallback formatter access. iOS 10 silently
// ignores the fraction bit; keep using the fallback for that layout there.
- (id<FBPISONative>)nativeFormatter {
 if(_formatOptions&FBPISOWeek) [NSException raise:NSInvalidArgumentException format:@"ISO week layouts are not backported"];
 if(!_native) return nil;
 if(_formatOptions&FBPISOFraction) { if(@available(iOS 11.0, macOS 10.13, *)) {} else return nil; }
 if(_nativeDirty) { _native.timeZone=_timeZone; _native.formatOptions=_formatOptions; _nativeDirty=NO; } return _native;
}
- (void)setTimeZone:(NSTimeZone *)tz { @synchronized(self) { _timeZone=[tz copy]; _formatter=nil; _nativeDirty=YES; } }
- (void)setFormatOptions:(FBPISO8601DateFormatOptions)o { @synchronized(self) { _formatOptions=o; _formatter=nil; _nativeDirty=YES; } }
- (NSDateFormatter *)formatter {
 if(_formatter) return _formatter;
 NSUInteger o=_formatOptions;
 // Week/ordinal and partial-component layouts are deliberately not advertised by
 // the importer until their ICU-version-dependent behavior is qualified.
 if(o&FBPISOWeek) [NSException raise:NSInvalidArgumentException format:@"ISO week layouts are not backported"];
 NSMutableArray *date=[NSMutableArray array];
 if(o&FBPISOYear) [date addObject:@"yyyy"];
 if(o&FBPISOMonth) [date addObject:@"MM"];
 if(o&FBPISODay) [date addObject:(o&FBPISOMonth)?@"dd":@"DDD"];
 NSMutableString *pattern=[[date componentsJoinedByString:(o&FBPISODash)?@"-":@""] mutableCopy];
 if(o&FBPISOTime) { if(pattern.length) [pattern appendString:(o&FBPISOSpace)?@"' '":@"'T'"]; [pattern appendString:(o&FBPISOColon)?@"HH:mm:ss":@"HHmmss"]; if(o&FBPISOFraction) [pattern appendString:@".SSS"]; }
 // XXXXX isn't present in every iOS5 ICU. ZZZZZ is also newer. Render/parse
 // timezone manually using a fixed numeric suffix, leaving date ICU portable.
 _formatter=[[NSDateFormatter alloc] init];
 _formatter.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
 _formatter.calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar];
 _formatter.timeZone=_timeZone?:[NSTimeZone timeZoneForSecondsFromGMT:0];
 _formatter.lenient=NO; _formatter.dateFormat=pattern;
 return _formatter;
}
- (NSString *)stringFromDate:(NSDate *)date { if(!date) return nil; @synchronized(self) {
 id<FBPISONative> native=[self nativeFormatter]; if(native) return [native stringFromDate:date];
 NSString *s=[[self formatter] stringFromDate:date]; if(!(_formatOptions&FBPISOTimeZone)) return s;
 NSInteger offset=[(_timeZone?:[NSTimeZone timeZoneForSecondsFromGMT:0]) secondsFromGMTForDate:date]; if(!offset) return [s stringByAppendingString:@"Z"];
 NSInteger magnitude=labs(offset); return [s stringByAppendingFormat:(_formatOptions&FBPISOTZColon)?@"%c%02ld:%02ld":@"%c%02ld%02ld",offset<0?'-':'+',(long)(magnitude/3600),(long)((magnitude/60)%60)];
} }
- (NSDate *)dateFromString:(NSString *)string { if(!string) return nil; @synchronized(self) {
 id<FBPISONative> native=[self nativeFormatter]; if(native) return [native dateFromString:string];
 NSDateFormatter *f=[self formatter]; NSInteger numericOffset=0; BOOL hasNumericOffset=NO; NSString *body=string; NSTimeZone *zone=_timeZone?:[NSTimeZone timeZoneForSecondsFromGMT:0];
 if(_formatOptions&FBPISOTimeZone) {
  // Native consumes the timezone prefix, not the entire input.
  NSUInteger start=0;
  if(_formatOptions&FBPISOTime) {
   if(_formatOptions&(FBPISOYear|FBPISOMonth|FBPISODay)) { NSRange sep=[body rangeOfString:(_formatOptions&FBPISOSpace)?@" ":@"T" options:NSCaseInsensitiveSearch]; if(sep.location==NSNotFound) return nil; start=sep.location+1; }
   while(start<body.length) { unichar c=[body characterAtIndex:start]; if(!((c>='0'&&c<='9')||c==':'||c=='.'||c==',')) break; start++; }
  } else start=(_formatOptions&FBPISODash)?10:8;
  NSUInteger endOfBody=start;
  while(start<body.length&&[[NSCharacterSet whitespaceCharacterSet] characterIsMember:[body characterAtIndex:start]]) start++;
  if(start>=body.length) return nil;
  NSString *suffix=[body substringFromIndex:start]; unichar sign=[suffix characterAtIndex:0];
  if(sign=='Z'||sign=='z'||[suffix hasPrefix:@"GMT"]||[suffix hasPrefix:@"UTC"]) zone=[NSTimeZone timeZoneForSecondsFromGMT:0];
  else {
   if(sign!='+'&&sign!='-') return nil;
   NSUInteger i=1,hd=0; NSInteger h=0,m=0;
   while(i<suffix.length&&hd<2&&[suffix characterAtIndex:i]>='0'&&[suffix characterAtIndex:i]<='9') { h=h*10+[suffix characterAtIndex:i++]-'0'; hd++; }
   if(!hd) return nil;
   BOOL hourFallback=h>23; if(hourFallback) { h/=10; i--; }
   if(i<suffix.length&&[suffix characterAtIndex:i]==':') i++;
   NSUInteger md=0; while(i<suffix.length&&md<2&&[suffix characterAtIndex:i]>='0'&&[suffix characterAtIndex:i]<='9') { m=m*10+[suffix characterAtIndex:i++]-'0'; md++; }
   if(m>59||hourFallback) m=0;
   numericOffset=(sign=='-'?-1:1)*(h*3600+m*60); hasNumericOffset=YES;
   zone=[NSTimeZone timeZoneForSecondsFromGMT:0];
  }
  body=[body substringToIndex:endOfBody];
 }
 f.timeZone=zone;
 NSDate *d=[f dateFromString:body];
 // Native normalizes day overflow (e.g. February 30) but rejects month 13 and
 // hour 25. ICU's nonlenient formatter rejects all three. Retry only a valid
 // numeric calendar envelope, never a malformed string.
 if(!d&&(_formatOptions&FBPISOFullDate)==FBPISOFullDate&&body.length>=10) {
  NSInteger month=[[body substringWithRange:NSMakeRange(5,2)] integerValue],day=[[body substringWithRange:NSMakeRange(8,2)] integerValue];
  BOOL envelope=month>=1&&month<=12&&day>=1&&day<=31;
  if((_formatOptions&FBPISOTime)&&body.length>=19) envelope=envelope&&[[body substringWithRange:NSMakeRange(11,2)] integerValue]<=23&&[[body substringWithRange:NSMakeRange(14,2)] integerValue]<=59&&[[body substringWithRange:NSMakeRange(17,2)] integerValue]<=59;
  if(envelope) { f.lenient=YES; d=[f dateFromString:body]; f.lenient=NO; }
 }
 // Like native ISO parsing, ICU may normalize an out-of-range day within a
 // valid month. Do not impose a stricter canonical round-trip than Foundation.
 if(d&&hasNumericOffset) d=[d dateByAddingTimeInterval:-numericOffset];
  f.timeZone=_timeZone?:[NSTimeZone timeZoneForSecondsFromGMT:0]; return d;
} }
+ (NSString *)stringFromDate:(NSDate *)date timeZone:(NSTimeZone *)tz formatOptions:(FBPISO8601DateFormatOptions)o { FBPISO8601DateFormatter *f=[[self alloc] init]; f.timeZone=tz; f.formatOptions=o; return [f stringFromDate:date]; }
- (NSString *)stringForObjectValue:(id)o { return [o isKindOfClass:[NSDate class]]?[self stringFromDate:o]:nil; }
- (BOOL)getObjectValue:(out id *)obj forString:(NSString *)s errorDescription:(out NSString **)error { NSDate *d=[self dateFromString:s]; if(obj) *obj=d; if(!d&&error) *error=@"Invalid ISO 8601 date"; return d!=nil; }
- (instancetype)initWithCoder:(NSCoder *)c { if((self=[self init])) { id tz; if(@available(iOS 6.0,*)) tz=[c decodeObjectOfClass:[NSTimeZone class] forKey:@"timeZone"]; else tz=[c decodeObjectForKey:@"timeZone"]; if(tz&&![tz isKindOfClass:[NSTimeZone class]]) [NSException raise:NSInvalidUnarchiveOperationException format:@"Invalid time zone"]; self.timeZone=tz; self.formatOptions=(NSUInteger)[c decodeInt64ForKey:@"formatOptions"]; } return self; }
- (void)encodeWithCoder:(NSCoder *)c { [c encodeObject:_timeZone forKey:@"timeZone"]; [c encodeInt64:(int64_t)_formatOptions forKey:@"formatOptions"]; }
- (id)copyWithZone:(NSZone *)zone { FBPISO8601DateFormatter *f=[[[self class] allocWithZone:zone] init]; f.timeZone=self.timeZone; f.formatOptions=self.formatOptions; return f; }
@end
