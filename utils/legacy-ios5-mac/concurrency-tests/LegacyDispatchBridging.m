#import "LegacyDispatchBridging.h"

volatile int LegacyOwnedQueueFinalized = 0;
static void LegacyOwnedQueueFinalizer(void *context) { LegacyOwnedQueueFinalized = 1; }

@implementation LegacyQueueOwner {
    dispatch_queue_t _queue;
    dispatch_queue_t _ownedQueue;
}
- (id)init {
    if ((self = [super init])) {
        _ownedQueue = dispatch_queue_create("legacy.owned", NULL);
        dispatch_set_context(_ownedQueue, (void *)1);   // finalizers run only with a context
        dispatch_set_finalizer_f(_ownedQueue, LegacyOwnedQueueFinalizer);
    }
    return self;
}
- (dispatch_queue_t)queue { return _queue; }
- (void)setQueue:(dispatch_queue_t)queue {
    if (queue) dispatch_retain(queue);
    if (_queue) dispatch_release(_queue);
    _queue = queue;
}
- (dispatch_queue_t)ownedQueue { return _ownedQueue; }
- (void)runOnQueue:(dispatch_queue_t)queue group:(dispatch_group_t)group block:(void (^)(void))block {
    dispatch_group_async(group, queue, block);
}
- (void)callBackWithQueue:(void (^)(dispatch_queue_t))handler { handler(_queue); }
- (void)releaseOwnedQueue {
    dispatch_release(_ownedQueue);
    _ownedQueue = NULL;
}
@end

uintptr_t LegacyHandleAddress(dispatch_queue_t queue) { return (uintptr_t)queue; }
dispatch_semaphore_t LegacySignalSemaphore(dispatch_semaphore_t semaphore) {
    dispatch_semaphore_signal(semaphore);
    return semaphore;
}
dispatch_queue_t LegacyMaybeQueue(int wantQueue) {
    return wantQueue ? dispatch_get_main_queue() : NULL;
}
