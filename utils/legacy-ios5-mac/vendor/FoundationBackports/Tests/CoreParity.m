// Copyright (c) 2026 FoundationBackports contributors. SPDX-License-Identifier: MIT
#import "../Core/FoundationBackportsCore.h"
#import <objc/runtime.h>
#import <mach/mach_time.h>
static NSUInteger checks,failures;
static void Check(BOOL ok, NSString *message) { checks++; if(!ok) { failures++; NSLog(@"FAIL %@",message); } }
static BOOL Equal(id a,id b) { return a==b||[a isEqual:b]; }
static void URLTests(void) {
 NSArray *inputs=@[@"https://user:pass@example.com:8443/a%2Fb?q=a%26b&nil&empty=&eq=x=y#f%23g",@"../a?x=+&x=%2B",@"mailto:a@example.com",@"http://[::1]:8080/a",@"https://example.com?",@"https://example.com#",@"",@"//host/path",@"a/b:c",@"http://host/a%20b",@"http://host/?&&a=&=b",@"https://example.com/a b?x=hello world#☃",@"https://user%40name:p%3Ass@example.com/a%2fb",@"file:///a/b",@"http://host:65536/",@"http://host:/",@"https://☃.net/",@"http://[2001:db8::1]/",@"/a//b/../",@"?#"];
 NSArray *keys=@[@"scheme",@"user",@"password",@"host",@"port",@"path",@"query",@"fragment",@"percentEncodedUser",@"percentEncodedPassword",@"percentEncodedHost",@"percentEncodedPath",@"percentEncodedQuery",@"percentEncodedFragment",@"string"];
 for(NSString *s in inputs) { FBPURLComponents *b=[FBPURLComponents componentsWithString:s]; NSURLComponents *n=[NSURLComponents componentsWithString:s];
  Check((b!=nil)==(n!=nil),[NSString stringWithFormat:@"URL accepted %@",s]);
  for(NSString *key in keys) Check(Equal([b valueForKey:key],[n valueForKey:key]),[NSString stringWithFormat:@"URL %@ %@ back=%@ native=%@",s,key,[b valueForKey:key],[n valueForKey:key]]);
  NSArray *bi=b.queryItems,*ni=n.queryItems; Check((bi==nil)==(ni==nil)&&bi.count==ni.count,@"query count");
  for(NSUInteger i=0;i<MIN(bi.count,ni.count);i++) { Check(Equal([bi[i] name],[ni[i] name]),@"query name"); Check(Equal([bi[i] value],[ni[i] value]),@"query value"); }
 }
 FBPURLComponents *b=[FBPURLComponents new]; NSURLComponents *n=[NSURLComponents new];
 NSArray *names=@[@"a&b",@"equal=name",@"plus+ space",@"unicode☃",@"nil",@"empty"];
 NSMutableArray *bi=[NSMutableArray array],*ni=[NSMutableArray array];
 for(NSString *name in names) { NSString *v=[name isEqual:@"nil"]?nil:([name isEqual:@"empty"]?@"":@"a=b&c+d /?☃"); [bi addObject:[FBPURLQueryItem queryItemWithName:name value:v]]; [ni addObject:[NSURLQueryItem queryItemWithName:name value:v]]; }
 b.queryItems=bi; n.queryItems=ni; Check(Equal(b.string,n.string),[NSString stringWithFormat:@"query encode back=%@ native=%@",b.string,n.string]);
 b.queryItems=@[]; n.queryItems=@[]; Check(Equal(b.string,n.string),@"empty query array");
 NSURL *relative=[NSURL URLWithString:@"../leaf?x=1" relativeToURL:[NSURL URLWithString:@"https://example.com/a/b/"]];
 for(NSNumber *resolve in @[@NO,@YES]) { FBPURLComponents *bc=[FBPURLComponents componentsWithURL:relative resolvingAgainstBaseURL:resolve.boolValue]; NSURLComponents *nc=[NSURLComponents componentsWithURL:relative resolvingAgainstBaseURL:resolve.boolValue]; Check(Equal(bc.string,nc.string),@"base resolution"); }
 unichar raw[]={ '/', 'a', 0, 'b' }; NSString *nul=[NSString stringWithCharacters:raw length:4]; b=[FBPURLComponents new];n=[NSURLComponents new];b.path=nul;n.path=nul;Check(Equal(b.percentEncodedPath,n.percentEncodedPath),@"NUL path encoding");
 unichar surrogate[]={0xD800}; NSString *invalid=[NSString stringWithCharacters:surrogate length:1];
#if FBP_FORCE_TEST_RUNTIME
 Check([FBPURLComponents componentsWithString:invalid]==nil,@"fallback invalid Unicode URL rejected");
#else
 Check(Equal([FBPURLComponents componentsWithString:invalid].string,[NSURLComponents componentsWithString:invalid].string),@"native-backed invalid Unicode follows native");
#endif
 for(NSString *p in @[@"2147483647",@"2147483648",@"9223372036854775807"]) { NSString *s=[NSString stringWithFormat:@"http://host:%@/",p]; FBPURLComponents *bc=[FBPURLComponents componentsWithString:s]; NSURLComponents *nc=[NSURLComponents componentsWithString:s]; Check(Equal(bc.port,nc.port),@"high port"); }
 b.host=@"example.com"; b.path=@"relative"; Check(b.string==nil,@"authority requires absolute path");
}
static void URLReviewTests(void) {
 FBPURLComponents *b=[FBPURLComponents new]; NSURLComponents *n=[NSURLComponents new];
 for(NSString *scheme in @[@"https",@"x+1",@"",@"https:",@"https://host",@"https://host/path?x",@"x?y",@"1x",@"é"]) {
  BOOL bt=NO,nt=NO; @try { b.scheme=scheme; } @catch(NSException *e) { bt=YES; }
  @try { n.scheme=scheme; } @catch(NSException *e) { nt=YES; }
  Check(bt==nt,[NSString stringWithFormat:@"scheme validation %@",scheme]);
  Check(Equal(b.scheme,n.scheme),@"invalid scheme leaves old value unchanged");
 }
 b.scheme=nil; n.scheme=nil; Check(Equal(b.scheme,n.scheme),@"nil clears scheme");
 NSArray *inputs=@[@"https://host/a",@"https://host/%61",@"https://HOST/a",@"HTTPS://host/a",@"https://host:/a",@"https://host:80/a",@"https://host:080/a",@"https://host/a?x=%2f",@"https://host/a?x=%2F",@"https://u:p@host/a",@"https://%75:p@host/a",@"https://host/a?",@"https://host/a#",@""];
 for(NSString *left in inputs) for(NSString *right in inputs) {
  FBPURLComponents *x=[FBPURLComponents componentsWithString:left],*y=[FBPURLComponents componentsWithString:right];
  NSURLComponents *nx=[NSURLComponents componentsWithString:left],*ny=[NSURLComponents componentsWithString:right];
  Check([x isEqual:y]==[nx isEqual:ny],[NSString stringWithFormat:@"component equality %@ / %@",left,right]);
  if([x isEqual:y]) Check(x.hash==y.hash,@"equal component hashes");
 }
}
static void ISOTests(void) {
 NSArray *opts=@[@(FBPISOInternetDateTime),@(FBPISOInternetDateTime|FBPISOFraction),@(FBPISOFullDate),@(FBPISOFullTime),@(FBPISOInternetDateTime|FBPISOSpace),@(FBPISOYear|FBPISOMonth|FBPISODay|FBPISOTime|FBPISOTimeZone)];
 NSArray *zones=@[[NSTimeZone timeZoneForSecondsFromGMT:0],[NSTimeZone timeZoneForSecondsFromGMT:19800],[NSTimeZone timeZoneForSecondsFromGMT:-25200]];
 NSArray *dates=@[[NSDate dateWithTimeIntervalSince1970:0],[NSDate dateWithTimeIntervalSince1970:1709251199.125],[NSDate dateWithTimeIntervalSince1970:-1]];
 for(NSNumber *o in opts) for(NSTimeZone *z in zones) { FBPISO8601DateFormatter *b=[FBPISO8601DateFormatter new]; NSISO8601DateFormatter *n=[NSISO8601DateFormatter new]; b.formatOptions=o.unsignedIntegerValue; n.formatOptions=o.unsignedIntegerValue; b.timeZone=z;n.timeZone=z;
  for(NSDate *d in dates) { NSString *bs=[b stringFromDate:d],*ns=[n stringFromDate:d]; Check(Equal(bs,ns),[NSString stringWithFormat:@"ISO format %lu %@ back=%@ native=%@",(unsigned long)o.unsignedIntegerValue,z,bs,ns]); NSDate *bd=[b dateFromString:ns],*nd=[n dateFromString:ns]; Check((!bd&&!nd)||(bd&&nd&&fabs([bd timeIntervalSinceDate:nd])<0.001),[NSString stringWithFormat:@"ISO parse %@ back=%@ native=%@",ns,bd,nd]); }
 }
 FBPISO8601DateFormatter *b=[FBPISO8601DateFormatter new]; Check([b dateFromString:@"not a date"]==nil,@"invalid date");
 NSISO8601DateFormatter *n=[NSISO8601DateFormatter new]; Check((NSUInteger)b.formatOptions==(NSUInteger)n.formatOptions,@"native default option bits");
 Check(Equal(b.timeZone,n.timeZone),@"default UTC");
 for(NSString *s in @[@"2024-02-29T23:59:59+0000",@"2024-02-29T23:59:59+00:00",@"2024-02-29T23:59:59Zjunk",@"2024-02-29T23:59:59z",@"2024-02-29T23:59:59",@"2024-02-29T23:59:59+05:30junk",@"2024-02-29T23:59:59+5",@"2024-02-29T23:59:59+05",@"2024-02-29T23:59:59+24:00",@"2024-02-29T23:59:59+23:60",@"2024-02-29T23:59:59GMT",@"2024-02-29T23:59:59UTC",@"2024-02-29T23:59:59 Z",@"2024-02-29T23:59:59junkZ",@"2024-02-29T23:59:59+00:0",@"2024-02-29T23:59:59+0:00"]) { NSDate *bd=[b dateFromString:s],*nd=[n dateFromString:s]; BOOL same=(!bd&&!nd)||(bd&&nd&&fabs([bd timeIntervalSinceDate:nd])<0.001); Check(same,[NSString stringWithFormat:@"ISO timezone prefix %@",s]); printf("ISO parser edge differential %s: backport %s native %s %s\n",s.UTF8String,bd?"accept":"reject",nd?"accept":"reject",same?"MATCH":"LIMITATION"); }

 for(NSString *s in @[@"2024-02-29T23:59:59+05:30",@"2024-02-29T23:59:59-07:00",@"2024-02-29T23:59:59Z",@"2023-02-29T12:00:00Z",@"2024-02-30T12:00:00Z",@"2024-13-01T12:00:00Z",@"2024-01-01T25:00:00Z"]) { NSDate *bd=[b dateFromString:s],*nd=[n dateFromString:s]; Check((!bd&&!nd)||(bd&&nd&&fabs([bd timeIntervalSinceDate:nd])<0.001),[NSString stringWithFormat:@"ISO explicit input %@ back=%@ native=%@",s,bd,nd]); }
}
@interface NSTimer (FBPTestSelectors)
+ (NSTimer *)fbp_timerWithTimeInterval:(NSTimeInterval)t repeats:(BOOL)r block:(void (^)(NSTimer *))b;
+ (NSTimer *)fbp_scheduledTimerWithTimeInterval:(NSTimeInterval)t repeats:(BOOL)r block:(void (^)(NSTimer *))b;
- (instancetype)initFBPWithFireDate:(NSDate *)date interval:(NSTimeInterval)t repeats:(BOOL)r block:(void (^)(NSTimer *))b;
@end
static void ValueSemanticsTests(void) {
 FBPISO8601DateFormatter *b=[FBPISO8601DateFormatter new]; NSISO8601DateFormatter *n=[NSISO8601DateFormatter new]; NSDate *d=[NSDate dateWithTimeIntervalSince1970:1709251199];
 Check(Equal([b stringForObjectValue:d],[n stringForObjectValue:d]),@"NSFormatter date rendering"); Check(Equal([b stringForObjectValue:@"bad"],[n stringForObjectValue:@"bad"]),@"NSFormatter rejects nondate");
 id bo=nil,no=nil; NSString *be=nil,*ne=nil; BOOL bok=[b getObjectValue:&bo forString:@"2024-02-29T23:59:59Z" errorDescription:&be],nok=[n getObjectValue:&no forString:@"2024-02-29T23:59:59Z" errorDescription:&ne]; Check(bok==nok&&Equal(bo,no),@"NSFormatter object parsing");
 FBPISO8601DateFormatter *copy=[b copy]; b.formatOptions=FBPISOFullDate; Check(copy.formatOptions==FBPISOInternetDateTime,@"ISO copy independent");
 NSData *data=[NSKeyedArchiver archivedDataWithRootObject:copy]; FBPISO8601DateFormatter *decoded=[NSKeyedUnarchiver unarchiveObjectWithData:data]; Check(Equal([decoded stringFromDate:d],[copy stringFromDate:d]),@"ISO coding roundtrip");
 FBPURLQueryItem *item=[FBPURLQueryItem queryItemWithName:@"name" value:@"value"]; Check(Equal(item,[item copy]),@"query immutable copy"); data=[NSKeyedArchiver archivedDataWithRootObject:item]; Check(Equal(item,[NSKeyedUnarchiver unarchiveObjectWithData:data]),@"query coding roundtrip");
 FBPURLComponents *c=[FBPURLComponents componentsWithString:@"https://u:p@host:/a?x=1#f"]; FBPURLComponents *cc=[c copy]; c.path=@"/b"; Check(Equal(cc.string,@"https://u:p@host:/a?x=1#f"),@"components copy independent");
}
static void TimerTests(void) {
#if FBP_FORCE_TEST_RUNTIME
 __block NSUInteger impCalls=0;
 NSTimer *installed=[NSTimer fbp_timerWithTimeInterval:100 repeats:NO block:^(NSTimer *t){ impCalls++; }]; [installed fire]; [installed invalidate]; Check(impCalls==1,@"installed class factory IMP");
 NSTimer *initialized=[[NSTimer alloc] initFBPWithFireDate:[NSDate date] interval:100 repeats:NO block:^(NSTimer *t){ impCalls++; }]; [initialized fire]; [initialized invalidate]; Check(impCalls==2,@"installed initializer IMP");
#endif
 __block BOOL nativeCalled=NO; NSTimer *native=[NSTimer timerWithTimeInterval:100 repeats:NO block:^(NSTimer *t){nativeCalled=YES;}]; Check(native.userInfo==nil,@"native timer userInfo"); [native fire]; Check(nativeCalled,@"native timer counterpart"); [native invalidate];
#if FBP_FORCE_TEST_RUNTIME
 Check(method_getImplementation(class_getClassMethod([NSTimer class],@selector(timerWithTimeInterval:repeats:block:)))!=method_getImplementation(class_getClassMethod([NSTimer class],@selector(fbp_timerWithTimeInterval:repeats:block:))),@"native timer IMP not replaced");
#endif
 __block NSUInteger called=0; __block NSTimer *received=nil;
 NSTimer *timer=FBPTimerWithTimeInterval(100,NO,^(NSTimer *t){ called++; received=t; });
 Check(timer.userInfo==nil,@"timer userInfo native nil"); [timer fire]; Check(called==1&&received==timer,@"timer block receives timer"); [timer invalidate]; Check(!timer.valid,@"timer invalidates");
 __block NSUInteger repeating=0; NSTimer *repeat=FBPTimerWithTimeInterval(100,YES,^(NSTimer *t){ repeating++; }); [repeat fire];[repeat fire];Check(repeating==2&&repeat.valid,@"repeating timer");[repeat invalidate];
 __block BOOL fired=NO; NSTimer *scheduled=FBPScheduledTimerWithTimeInterval(0.001,NO,^(NSTimer *t){fired=YES;}); [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]]; Check(fired&&!scheduled.valid,@"scheduled default runloop timer");
}
static double Benchmark(void (^block)(void),NSUInteger count) { uint64_t start=mach_absolute_time(); for(NSUInteger i=0;i<count;i++) @autoreleasepool { block(); } uint64_t end=mach_absolute_time(); mach_timebase_info_data_t info; mach_timebase_info(&info); return ((double)(end-start)*info.numer/info.denom)/(1e6); }
static double MedianBenchmark(void (^block)(void),NSUInteger count) { double times[5]; for(NSUInteger i=0;i<5;i++) times[i]=Benchmark(block,count); for(NSUInteger i=0;i<5;i++) for(NSUInteger j=i+1;j<5;j++) if(times[j]<times[i]) {double t=times[i];times[i]=times[j];times[j]=t;} return times[2]; }
static void Perf(void) {
 NSUInteger count=10000; NSString *s=@"https://user:password@example.com:443/a%20path?q=a%26b&x=2#frag";
 double bp=MedianBenchmark(^{ FBPURLComponents *c=[FBPURLComponents componentsWithString:s]; (void)c.queryItems; (void)c.string; },count);
 double native=MedianBenchmark(^{ NSURLComponents *c=[NSURLComponents componentsWithString:s]; (void)c.queryItems; (void)c.string; },count);
 printf("URL parse+query+serialize median of 5 x %lu iterations: backport %.3f ms native %.3f ms ratio %.3f\n",(unsigned long)count,bp,native,bp/native);
 double parse=MedianBenchmark(^{ (void)[FBPURLComponents componentsWithString:s]; },count); FBPURLComponents *component=[FBPURLComponents componentsWithString:s];
 double query=MedianBenchmark(^{ (void)component.queryItems; },count),serialize=MedianBenchmark(^{ (void)component.string; },count);
 printf("URL stage profile median of 5 x %lu: parse-only %.3f ms query-get %.3f ms serialize-get %.3f ms (independent workloads)\n",(unsigned long)count,parse,query,serialize);
 FBPISO8601DateFormatter *b=[FBPISO8601DateFormatter new]; NSISO8601DateFormatter *n=[NSISO8601DateFormatter new]; NSDate *d=[NSDate dateWithTimeIntervalSince1970:1709251199]; (void)[b stringFromDate:d];(void)[n stringFromDate:d];
 bp=MedianBenchmark(^{ (void)[b stringFromDate:d]; },count); native=MedianBenchmark(^{ (void)[n stringFromDate:d]; },count);
 printf("ISO cached formatting median of 5 x %lu iterations: backport %.3f ms native %.3f ms ratio %.3f\n",(unsigned long)count,bp,native,bp/native);
}
int main(void) { @autoreleasepool { URLTests(); URLReviewTests(); ISOTests(); ValueSemanticsTests(); TimerTests(); Perf(); printf("Core parity: %lu checks, %lu failures\n",(unsigned long)checks,(unsigned long)failures); return failures?1:0; } }
