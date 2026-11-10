# Swift Concurrency on the legacy iOS 5 runtime — device tests

`run-on-ipod.sh SRC.swift [TOOLCHAIN]` compiles a test with the assembled toolchain (no availability flags),
links the toolchain's own `libswift_Concurrency.dylib`, ships it over the USB bridge and runs it on the iPod.

* `ConcurrencyRuntime.swift` – 14 checks: actor contention, throwing task group, `async let`, checked
  continuations (value + throw), `AsyncStream`, error propagation, cancellation, `MainActor.run` (and that it
  is really the main thread), detached tasks, task-locals, `Task.sleep` timing, 500 child tasks.
* `ConcurrencyClocks.swift` – `Duration`, `ContinuousClock`, `SuspendingClock`, `Task.sleep(for:)`/`(until:)`.

The test must drain the main queue with `CFRunLoopRun()` (an app's UIApplication run loop does this);
`dispatchMain()` is not equivalent on iOS 5 for `@MainActor` work.
* `ConcurrencyAsyncSequences.swift` – 12 checks: custom `AsyncSequence`, `map`/`filter`/`prefix`/`dropFirst`/
  `reduce`/`contains`/`first(where:)`, `AsyncStream` buffering policies and `makeStream`, `AsyncThrowingStream`,
  termination, `withTaskCancellationHandler`, task priority, 2000 child tasks, `cancelAll`.
* `FoundationAsync.swift` – Foundation adapter regression checks with an in-process loopback HTTP
  fixture: data/bytes/upload/download, cancellation, notifications, buffered file bytes/lines,
  JSON fragments, URL path helpers. A skipped HTTP fixture is **not** a networking pass.
* `check-stage-failure.py` – host regression for build-stage error propagation and stamp creation.

See [API inventory](API-INVENTORY.md) for implemented adapters, non-streaming limitations and
remaining API work. Adapter byte/line properties are not yet source/behavior equivalent to Apple's
lazy streaming APIs. The embedded Foundation overlay now links `_Concurrency`, so apps using
Foundation load that runtime even if their own code has no async calls.

The runner signs only private runtime copies; it must never modify the hash-qualified toolchain.
Link failures and the remote test's exit status propagate to the invoking shell.

`run-on-simulator.sh SOURCE TOOLCHAIN SIMULATOR_UDID` compiles an arm64 device test and retags
private runtime copies for the simulator. It keeps its temporary evidence directory and never
modifies the toolchain. Apple's frameworks may also load their own Swift runtime; duplicate-class
warnings are expected in this configuration and must not be confused with a passing test result.

`EXTRA_LIBS=UIKit bash run-on-ipod.sh UIKitSemanticColors.swift TOOLCHAIN` checks the semantic
background selectors used by the photo app. These are light-appearance fallbacks only on systems
missing the native selectors.

`UIKitSpinnerStyles.swift` is a UIKit-app test (install/launch as a bundle through SpringBoard,
not the CLI runner). It tests legacy and modern spinner enum values (0/1/2/100/101), including
initializer, setter and animation. UIKit system image tables are unavailable before UIApplicationMain;
the direct CLI harness is therefore not a valid spinner test. Old UIKit
can throw with an absurd array capacity when given value 101; the backport maps medium/large to
gray/whiteLarge only when UIKit lacks its modern dynamic-color capability. Modern UIKit stays native.

`UIKitStackFirstUse.swift` is an app regression where `UIStackView(arrangedSubviews:)` is deliberately
the first Auto Layout operation. It checks arranged subviews, anchor constraints, button dispatch and
five main-actor async updates. Creating an unrelated constraint first would hide the original defect.
`check-stack-first-use-registration.py` also runs the actual Objective-C class-registration/facade
code with a minimal host mock; its negative control restores the old OA-only parent and must fail.
The public fallback class must inherit the bootstrap facade, not skip it through allocation redirection.
