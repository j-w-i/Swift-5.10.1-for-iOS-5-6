// Objective-C side of LegacyDispatchBridging.swift: libdispatch handles in Objective-C signatures,
// written the iOS 5 way (assign properties, manual dispatch_retain/release).
#import <Foundation/Foundation.h>

@interface LegacyQueueOwner : NSObject
// The setter retains the queue, as hand-written iOS 5 setters do.
@property (nonatomic, assign) dispatch_queue_t queue;
// A queue the owner creates; LegacyOwnedQueueFinalized reports when libdispatch disposes of it.
@property (nonatomic, readonly) dispatch_queue_t ownedQueue;
- (void)runOnQueue:(dispatch_queue_t)queue group:(dispatch_group_t)group block:(void (^)(void))block;
- (void)callBackWithQueue:(void (^)(dispatch_queue_t queue))handler;
- (void)releaseOwnedQueue;
@end

extern volatile int LegacyOwnedQueueFinalized;
uintptr_t LegacyHandleAddress(dispatch_queue_t queue);
dispatch_semaphore_t LegacySignalSemaphore(dispatch_semaphore_t semaphore);
dispatch_queue_t LegacyMaybeQueue(int wantQueue);
