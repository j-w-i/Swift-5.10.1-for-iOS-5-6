// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
#import "../Core/FoundationBackportsCore.h"
#import <objc/runtime.h>
static NSUInteger checks,failures;
static void Check(BOOL ok,NSString *label) { checks++; if(!ok) { failures++; NSLog(@"FAIL %@",label); } }
static BOOL Equal(id a,id b) { return a==b||[a isEqual:b]; }
int main(void) { @autoreleasepool {
 FBPURLComponents *url=[[FBPURLComponents alloc] initWithString:@"https://example.com/a?x=1&nil&empty="];
 FBPURLQueryItem *item=[[FBPURLQueryItem alloc] initWithName:@"x" value:@"1"];
 FBPISO8601DateFormatter *iso=[[FBPISO8601DateFormatter alloc] init];
 Check([url isKindOfClass:[FBPURLComponents class]],@"URL allocation preserves FBP class identity");
 Check([[url copy] isKindOfClass:[FBPURLComponents class]],@"URL copy preserves FBP class identity");
 Check([item isKindOfClass:[FBPURLQueryItem class]]&&[[item copy] isKindOfClass:[FBPURLQueryItem class]],@"query item allocation/copy FBP identity");
 Check([iso isKindOfClass:[FBPISO8601DateFormatter class]]&&[[iso copy] isKindOfClass:[FBPISO8601DateFormatter class]],@"ISO allocation/copy FBP identity");
 NSURLComponents *native=[NSURLComponents componentsWithString:url.string];
 NSArray *items=url.queryItems,*nativeItems=native.queryItems;
 Check(items.count==nativeItems.count,@"native-backed query item count");
 for(NSUInteger i=0;i<items.count;i++) { Check([items[i] isKindOfClass:[FBPURLQueryItem class]],@"query getter FBP identity"); Check(Equal([items[i] name],[nativeItems[i] name])&&Equal([items[i] value],[nativeItems[i] value]),@"query getter native values"); }
 url.queryItems=@[item]; native.queryItems=@[[NSURLQueryItem queryItemWithName:@"x" value:@"1"]]; Check(Equal(url.string,native.string),@"query setter native output");
 FBPURLComponents *copy=[url copy]; url.path=@"/changed"; Check(Equal(copy.path,@"/a"),@"native-backed copy independent");
 NSURL *base=[NSURL URLWithString:@"https://host/a/b/"]; NSURL *relative=[NSURL URLWithString:@"../leaf?x=1" relativeToURL:base];
 for(NSNumber *resolve in @[@NO,@YES]) { FBPURLComponents *u=[FBPURLComponents componentsWithURL:relative resolvingAgainstBaseURL:resolve.boolValue]; NSURLComponents *n=[NSURLComponents componentsWithURL:relative resolvingAgainstBaseURL:resolve.boolValue]; Check([u isKindOfClass:[FBPURLComponents class]],@"URL factory FBP identity"); Check(Equal(u.string,n.string)&&Equal(u.URL,n.URL)&&Equal([u URLRelativeToURL:base],[n URLRelativeToURL:base]),@"native URL/base initializer semantics"); }
 FBPURLComponents *emptyPort=[FBPURLComponents componentsWithString:@"https://host:/a"],*absentPort=[FBPURLComponents componentsWithString:@"https://host/a"];
 Check([emptyPort isEqual:absentPort]&&emptyPort.hash==absentPort.hash,@"native-backed equality empty port");
 for(NSString *scheme in @[@"https",@"x+1",@"",@"https:",@"https://host",@"x?y",@"1x"]) { BOOL bt=NO,nt=NO; @try { url.scheme=scheme; } @catch(NSException *e) { bt=YES; } @try { native.scheme=scheme; } @catch(NSException *e) { nt=YES; } Check(bt==nt,@"native-backed scheme validation"); }
 NSISO8601DateFormatter *ni=[NSISO8601DateFormatter new]; NSDate *date=[NSDate dateWithTimeIntervalSince1970:1709251199.125];
 for(NSNumber *o in @[@(FBPISOInternetDateTime),@(FBPISOInternetDateTime|FBPISOFraction),@(FBPISOFullDate),@(FBPISOFullTime)]) {
  iso.formatOptions=o.unsignedIntegerValue; ni.formatOptions=o.unsignedIntegerValue; iso.timeZone=ni.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:19800];
  NSString *s=[ni stringFromDate:date]; Check(Equal([iso stringFromDate:date],s),@"native-backed ISO formatting"); Check(Equal([iso dateFromString:s],[ni dateFromString:s]),@"native-backed ISO parsing"); Check(Equal([iso stringForObjectValue:date],[ni stringForObjectValue:date]),@"NSFormatter native-backed rendering");
 }
 id parsed=nil; NSString *error=nil; Check([iso getObjectValue:&parsed forString:[ni stringFromDate:date] errorDescription:&error]&&Equal(parsed,[ni dateFromString:[ni stringFromDate:date]]),@"NSFormatter native-backed parsing");
 NSData *archive=[NSKeyedArchiver archivedDataWithRootObject:iso]; id decoded=[NSKeyedUnarchiver unarchiveObjectWithData:archive]; Check([decoded isKindOfClass:[FBPISO8601DateFormatter class]]&&Equal([decoded stringFromDate:date],[iso stringFromDate:date]),@"native-backed ISO coding FBP identity/output");
 archive=[NSKeyedArchiver archivedDataWithRootObject:item]; decoded=[NSKeyedUnarchiver unarchiveObjectWithData:archive]; Check([decoded isKindOfClass:[FBPURLQueryItem class]]&&Equal(decoded,item),@"query coding FBP identity");
 __block BOOL called=NO; NSTimer *timer=[NSTimer timerWithTimeInterval:100 repeats:NO block:^(NSTimer *t){called=YES;}]; [timer fire]; [timer invalidate]; Check(called,@"native timer remains functional");
 printf("Core native-backed identity/semantics: %lu checks, %lu failures\n",(unsigned long)checks,(unsigned long)failures); return failures?1:0;
} }
