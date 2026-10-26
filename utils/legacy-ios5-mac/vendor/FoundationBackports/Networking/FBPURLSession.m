#import "FBPURLSession.h"
#import <objc/runtime.h>

// SDK protocol names are preserved; no native class symbol imports or isa tricks.
__attribute__((used)) static Protocol *FBPSessionDelegateProtocol(void) { return @protocol(NSURLSessionDelegate); }
__attribute__((used)) static Protocol *FBPTaskDelegateProtocol(void) { return @protocol(NSURLSessionTaskDelegate); }
__attribute__((used)) static Protocol *FBPDataDelegateProtocol(void) { return @protocol(NSURLSessionDataDelegate); }
__attribute__((used)) static Protocol *FBPDownloadDelegateProtocol(void) { return @protocol(NSURLSessionDownloadDelegate); }
static Class FBPNative(NSString *name) {
#ifndef FBP_FORCE_TEST_RUNTIME
    return NSClassFromString(name);
#else
    return Nil;
#endif
}
@interface FBPURLSessionConfiguration ()
@property(strong) id nativeConfiguration;
@end
@implementation FBPURLSessionConfiguration
@synthesize timeoutIntervalForRequest=_timeoutIntervalForRequest, requestCachePolicy=_requestCachePolicy, HTTPAdditionalHeaders=_HTTPAdditionalHeaders, HTTPShouldSetCookies=_HTTPShouldSetCookies, HTTPShouldUsePipelining=_HTTPShouldUsePipelining;
+ (instancetype)defaultSessionConfiguration { return [[self alloc] init]; }
+ (instancetype)ephemeralSessionConfiguration { [NSException raise:NSInvalidArgumentException format:@"Ephemeral sessions are outside the supported subset"]; return nil; }
- (id)init { if((self=[super init])) { _timeoutIntervalForRequest=60; _HTTPShouldSetCookies=YES; _nativeConfiguration=[FBPNative(@"NSURLSessionConfiguration") defaultSessionConfiguration]; } return self; }
#define CONFIG_ACCESS(type, name, setter) \
- (type)name { @synchronized(self) { return _nativeConfiguration ? [_nativeConfiguration name] : _##name; } } \
- (void)setter:(type)v { @synchronized(self) { _##name=v; [_nativeConfiguration setter:v]; } }
CONFIG_ACCESS(NSTimeInterval, timeoutIntervalForRequest, setTimeoutIntervalForRequest)
CONFIG_ACCESS(NSURLRequestCachePolicy, requestCachePolicy, setRequestCachePolicy)
CONFIG_ACCESS(BOOL, HTTPShouldSetCookies, setHTTPShouldSetCookies)
CONFIG_ACCESS(BOOL, HTTPShouldUsePipelining, setHTTPShouldUsePipelining)
#undef CONFIG_ACCESS
- (NSDictionary *)HTTPAdditionalHeaders { @synchronized(self) { return _nativeConfiguration ? [_nativeConfiguration HTTPAdditionalHeaders] : _HTTPAdditionalHeaders; } }
- (void)setHTTPAdditionalHeaders:(NSDictionary *)v { @synchronized(self) { _HTTPAdditionalHeaders=[v copy]; [_nativeConfiguration setHTTPAdditionalHeaders:v]; } }
- (id)copyWithZone:(NSZone *)zone { @synchronized(self) { FBPURLSessionConfiguration *c=[[[self class] allocWithZone:zone] init]; c.timeoutIntervalForRequest=self.timeoutIntervalForRequest; c.requestCachePolicy=self.requestCachePolicy; c.HTTPAdditionalHeaders=self.HTTPAdditionalHeaders; c.HTTPShouldSetCookies=self.HTTPShouldSetCookies; c.HTTPShouldUsePipelining=self.HTTPShouldUsePipelining; c.nativeConfiguration=[_nativeConfiguration copy]; return c; } }
@end

@class FBPNativeSessionDelegate;
@interface FBPURLSession ()
@property(strong) NSMutableSet *tasks;
@property(strong) NSOperation *lastCallback;
@property(strong) NSObject *callbackMonitor;
@property BOOL invalidating;
@property BOOL invalidated;
@property BOOL shared;
@property NSUInteger nextIdentifier;
@property(strong) id nativeSession;
@property(strong) FBPNativeSessionDelegate *nativeBridge;
- (void)enqueue:(void (^)(void))block;
- (void)finished:(FBPURLSessionTask *)task;
- (FBPURLSessionTask *)wrapperForNative:(id)task;
- (void)nativeInvalidated:(NSError *)error;
@end
@interface FBPURLSessionTask ()
@property(readwrite) NSUInteger taskIdentifier;
@property(readwrite,copy) NSURLRequest *originalRequest;
@property(readwrite,copy) NSURLRequest *currentRequest;
@property(readwrite,strong) NSURLResponse *response;
@property(readwrite,strong) NSError *error;
@property(readwrite) FBPURLSessionTaskState state;
@property(readwrite) int64_t countOfBytesReceived;
@property(readwrite) int64_t countOfBytesExpectedToReceive;
@property(readwrite) int64_t countOfBytesSent;
@property(readwrite) int64_t countOfBytesExpectedToSend;
@property(strong) id nativeTask;
@property(strong) FBPURLSession *session;
@property(strong) NSURLConnection *connection;
@property(strong) NSOperationQueue *transportQueue;
@property(strong) NSMutableData *data;
@property(copy) id completion;
@property NSUInteger suspendCount;
@property BOOL started;
@property BOOL terminal;
@property BOOL download;
@property(strong) NSOutputStream *fileStream;
@property(strong) NSURL *fileURL;
- (void)finish:(NSError *)error;
- (void)nativeFinishedWithData:(NSData *)data location:(NSURL *)location response:(NSURLResponse *)response error:(NSError *)error;
- (void)nativeDownloaded:(NSURL *)location;
- (BOOL)hasCompletion;
@end
@interface FBPNativeSessionDelegate : NSObject
@property(strong) FBPURLSession *owner;
@end

@implementation FBPURLSession
@synthesize configuration=_configuration, delegate=_delegate, delegateQueue=_delegateQueue, sessionDescription=_sessionDescription;
+ (instancetype)sharedSession { static FBPURLSession *shared; static dispatch_once_t once; dispatch_once(&once, ^{ shared=[self sessionWithConfiguration:[FBPURLSessionConfiguration defaultSessionConfiguration]]; shared->_shared=YES; }); return shared; }
+ (instancetype)sessionWithConfiguration:(FBPURLSessionConfiguration *)c { return [self sessionWithConfiguration:c delegate:nil delegateQueue:nil]; }
+ (instancetype)sessionWithConfiguration:(FBPURLSessionConfiguration *)c delegate:(id)d delegateQueue:(NSOperationQueue *)q {
    if(!c) [NSException raise:NSInvalidArgumentException format:@"configuration must not be nil"];
    FBPURLSession *s=[[self alloc] init]; s->_configuration=[c copy]; s->_delegate=d; s->_delegateQueue=q ?: [[NSOperationQueue alloc] init]; if(!q) s->_delegateQueue.maxConcurrentOperationCount=1; s.tasks=[NSMutableSet set]; s.nextIdentifier=1; s.callbackMonitor=[NSObject new];
    Class native=FBPNative(@"NSURLSession");
    if(native) { FBPNativeSessionDelegate *bridge=[FBPNativeSessionDelegate new]; bridge.owner=s; s.nativeBridge=bridge; NSOperationQueue *transport=[NSOperationQueue new]; transport.maxConcurrentOperationCount=1; s.nativeSession=[native sessionWithConfiguration:s->_configuration.nativeConfiguration delegate:bridge delegateQueue:transport]; }
    return s;
}
- (FBPURLSessionConfiguration *)configuration { @synchronized(self) { return [_configuration copy]; } }
- (id)delegate { @synchronized(self) { return _delegate; } }
- (NSOperationQueue *)delegateQueue { @synchronized(self) { return _delegateQueue; } }
- (NSString *)sessionDescription { @synchronized(self) { return _nativeSession ? [_nativeSession sessionDescription] : _sessionDescription; } }
- (void)setSessionDescription:(NSString *)value { @synchronized(self) { _sessionDescription=[value copy]; [_nativeSession setSessionDescription:value]; } }
- (void)enqueue:(void (^)(void))block { @synchronized(self) { NSObject *monitor=_callbackMonitor; NSBlockOperation *op=[NSBlockOperation blockOperationWithBlock:^{ @synchronized(monitor) { block(); } }]; if(_lastCallback && ![_lastCallback isFinished]) [op addDependency:_lastCallback]; __unsafe_unretained NSOperation *executingOp=op; op.completionBlock=^{ @synchronized(self) { if(self.lastCallback==executingOp) self.lastCallback=nil; } }; _lastCallback=op; [_delegateQueue addOperation:op]; } }
- (void)nativeInvalidated:(NSError *)error { @synchronized(self) { if(_invalidated) return; _invalidated=YES; id d=_delegate; _delegate=nil; [self enqueue:^{ if([d respondsToSelector:@selector(URLSession:didBecomeInvalidWithError:)]) [d URLSession:(id)self didBecomeInvalidWithError:error]; }]; _nativeBridge.owner=nil; _nativeBridge=nil; } }
- (void)checkInvalidation { @synchronized(self) { if(_nativeSession || !_invalidating || _invalidated || [_tasks count]) return; [self nativeInvalidated:nil]; } }
- (void)finished:(FBPURLSessionTask *)task { @synchronized(self) { [_tasks removeObject:task]; [self checkInvalidation]; } }
- (FBPURLSessionTask *)wrapperForNative:(id)native { @synchronized(self) { for(FBPURLSessionTask *t in _tasks) if(t.nativeTask==native) return t; return nil; } }
- (void)finishTasksAndInvalidate { @synchronized(self) { if(_shared) return; _invalidating=YES; if(_nativeSession) [_nativeSession finishTasksAndInvalidate]; else [self checkInvalidation]; } }
- (void)invalidateAndCancel { NSArray *tasks; @synchronized(self) { if(_shared) return; _invalidating=YES; if(_nativeSession) { [_nativeSession invalidateAndCancel]; return; } tasks=[_tasks allObjects]; } for(FBPURLSessionTask *t in tasks) [t cancel]; [self checkInvalidation]; }
- (void)getTasksWithCompletionHandler:(void (^)(NSArray *,NSArray *,NSArray *))completion { if(!completion) return; NSMutableArray *d=[NSMutableArray array], *u=[NSMutableArray array], *f=[NSMutableArray array]; @synchronized(self) { for(id t in _tasks) { if([t isKindOfClass:[FBPURLSessionUploadTask class]]) [u addObject:t]; else if([t isKindOfClass:[FBPURLSessionDownloadTask class]]) [f addObject:t]; else [d addObject:t]; } } [self enqueue:^{ completion(d,u,f); }]; }
- (id)task:(Class)cls request:(NSURLRequest *)request completion:(id)completion { return [self task:cls request:request body:nil completion:completion]; }
- (id)task:(Class)cls request:(NSURLRequest *)request body:(NSData *)body completion:(id)completion {
    if(!request.URL) [NSException raise:NSInvalidArgumentException format:@"request URL must not be nil"];
    @synchronized(self) {
        if(_invalidating) [NSException raise:NSInternalInconsistencyException format:@"Session is invalidated"];
        FBPURLSessionTask *t=[[cls alloc] init]; t.session=self; t.download=[t isKindOfClass:[FBPURLSessionDownloadTask class]]; t.completion=completion;
        if(_nativeSession) {
            // Apple's shared session has no wrapper-owned delegate bridge. Its
            // handler-less public tasks still need a private retirement path;
            // otherwise the singleton retains completed wrappers indefinitely.
            BOOL needsRetirementHandler = completion != nil || _nativeBridge == nil;
            if(t.download) {
                if(needsRetirementHandler) t.nativeTask=[_nativeSession downloadTaskWithRequest:request completionHandler:^(NSURL *url,NSURLResponse *r,NSError *e) { [t nativeFinishedWithData:nil location:url response:r error:e]; }];
                else t.nativeTask=[_nativeSession downloadTaskWithRequest:request];
            } else if([t isKindOfClass:[FBPURLSessionUploadTask class]]) {
                if(needsRetirementHandler) t.nativeTask=[_nativeSession uploadTaskWithRequest:request fromData:body completionHandler:^(NSData *data,NSURLResponse *r,NSError *e) { [t nativeFinishedWithData:data location:nil response:r error:e]; }];
                else t.nativeTask=[_nativeSession uploadTaskWithRequest:request fromData:body];
            } else {
                if(needsRetirementHandler) t.nativeTask=[_nativeSession dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *r,NSError *e) { [t nativeFinishedWithData:data location:nil response:r error:e]; }];
                else t.nativeTask=[_nativeSession dataTaskWithRequest:request];
            }
        } else {
            // Native currentRequest preserves the request's timeout/cache values,
            // even when defaults are applied later by the transport.
            NSMutableURLRequest *r=[request mutableCopy]; if([t isKindOfClass:[FBPURLSessionUploadTask class]]) r.HTTPBody=body;
            for(NSString *key in _configuration.HTTPAdditionalHeaders) if(![r valueForHTTPHeaderField:key]) [r setValue:[[_configuration.HTTPAdditionalHeaders objectForKey:key] description] forHTTPHeaderField:key];
            t.originalRequest=request; t.currentRequest=r; t.taskIdentifier=_nextIdentifier++; t.state=FBPTaskSuspended; t.suspendCount=1; t.countOfBytesExpectedToReceive=-1; t.countOfBytesExpectedToSend=r.HTTPBody ? [r.HTTPBody length] : 0;
        }
        [_tasks addObject:t]; return t;
    }
}
- (FBPURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)r { return [self dataTaskWithRequest:r completionHandler:nil]; }
- (FBPURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)r completionHandler:(void (^)(NSData *,NSURLResponse *,NSError *))c { return [self task:[FBPURLSessionDataTask class] request:r completion:c]; }
- (FBPURLSessionDataTask *)dataTaskWithURL:(NSURL *)u { return [self dataTaskWithRequest:[NSURLRequest requestWithURL:u]]; }
- (FBPURLSessionDataTask *)dataTaskWithURL:(NSURL *)u completionHandler:(void (^)(NSData *,NSURLResponse *,NSError *))c { return [self dataTaskWithRequest:[NSURLRequest requestWithURL:u] completionHandler:c]; }
- (FBPURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)r fromData:(NSData *)d { return [self uploadTaskWithRequest:r fromData:d completionHandler:nil]; }
- (FBPURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)r fromData:(NSData *)d completionHandler:(void (^)(NSData *,NSURLResponse *,NSError *))c { return [self task:[FBPURLSessionUploadTask class] request:r body:d completion:c]; }
- (FBPURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)r { return [self downloadTaskWithRequest:r completionHandler:nil]; }
- (FBPURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)r completionHandler:(void (^)(NSURL *,NSURLResponse *,NSError *))c { return [self task:[FBPURLSessionDownloadTask class] request:r completion:c]; }
- (FBPURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)u { return [self downloadTaskWithRequest:[NSURLRequest requestWithURL:u]]; }
- (FBPURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)u completionHandler:(void (^)(NSURL *,NSURLResponse *,NSError *))c { return [self downloadTaskWithRequest:[NSURLRequest requestWithURL:u] completionHandler:c]; }
@end

@implementation FBPURLSessionTask
@synthesize taskIdentifier=_taskIdentifier, taskDescription=_taskDescription, originalRequest=_originalRequest, currentRequest=_currentRequest, response=_response, error=_error, state=_state, countOfBytesReceived=_countOfBytesReceived, countOfBytesExpectedToReceive=_countOfBytesExpectedToReceive, countOfBytesSent=_countOfBytesSent, countOfBytesExpectedToSend=_countOfBytesExpectedToSend;
// The SAME monitor protects direct ARC writes, strong returns and ARMv7 int64s.
#define FBP_ACCESS(type, name, setter) \
- (type)name { @synchronized(self) { return _nativeTask ? (type)[_nativeTask name] : _##name; } } \
- (void)setter:(type)value { @synchronized(self) { _##name=value; } }
FBP_ACCESS(NSUInteger, taskIdentifier, setTaskIdentifier)
FBP_ACCESS(NSURLResponse *, response, setResponse)
FBP_ACCESS(FBPURLSessionTaskState, state, setState)
FBP_ACCESS(int64_t, countOfBytesReceived, setCountOfBytesReceived)
FBP_ACCESS(int64_t, countOfBytesExpectedToReceive, setCountOfBytesExpectedToReceive)
FBP_ACCESS(int64_t, countOfBytesSent, setCountOfBytesSent)
FBP_ACCESS(int64_t, countOfBytesExpectedToSend, setCountOfBytesExpectedToSend)
#undef FBP_ACCESS
#define FBP_REQUEST_ACCESS(name, setter) \
- (NSURLRequest *)name { @synchronized(self) { return _nativeTask ? [_nativeTask name] : _##name; } } \
- (void)setter:(NSURLRequest *)value { @synchronized(self) { _##name=[value copy]; } }
FBP_REQUEST_ACCESS(originalRequest, setOriginalRequest)
FBP_REQUEST_ACCESS(currentRequest, setCurrentRequest)
#undef FBP_REQUEST_ACCESS
- (BOOL)hasCompletion { @synchronized(self) { return _completion!=nil; } }
- (NSError *)error { @synchronized(self) { return _error ?: [_nativeTask error]; } }
- (void)setError:(NSError *)value { @synchronized(self) { _error=value; } }
- (NSString *)taskDescription { @synchronized(self) { return _nativeTask ? [_nativeTask taskDescription] : _taskDescription; } }
- (void)setTaskDescription:(NSString *)value { @synchronized(self) { _taskDescription=[value copy]; [_nativeTask setTaskDescription:value]; } }
- (void)resume { @synchronized(self) {
    if(_nativeTask) { [(FBPURLSessionTask *)_nativeTask resume]; return; }
    if(_terminal || _suspendCount==0) return; if(--_suspendCount) return; _state=FBPTaskRunning;
    if(_started) { _transportQueue.suspended=NO; return; }
    _started=YES; _transportQueue=[[NSOperationQueue alloc] init]; _transportQueue.maxConcurrentOperationCount=1;
    if(_download) { NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]; _fileURL=[NSURL fileURLWithPath:path]; _fileStream=[NSOutputStream outputStreamToFileAtPath:path append:NO]; [_fileStream open]; }
    else if(_completion) _data=[NSMutableData data];
    NSMutableURLRequest *transport=[_currentRequest mutableCopy]; FBPURLSessionConfiguration *config=_session.configuration;
    if(transport.timeoutInterval==60) transport.timeoutInterval=config.timeoutIntervalForRequest;
    if(transport.cachePolicy==NSURLRequestUseProtocolCachePolicy) transport.cachePolicy=config.requestCachePolicy;
    transport.HTTPShouldHandleCookies=transport.HTTPShouldHandleCookies && config.HTTPShouldSetCookies;
    transport.HTTPShouldUsePipelining=transport.HTTPShouldUsePipelining || config.HTTPShouldUsePipelining;
    _connection=[[NSURLConnection alloc] initWithRequest:transport delegate:self startImmediately:NO];
    if(!_connection) { [self finish:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnsupportedURL userInfo:nil]]; return; }
    [_connection setDelegateQueue:_transportQueue]; [_connection start];
} }
- (void)suspend { @synchronized(self) { if(_nativeTask) { [(FBPURLSessionTask *)_nativeTask suspend]; return; } if(_terminal || _state==FBPTaskCanceling) return; ++_suspendCount; _state=FBPTaskSuspended; _transportQueue.suspended=YES; } }
- (void)cancel { @synchronized(self) { if(_nativeTask) { [_nativeTask cancel]; return; } if(_terminal) return; _state=FBPTaskCanceling; [_connection cancel]; _transportQueue.suspended=NO; [self finish:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]]; } }
// Native files are only valid during the native callback. Move to our own file
// before queue hopping; our file in turn exists only during the public callback.
- (void)nativeDownloaded:(NSURL *)location { @synchronized(self) { if(!location) return; NSURL *owned=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]]; NSError *e=nil; if([[NSFileManager defaultManager] moveItemAtURL:location toURL:owned error:&e]) _fileURL=owned; else _error=e; } }
- (void)nativeFinishedWithData:(NSData *)data location:(NSURL *)location response:(NSURLResponse *)response error:(NSError *)error { @synchronized(self) { if(_terminal) return; if(location) [self nativeDownloaded:location]; _data=[data mutableCopy]; _response=response; [self finish:error ?: _error]; } }
- (void)finish:(NSError *)error { @synchronized(self) {
    if(_terminal) return; _terminal=YES; _state=FBPTaskCompleted; _error=error; [_fileStream close]; _fileStream=nil; _connection=nil;
    FBPURLSession *session=_session; id completion=_completion; _completion=nil; NSData *data=[_data copy]; _data=nil; NSURL *location=_fileURL; id delegate=session.delegate;
    [session enqueue:^{
        if(completion) { if(self.download) ((void (^)(NSURL *,NSURLResponse *,NSError *))completion)(error?nil:location,self.response,error); else ((void (^)(NSData *,NSURLResponse *,NSError *))completion)(error?nil:(data ?: [NSData data]),self.response,error); }
        else { if(self.download && !error && [delegate respondsToSelector:@selector(URLSession:downloadTask:didFinishDownloadingToURL:)]) [delegate URLSession:(id)session downloadTask:(id)self didFinishDownloadingToURL:location]; if([delegate respondsToSelector:@selector(URLSession:task:didCompleteWithError:)]) [delegate URLSession:(id)session task:(id)self didCompleteWithError:error]; }
        if(location) [[NSFileManager defaultManager] removeItemAtURL:location error:NULL];
    }];
    [session finished:self]; _session=nil;
} }
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response { @synchronized(self) { if(_terminal) return; _response=response; _countOfBytesExpectedToReceive=response.expectedContentLength; _countOfBytesReceived=0; [_data setLength:0]; if(_fileStream) { [_fileStream close]; _fileStream=[NSOutputStream outputStreamToFileAtPath:_fileURL.path append:NO]; [_fileStream open]; } } }
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data { @synchronized(self) { if(_terminal) return;
    if(_download) { const uint8_t *p=data.bytes; NSUInteger left=data.length; while(left) { NSInteger n=[_fileStream write:p maxLength:left]; if(n<=0) { [_connection cancel]; [self finish:_fileStream.streamError ?: [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil]]; return; } left-=n; p+=n; } }
    else [_data appendData:data]; _countOfBytesReceived+=data.length;
    FBPURLSession *s=_session; id d=s.delegate; if(!_completion) { if(_download && [d respondsToSelector:@selector(URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)]) { int64_t total=_countOfBytesReceived, expected=_countOfBytesExpectedToReceive; [s enqueue:^{ [d URLSession:(id)s downloadTask:(id)self didWriteData:data.length totalBytesWritten:total totalBytesExpectedToWrite:expected]; }]; } else if(!_download && [d respondsToSelector:@selector(URLSession:dataTask:didReceiveData:)]) [s enqueue:^{ [d URLSession:(id)s dataTask:(id)self didReceiveData:data]; }]; }
} }
- (void)connectionDidFinishLoading:(NSURLConnection *)connection { [self finish:nil]; }
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error { [self finish:error]; }
- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cached { return cached; }
- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)response { @synchronized(self) { if(_terminal) return nil; _currentRequest=[request copy]; return request; } }
- (void)connection:(NSURLConnection *)connection didSendBodyData:(NSInteger)bytes totalBytesWritten:(NSInteger)total totalBytesExpectedToWrite:(NSInteger)expected { @synchronized(self) { if(_terminal) return; _countOfBytesSent=total; _countOfBytesExpectedToSend=expected; FBPURLSession *s=_session; id d=s.delegate; if(!_completion && [d respondsToSelector:@selector(URLSession:task:didSendBodyData:totalBytesSent:totalBytesExpectedToSend:)]) [s enqueue:^{ [d URLSession:(id)s task:(id)self didSendBodyData:bytes totalBytesSent:total totalBytesExpectedToSend:expected]; }]; } }
@end
@implementation FBPURLSessionDataTask @end
@implementation FBPURLSessionUploadTask @end
@implementation FBPURLSessionDownloadTask @end

@implementation FBPNativeSessionDelegate
- (void)URLSession:(id)s didBecomeInvalidWithError:(NSError *)error { FBPURLSession *owner=self.owner; [owner nativeInvalidated:error]; }
- (void)URLSession:(id)s task:(id)native didCompleteWithError:(NSError *)error { FBPURLSession *owner=self.owner; FBPURLSessionTask *t=[owner wrapperForNative:native]; [t nativeFinishedWithData:nil location:nil response:[native response] error:error]; }
- (void)URLSession:(id)s dataTask:(id)native didReceiveData:(NSData *)data { FBPURLSession *owner=self.owner; FBPURLSessionTask *t=[owner wrapperForNative:native]; id d=owner.delegate; if(t && !t.hasCompletion && [d respondsToSelector:@selector(URLSession:dataTask:didReceiveData:)]) [owner enqueue:^{ [d URLSession:(id)owner dataTask:(id)t didReceiveData:data]; }]; }
- (void)URLSession:(id)s task:(id)native didSendBodyData:(int64_t)bytes totalBytesSent:(int64_t)total totalBytesExpectedToSend:(int64_t)expected { FBPURLSession *owner=self.owner; FBPURLSessionTask *t=[owner wrapperForNative:native]; id d=owner.delegate; if(t && !t.hasCompletion && [d respondsToSelector:@selector(URLSession:task:didSendBodyData:totalBytesSent:totalBytesExpectedToSend:)]) [owner enqueue:^{ [d URLSession:(id)owner task:(id)t didSendBodyData:bytes totalBytesSent:total totalBytesExpectedToSend:expected]; }]; }
- (void)URLSession:(id)s downloadTask:(id)native didWriteData:(int64_t)bytes totalBytesWritten:(int64_t)total totalBytesExpectedToWrite:(int64_t)expected { FBPURLSession *owner=self.owner; FBPURLSessionTask *t=[owner wrapperForNative:native]; id d=owner.delegate; if(t && !t.hasCompletion && [d respondsToSelector:@selector(URLSession:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)]) [owner enqueue:^{ [d URLSession:(id)owner downloadTask:(id)t didWriteData:bytes totalBytesWritten:total totalBytesExpectedToWrite:expected]; }]; }
- (void)URLSession:(id)s downloadTask:(id)native didFinishDownloadingToURL:(NSURL *)location { [[self.owner wrapperForNative:native] nativeDownloaded:location]; }
@end
