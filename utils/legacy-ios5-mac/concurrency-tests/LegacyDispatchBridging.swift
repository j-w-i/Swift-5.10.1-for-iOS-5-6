// libdispatch handles in C and Objective-C signatures import as the Dispatch overlay's classes on
// every slice (stock Swift: OS_dispatch_queue is DispatchQueue). Run through the device runner:
//   SWIFT_EXTRA="-import-objc-header $PWD/LegacyDispatchBridging.h" EXTRA_OBJC=$PWD/LegacyDispatchBridging.m \
//     bash run-on-ipod.sh LegacyDispatchBridging.swift TOOLCHAIN
import Foundation
import Dispatch
import Darwin

setvbuf(stdout, nil, _IONBF, 0)
var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS \(what)" : "FAIL \(what)")
    if !ok { failures += 1 }
}

let owner = LegacyQueueOwner()
let queue = DispatchQueue(label: "legacy.swift")

// Property (assign, the iOS 5 spelling): a DispatchQueue in, the same handle out.
owner.queue = queue
let readBack: DispatchQueue? = owner.queue
check(readBack != nil && LegacyHandleAddress(readBack) == LegacyHandleAddress(queue),
      "assign property takes and returns the same dispatch_queue_t")

// Parameters (queue, group) and a block run by libdispatch on that queue.
let group = DispatchGroup()
var ranOnQueue = false
owner.run(on: queue, group: group) { ranOnQueue = true }
check(group.wait(timeout: .now() + 2) == .success && ranOnQueue, "queue and group parameters reach dispatch_group_async")

// A block parameter that receives a queue.
var received: DispatchQueue?
owner.callBack { received = $0 }
check(received != nil && LegacyHandleAddress(received) == LegacyHandleAddress(queue), "block parameter receives the queue")

// C function: semaphore in, semaphore out.
let semaphore = DispatchSemaphore(value: 0)
let returned = LegacySignalSemaphore(semaphore)
check(returned?.wait(timeout: .now()) == .success, "C function returns the semaphore it signalled")
check(semaphore.wait(timeout: .now()) == .timedOut, "...and it is the same semaphore")

// NULL results are nil.
check(LegacyMaybeQueue(0) == nil, "NULL dispatch_queue_t is nil")
check(LegacyMaybeQueue(1) != nil, "main queue handle is non-nil")

// Reference counting: wrappers made from a handle retain it and release it when they go.
for _ in 0..<500 { owner.ownedQueue.sync {} }
check(LegacyOwnedQueueFinalized == 0, "500 short-lived wrappers leave the owner's reference intact")
var kept: DispatchQueue? = owner.ownedQueue
owner.releaseOwnedQueue()
usleep(200_000)
check(LegacyOwnedQueueFinalized == 0, "a Swift wrapper keeps the queue alive after Objective-C releases it")
var ranOnKept = false
kept?.sync { ranOnKept = true }
check(ranOnKept, "the kept queue still runs work")
kept = nil
for _ in 0..<20 where LegacyOwnedQueueFinalized == 0 { usleep(50_000) }
check(LegacyOwnedQueueFinalized == 1, "the queue is finalized once the last Swift wrapper goes (no leak)")

// Identity, as in stock Swift: one wrapper per handle while any is alive.
check(owner.queue === queue, "a queue read back from Objective-C is === the one stored")
var calledBack: DispatchQueue?
owner.callBack { calledBack = $0 }
check(calledBack === queue, "a queue passed to a block is === the one stored")
check(DispatchQueue.main === DispatchQueue.main, "DispatchQueue.main === DispatchQueue.main")
check(DispatchQueue.global() === DispatchQueue.global(), "DispatchQueue.global() === DispatchQueue.global()")
check(LegacyMaybeQueue(1) === DispatchQueue.main, "dispatch_get_main_queue() from C is DispatchQueue.main")
check(Set<DispatchObject>([queue, owner.queue!, DispatchQueue.main, LegacyMaybeQueue(1)!]).count == 2,
      "Hashable by identity")

// Swift overrides of Objective-C methods with dispatch handles, called from Objective-C.
final class SwiftQueueOwner: LegacyQueueOwner {
    var overrideSawQueue: DispatchQueue?
    override func run(on queue: DispatchQueue!, group: DispatchGroup!, block: (() -> Void)!) {
        overrideSawQueue = queue
        super.run(on: queue, group: group, block: block)
    }
}
let swiftOwner = SwiftQueueOwner()
check(swiftOwner.invokeRun(on: queue) && swiftOwner.overrideSawQueue === queue,
      "Objective-C reaches a Swift override with the queue it passed")

// A Swift class implementing an Objective-C protocol that returns a queue.
final class SwiftProvider: NSObject, LegacyQueueProvider {
    let queue = DispatchQueue(label: "legacy.provider")
    func queueForWork() -> DispatchQueue! { return queue }
}
let provider = SwiftProvider()
var providedAddress: UInt = 0
check(LegacyRunOnProvidedQueue(provider, &providedAddress) && providedAddress == LegacyHandleAddress(provider.queue),
      "Objective-C gets the handle from a Swift protocol witness and runs work on it")

// The overlay's own API is unchanged.
var ranAsync = false
let done = DispatchSemaphore(value: 0)
DispatchQueue.global().async { ranAsync = true; done.signal() }
check(done.wait(timeout: .now() + 2) == .success && ranAsync, "DispatchQueue.global().async")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(Int32(failures))
