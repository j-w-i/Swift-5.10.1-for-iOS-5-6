// Internal runtime declarations. Client declarations come unchanged from the SDK.
#import <Foundation/Foundation.h>
@interface FBPURLSessionConfiguration : NSObject <NSCopying>
@property NSTimeInterval timeoutIntervalForRequest;
@property NSURLRequestCachePolicy requestCachePolicy;
@property(copy) NSDictionary *HTTPAdditionalHeaders;
@property BOOL HTTPShouldSetCookies;
@property BOOL HTTPShouldUsePipelining;
+ (instancetype)defaultSessionConfiguration;
+ (instancetype)ephemeralSessionConfiguration;
@end
// Local scalar ABI equivalent avoids treating SDK enum availability as a runtime call.
typedef NS_ENUM(NSInteger, FBPURLSessionTaskState) { FBPTaskRunning=0, FBPTaskSuspended=1, FBPTaskCanceling=2, FBPTaskCompleted=3 };
@class FBPURLSessionTask, FBPURLSessionDataTask, FBPURLSessionUploadTask, FBPURLSessionDownloadTask;
@interface FBPURLSession : NSObject
@property(readonly,copy) FBPURLSessionConfiguration *configuration;
@property(readonly,strong) id delegate;
@property(readonly,strong) NSOperationQueue *delegateQueue;
@property(copy) NSString *sessionDescription;
+ (instancetype)sharedSession;
+ (instancetype)sessionWithConfiguration:(FBPURLSessionConfiguration *)configuration;
+ (instancetype)sessionWithConfiguration:(FBPURLSessionConfiguration *)configuration delegate:(id)delegate delegateQueue:(NSOperationQueue *)queue;
- (void)finishTasksAndInvalidate;
- (void)invalidateAndCancel;
- (void)getTasksWithCompletionHandler:(void (^)(NSArray *, NSArray *, NSArray *))completion;
- (FBPURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request;
- (FBPURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion;
- (FBPURLSessionDataTask *)dataTaskWithURL:(NSURL *)url;
- (FBPURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion;
- (FBPURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)body;
- (FBPURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request fromData:(NSData *)body completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion;
- (FBPURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request;
- (FBPURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completion;
- (FBPURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url;
- (FBPURLSessionDownloadTask *)downloadTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completion;
@end
@interface FBPURLSessionTask : NSObject <NSURLConnectionDataDelegate>
@property(readonly) NSUInteger taskIdentifier;
@property(copy) NSString *taskDescription;
@property(readonly,copy) NSURLRequest *originalRequest;
@property(readonly,copy) NSURLRequest *currentRequest;
@property(readonly,strong) NSURLResponse *response;
@property(readonly,strong) NSError *error;
@property(readonly) FBPURLSessionTaskState state;
@property(readonly) int64_t countOfBytesReceived;
@property(readonly) int64_t countOfBytesExpectedToReceive;
@property(readonly) int64_t countOfBytesSent;
@property(readonly) int64_t countOfBytesExpectedToSend;
- (void)resume;
- (void)suspend;
- (void)cancel;
@end
@interface FBPURLSessionDataTask : FBPURLSessionTask @end
@interface FBPURLSessionUploadTask : FBPURLSessionDataTask @end
@interface FBPURLSessionDownloadTask : FBPURLSessionTask @end
