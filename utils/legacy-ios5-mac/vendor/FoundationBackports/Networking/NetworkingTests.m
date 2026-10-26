#import "FBPURLSession.h"
#include <stdio.h>
#include <stdlib.h>
static unsigned checks;
#define CHECK(x) do { __sync_fetch_and_add(&checks,1); if(!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); abort(); } } while(0)
static NSData *Payload(void) { return [@"local deterministic payload" dataUsingEncoding:NSUTF8StringEncoding]; }
static NSURL *URL(NSString *path) {
#ifdef FBP_FORCE_TEST_RUNTIME
    return [NSURL URLWithString:[@"fbptest://" stringByAppendingString:path]];
#else
    NSString *base=[[[NSProcessInfo processInfo] environment] objectForKey:@"FBP_TEST_SERVER"];
    CHECK(base.length); return [NSURL URLWithString:[base stringByAppendingFormat:@"/%@",path]];
#endif
}
static NSURLRequest *UploadRequest(void) { NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:URL(@"upload")]; r.HTTPMethod=@"POST"; return r; }
@interface FBPTestProtocol : NSURLProtocol @end
@implementation FBPTestProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r { return [r.URL.scheme isEqual:@"fbptest"]; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading {
    if([self.request.URL.host isEqual:@"hold"]) return;
    NSData *data=Payload(); if([self.request.URL.host isEqual:@"upload"]) data=self.request.HTTPBody ?: data;
    NSURLResponse *r=[[NSURLResponse alloc] initWithURL:self.request.URL MIMEType:@"application/octet-stream" expectedContentLength:data.length textEncodingName:nil];
    [self.client URLProtocol:self didReceiveResponse:r cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data]; [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end
@interface FBPTestDelegate : NSObject <NSURLSessionDelegate,NSURLSessionDataDelegate,NSURLSessionDownloadDelegate>
@property dispatch_semaphore_t done;
@property(strong) NSMutableData *bytes;
@property BOOL invalidated;
@property(strong) NSError *error;
@property NSUInteger completionCount;
@property(strong) id expectedSession;
@property(strong) id expectedTask;
@property(strong) NSOperationQueue *queue;
@property NSUInteger progressCount;
@end
@implementation FBPTestDelegate
- (void)verifySession:(id)s task:(id)t { CHECK(s==_expectedSession && [s isKindOfClass:[FBPURLSession class]]); CHECK([NSOperationQueue currentQueue]==_queue); if(t) { CHECK([t isKindOfClass:[FBPURLSessionTask class]]); if(_expectedTask) CHECK(t==_expectedTask); } }
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data { [self verifySession:s task:t]; CHECK([(id)t isKindOfClass:[FBPURLSessionDataTask class]]); [_bytes appendData:data]; }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error { [self verifySession:s task:t]; _error=error; ++_completionCount; dispatch_semaphore_signal(_done); }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didSendBodyData:(int64_t)b totalBytesSent:(int64_t)total totalBytesExpectedToSend:(int64_t)expected { [self verifySession:s task:t]; CHECK([(id)t isKindOfClass:[FBPURLSessionUploadTask class]]); ++_progressCount; }
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didWriteData:(int64_t)b totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected { [self verifySession:s task:t]; CHECK([(id)t isKindOfClass:[FBPURLSessionDownloadTask class]]); ++_progressCount; }
- (void)URLSession:(NSURLSession *)s didBecomeInvalidWithError:(NSError *)error { [self verifySession:s task:nil]; _invalidated=YES; dispatch_semaphore_signal(_done); }
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didFinishDownloadingToURL:(NSURL *)url { [self verifySession:s task:t]; CHECK([(id)t isKindOfClass:[FBPURLSessionDownloadTask class]]); CHECK([[NSData dataWithContentsOfURL:url] isEqual:Payload()]); }
@end
static void Wait(dispatch_semaphore_t sem) { CHECK(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0); }
// Test-only private writes, not additional public/importer surface.
@interface FBPURLSessionTask (RaceTest)
- (void)setCountOfBytesSent:(int64_t)v;
- (void)setCountOfBytesExpectedToSend:(int64_t)v;
- (void)setCountOfBytesReceived:(int64_t)v;
- (void)setCountOfBytesExpectedToReceive:(int64_t)v;
- (void)setTaskIdentifier:(NSUInteger)v;
- (void)setState:(FBPURLSessionTaskState)v;
- (void)setOriginalRequest:(NSURLRequest *)v;
- (void)setError:(NSError *)v;
- (void)connection:(NSURLConnection *)c didReceiveResponse:(NSURLResponse *)r;
- (NSURLRequest *)connection:(NSURLConnection *)c willSendRequest:(NSURLRequest *)r redirectResponse:(NSURLResponse *)s;
@end
static void ReadRace(FBPURLSession *session) {
    FBPURLSessionTask *t=[FBPURLSessionTask new]; FBPURLSessionConfiguration *config=[FBPURLSessionConfiguration defaultSessionConfiguration];
    dispatch_group_t group=dispatch_group_create(); dispatch_queue_t q=dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0);
    dispatch_group_async(group,q, ^{ for(NSUInteger i=0;i<10000;i++) { @autoreleasepool {
        NSURLRequest *r=[NSURLRequest requestWithURL:URL(@"readrace")];
        [t connection:nil willSendRequest:r redirectResponse:nil]; [t setOriginalRequest:r];
        [t connection:nil didReceiveResponse:[[NSURLResponse alloc] initWithURL:r.URL MIMEType:@"text/plain" expectedContentLength:42 textEncodingName:nil]];
        [t setError:[NSError errorWithDomain:@"Race" code:i userInfo:nil]]; t.taskDescription=[NSString stringWithFormat:@"%lu",(unsigned long)i];
        [t setCountOfBytesSent:INT64_C(0x1234567887654321)]; [t setCountOfBytesExpectedToSend:INT64_C(0x1234567887654321)]; [t setCountOfBytesReceived:INT64_C(0x1234567887654321)]; [t setCountOfBytesExpectedToReceive:INT64_C(0x1234567887654321)]; [t setTaskIdentifier:i]; [t setState:FBPTaskRunning]; session.sessionDescription=t.taskDescription; config.HTTPAdditionalHeaders=@{@"Race":t.taskDescription}; config.timeoutIntervalForRequest=i+1; config.requestCachePolicy=i%4; config.HTTPShouldSetCookies=i%2; config.HTTPShouldUsePipelining=i%2;
    } } });
    for(int j=0;j<4;j++) dispatch_group_async(group,q, ^{ for(int i=0;i<10000;i++) { @autoreleasepool {
        CHECK(t.countOfBytesSent==0 || t.countOfBytesSent==INT64_C(0x1234567887654321));
        (void)t.countOfBytesReceived; (void)t.countOfBytesExpectedToReceive; (void)t.countOfBytesExpectedToSend; (void)t.state; (void)t.taskIdentifier;
        (void)t.currentRequest.URL.absoluteString.length; (void)t.originalRequest.URL.absoluteString.length; (void)t.response.MIMEType.length; (void)t.error.domain.length; (void)t.taskDescription.length;
        (void)config.HTTPAdditionalHeaders.count; (void)config.timeoutIntervalForRequest; (void)config.requestCachePolicy; (void)config.HTTPShouldSetCookies; (void)config.HTTPShouldUsePipelining;
        (void)session.configuration.HTTPAdditionalHeaders.count; (void)session.delegate; (void)session.delegateQueue; (void)session.sessionDescription.length;
    } } });
    CHECK(dispatch_group_wait(group,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0);
}
int main(void) { @autoreleasepool {
    [NSURLProtocol registerClass:[FBPTestProtocol class]];
    FBPURLSessionConfiguration *c=[FBPURLSessionConfiguration defaultSessionConfiguration]; CHECK([c isKindOfClass:[FBPURLSessionConfiguration class]]); CHECK([FBPURLSession sharedSession]==[FBPURLSession sharedSession]); CHECK([[FBPURLSession sharedSession] isKindOfClass:[FBPURLSession class]]);
#ifndef FBP_FORCE_TEST_RUNTIME
    CHECK(![(id)c isKindOfClass:[NSURLSessionConfiguration class]]); CHECK(![(id)[FBPURLSession sharedSession] isKindOfClass:[NSURLSession class]]);
#endif
    [[FBPURLSession sharedSession] invalidateAndCancel];
    c.HTTPAdditionalHeaders=@{@"X-Default":@"session",@"X-Override":@"session"}; c.timeoutIntervalForRequest=12; c.requestCachePolicy=NSURLRequestReturnCacheDataElseLoad;
    NSOperationQueue *queue=[[NSOperationQueue alloc] init]; queue.maxConcurrentOperationCount=4;
    FBPURLSession *s=[FBPURLSession sessionWithConfiguration:c delegate:nil delegateQueue:queue]; c.timeoutIntervalForRequest=99;
#ifndef FBP_FORCE_TEST_RUNTIME
    CHECK([[s valueForKey:@"nativeSession"] isKindOfClass:NSClassFromString(@"NSURLSession")]); CHECK([[c valueForKey:@"nativeConfiguration"] isKindOfClass:NSClassFromString(@"NSURLSessionConfiguration")]);
#endif
    CHECK([s isKindOfClass:[FBPURLSession class]]); CHECK(s.configuration.timeoutIntervalForRequest==12); FBPURLSessionConfiguration *snapshot=s.configuration; snapshot.timeoutIntervalForRequest=30; CHECK(s.configuration.timeoutIntervalForRequest==12);
    dispatch_semaphore_t done=dispatch_semaphore_create(0); __block NSUInteger calls=0;
    NSMutableURLRequest *r=[NSMutableURLRequest requestWithURL:URL(@"data")]; [r setValue:@"request" forHTTPHeaderField:@"X-Override"]; r.timeoutInterval=23; r.cachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
    FBPURLSessionDataTask *task=[s dataTaskWithRequest:r completionHandler:^(NSData *d,NSURLResponse *response,NSError *e) { CHECK([NSOperationQueue currentQueue]==queue); CHECK(!e && [d isEqual:Payload()]); ++calls; dispatch_semaphore_signal(done); }];
#ifndef FBP_FORCE_TEST_RUNTIME
    CHECK([[task valueForKey:@"nativeTask"] isKindOfClass:NSClassFromString(@"NSURLSessionDataTask")]); CHECK(![(id)task isKindOfClass:NSClassFromString(@"NSURLSessionTask")]);
#endif
    NSMutableString *description=[@"snapshot" mutableCopy]; task.taskDescription=description; [description appendString:@"changed"]; CHECK([task.taskDescription isEqual:@"snapshot"]);
    CHECK([task isKindOfClass:[FBPURLSessionDataTask class]] && [task isKindOfClass:[FBPURLSessionTask class]]); CHECK(task.state==FBPTaskSuspended); CHECK(task.currentRequest.timeoutInterval==23 && task.currentRequest.cachePolicy==NSURLRequestReloadIgnoringLocalCacheData); CHECK([[task.currentRequest valueForHTTPHeaderField:@"X-Override"] isEqual:@"request"]);
#ifdef FBP_FORCE_TEST_RUNTIME
    CHECK([[task.currentRequest valueForHTTPHeaderField:@"X-Default"] isEqual:@"session"]);
#endif
    [task resume]; Wait(done); [task cancel]; CHECK(calls==1 && task.state==FBPTaskCompleted && task.countOfBytesReceived==Payload().length);
    FBPURLSessionDataTask *cancelled=[s dataTaskWithURL:URL(@"hold") completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) { CHECK(!d && e.code==NSURLErrorCancelled); ++calls; dispatch_semaphore_signal(done); }]; CHECK(cancelled.currentRequest.timeoutInterval==60 && cancelled.currentRequest.cachePolicy==0); [cancelled cancel]; [cancelled cancel]; [cancelled resume]; Wait(done); CHECK(calls==2);
    FBPURLSessionDataTask *running=[s dataTaskWithURL:URL(@"hold") completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) { CHECK(e.code==NSURLErrorCancelled); dispatch_semaphore_signal(done); }]; [running resume]; [running cancel]; Wait(done);
    __block NSURL *downloadURL;
    FBPURLSessionDownloadTask *download=[s downloadTaskWithURL:URL(@"download") completionHandler:^(NSURL *url,NSURLResponse *r,NSError *e) { CHECK(!e && [[NSData dataWithContentsOfURL:url] isEqual:Payload()]); downloadURL=url; dispatch_semaphore_signal(done); }]; CHECK([download isKindOfClass:[FBPURLSessionDownloadTask class]] && ![download isKindOfClass:[FBPURLSessionDataTask class]]); [download resume]; Wait(done); [queue waitUntilAllOperationsAreFinished]; CHECK(![[NSFileManager defaultManager] fileExistsAtPath:downloadURL.path]);
    FBPURLSessionUploadTask *upload=[s uploadTaskWithRequest:UploadRequest() fromData:Payload() completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) { if(e || ![d isEqual:Payload()]) NSLog(@"upload error=%@ data=%@",e,d); CHECK(!e && [d isEqual:Payload()]); dispatch_semaphore_signal(done); }]; CHECK([upload isKindOfClass:[FBPURLSessionUploadTask class]] && [upload isKindOfClass:[FBPURLSessionDataTask class]]); [upload resume]; Wait(done);
    [s getTasksWithCompletionHandler:^(NSArray *d,NSArray *u,NSArray *f) { CHECK(!d.count && !u.count && !f.count); dispatch_semaphore_signal(done); }]; Wait(done);
    FBPTestDelegate *delegate=[FBPTestDelegate new]; delegate.done=done; delegate.bytes=[NSMutableData data]; delegate.queue=queue; FBPURLSession *ds=[FBPURLSession sessionWithConfiguration:[FBPURLSessionConfiguration defaultSessionConfiguration] delegate:delegate delegateQueue:queue]; delegate.expectedSession=ds;
    [[ds dataTaskWithURL:URL(@"data") completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) { CHECK(!e && [d isEqual:Payload()]); dispatch_semaphore_signal(done); }] resume]; Wait(done); [queue waitUntilAllOperationsAreFinished]; CHECK(delegate.completionCount==0 && delegate.bytes.length==0 && delegate.progressCount==0);
    [[ds uploadTaskWithRequest:UploadRequest() fromData:Payload() completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) { CHECK(!e && [d isEqual:Payload()]); dispatch_semaphore_signal(done); }] resume]; Wait(done); [queue waitUntilAllOperationsAreFinished]; CHECK(delegate.completionCount==0 && delegate.bytes.length==0 && delegate.progressCount==0);
    FBPURLSessionTask *dt=[ds dataTaskWithURL:URL(@"data")]; delegate.expectedTask=dt; [dt resume]; Wait(done); CHECK([delegate.bytes isEqual:Payload()] && delegate.completionCount==1 && !delegate.error);
    dt=[ds downloadTaskWithURL:URL(@"download")]; delegate.expectedTask=dt; [dt resume]; Wait(done); CHECK(delegate.completionCount==2);
    dt=[ds uploadTaskWithRequest:UploadRequest() fromData:Payload()]; delegate.expectedTask=dt; [dt resume]; Wait(done); CHECK(delegate.completionCount==3 && !delegate.error);
    [ds finishTasksAndInvalidate]; Wait(done); CHECK(delegate.invalidated && ds.delegate==nil); delegate.expectedSession=nil; delegate.expectedTask=nil;
    BOOL raised=NO; @try { [ds dataTaskWithURL:URL(@"data")]; } @catch(NSException *e) { raised=YES; } CHECK(raised);
#ifdef FBP_FORCE_TEST_RUNTIME
    FBPURLSessionDataTask *paused=[s dataTaskWithURL:URL(@"data") completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) { CHECK(!e); dispatch_semaphore_signal(done); }]; [paused suspend]; [paused resume]; CHECK(paused.state==FBPTaskSuspended); [paused resume]; Wait(done);
#endif
    CFAbsoluteTime begin=CFAbsoluteTimeGetCurrent(); NSUInteger iterations=100;
    for(NSUInteger i=0;i<iterations;++i) { @autoreleasepool { [[s dataTaskWithURL:URL(@"perf") completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) { CHECK(!e && [d isEqual:Payload()]); dispatch_semaphore_signal(done); }] resume]; Wait(done); } }
    printf("PASS networking behavior; perf %lu local tasks %.3f ms (%.3f ms/task)\n",(unsigned long)iterations,(CFAbsoluteTimeGetCurrent()-begin)*1000,(CFAbsoluteTimeGetCurrent()-begin)*1000/iterations);
    __block NSUInteger raceCompletions=0; dispatch_group_t cancelGroup=dispatch_group_create();
    for(NSUInteger i=0;i<100;++i) {
        FBPURLSessionDataTask *racing=[s dataTaskWithURL:URL(@"race") completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) { CHECK((!e && [d isEqual:Payload()]) || e.code==NSURLErrorCancelled); ++raceCompletions; dispatch_semaphore_signal(done); }];
        [racing resume]; dispatch_group_async(cancelGroup,dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0), ^{ [racing cancel]; [racing cancel]; });
    }
    for(NSUInteger i=0;i<100;++i) Wait(done);
    CHECK(dispatch_group_wait(cancelGroup,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0); [queue waitUntilAllOperationsAreFinished]; CHECK(raceCompletions==100);
    FBPTestDelegate *cancelDelegate=[FBPTestDelegate new]; cancelDelegate.done=done; cancelDelegate.queue=queue;
    FBPURLSession *cs=[FBPURLSession sessionWithConfiguration:[FBPURLSessionConfiguration defaultSessionConfiguration] delegate:cancelDelegate delegateQueue:queue]; cancelDelegate.expectedSession=cs;
    FBPURLSessionTask *held=[cs dataTaskWithURL:URL(@"hold")];
    FBPURLSessionTask *heldUpload=[cs uploadTaskWithRequest:UploadRequest() fromData:Payload()];
    FBPURLSessionTask *heldDownload=[cs downloadTaskWithURL:URL(@"hold")];
    [cs getTasksWithCompletionHandler:^(NSArray *d,NSArray *u,NSArray *f) { CHECK(d.count==1 && d[0]==held && u.count==1 && u[0]==heldUpload && f.count==1 && f[0]==heldDownload); dispatch_semaphore_signal(done); }]; Wait(done);
    [held resume]; [cs invalidateAndCancel]; Wait(done); Wait(done); Wait(done); Wait(done); CHECK(cancelDelegate.completionCount==3 && cancelDelegate.error.code==NSURLErrorCancelled && cancelDelegate.invalidated); cancelDelegate.expectedSession=nil;
    [[[FBPURLSession sharedSession] dataTaskWithURL:URL(@"data") completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) { CHECK(!e && [d isEqual:Payload()]); dispatch_semaphore_signal(done); }] resume]; Wait(done);
    ReadRace(s); [s finishTasksAndInvalidate]; [queue waitUntilAllOperationsAreFinished];
    printf("ASSERTIONS %u; cancellation races %lu; concurrent reads 4x10000\n", checks,(unsigned long)raceCompletions);
} return 0; }
