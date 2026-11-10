# Swift Concurrency on the legacy iOS 5 runtime — device tests

`run-on-ipod.sh SRC.swift [TOOLCHAIN]` compiles a test with the assembled toolchain (no availability flags),
links the toolchain's own `libswift_Concurrency.dylib`, ships it over the USB bridge and runs it on the iPod.

* `ConcurrencyRuntime.swift` – 14 checks: actor contention, throwing task group, `async let`, checked
  continuations (value + throw), `AsyncStream`, error propagation, cancellation, `MainActor.run` (and that it
  is really the main thread), detached tasks, task-locals, `Task.sleep` timing, 500 child tasks.
* `ConcurrencyClocks.swift` – `Duration`, `ContinuousClock`, `SuspendingClock`, `Task.sleep(for:)`/`(until:)`.

The test must drain the main queue with `CFRunLoopRun()` (an app's UIApplication run loop does this);
`dispatchMain()` is not equivalent on iOS 5 for `@MainActor` work.
