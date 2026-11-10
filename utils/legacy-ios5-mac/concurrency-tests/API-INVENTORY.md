# Concurrency-adjacent Foundation API inventory

This is an implementation inventory, **not** a claim that every SDK API is backported. Concurrency support does not automatically make newer Foundation or UIKit classes available. Keep availability diagnostics enabled in projects.

## Implemented in this change

Verified by 57/57 checks (zero skips) on iPod touch iOS 5.1.1, iPhone 6 iOS 10.3.3 and iOS 27 simulator. This validates the explicitly buffered subset below, not full native API parity. All three runtime architectures build and pass static qualification; armv7s has no physical execution coverage.

| API | Implementation | Important differences / tests needed |
| --- | --- | --- |
| `URLSession.data(from:)`, `data(for:)` | Checked continuation around the existing URLSession completion API; task cancellation forwarded | No per-request delegate overload yet. Test successful, failed, and cancelled requests on both the legacy transport and native-session forwarding path. |
| `URLSession.upload(for:from:)` (Data) | Completion API plus cancellation | File upload overload and per-request delegates are not implemented. |
| `URLSession.download(from:)`, `download(for:)` | Completion API plus cancellation; preserve callback temporary file by moving it | Caller must clean up returned temporary file. Test file still exists after callback returns. |
| `URLSession.bytes(from:)`, `bytes(for:)` | Buffered response exposed as AsyncSequence | **Not streaming**: unsuitable for SSE, unbounded responses, or bounded-memory large downloads. |
| `URL.lines` | Buffered UTF-8 decoding and CR/LF/CRLF splitting | Currently asynchronous property, not source-compatible with Apple's synchronous sequence property. Local file reads currently block the executing thread. |
| `FileHandle.bytes` | Entire remaining file read on a dispatch worker | Currently asynchronous property and fully buffered, not native lazy streaming semantics. Read exceptions and cancellation need hardening. |
| `NotificationCenter.notifications(named:object:)` | Observer bridged to AsyncStream | Unbounded buffering; Notification is not Sendable. Observer lifetime on early loop exit needs review. Do not assume `break` is equivalent to cancellation. |
| URL path-component / extension helpers | Existing NSURL operations | Round-trip and mutation tests. |
| Top-level JSONDecoder fragments | JSONSerialization `.allowFragments` | Decode scalar/string/bool/null fragments on old Foundation. |

The URLSession callback surface is already provided by the source-built Foundation networking backport. It uses a legacy NSURLConnection transport when URLSession is absent and forwards to native sessions when present. Async wrappers must be shipped in every architecture's Foundation overlay and explicitly link the embedded concurrency runtime.

## High-value next work (not implemented by this change)

1. **True lazy byte/line sequences**: synchronous property access, iterator-driven I/O, errors from `next()`, incremental UTF-8 decoding, bounded buffering, cancellation of a blocked read, and explicit handle ownership. Avoid presenting buffered APIs as streaming parity.
2. **URLSession overload parity**: upload from file; download using resume data only if the underlying transport can genuinely support it; per-request delegate variants only after delegate routing has an implementation. Do not silently ignore a supplied delegate.
3. **Notification lifetime and buffering**: a dedicated sequence/iterator with observer ownership, cancellation cleanup, tested early termination and object filtering. Document ordering and dropped values if adding bounded buffering.
4. **Sendable audits**: inspect Foundation value types (Data, URL, URLRequest, Date, UUID, IndexPath) and UIKit objects separately. Do not blanket-mark reference types or UIImage as Sendable merely to suppress diagnostics. Protect mutable storage before adding unchecked conformances.
5. **UIKit callback adapters**: `UIApplication.open` async form and image preparation APIs. These need actual runtime fallbacks, main-thread tests, and API-specific semantics; they are not supplied simply by enabling concurrency.
6. **Foundation classes still gated by their actual runtime**: Progress (iOS 7), DateInterval/Measurement and Unit families (iOS 10), and ProcessInfo activity APIs. Existing overlay declarations do not establish iOS 5 implementations. Preserve their availability until those classes/selectors have real implementations and tests.
7. **Modern formatting**: FormatStyle, ParseStrategy, newer Date/Duration formatting, and newer attributed-string APIs require additional libraries/implementations; no parity is claimed here.

## UIKit startup follow-up

The user's unchanged photo-app source calls `UIColor.systemBackground`. On iOS 5 this compiled call
reached a missing `systemBackgroundColor` selector and raised an Objective-C exception before async
networking started. The UIKit runtime now installs six missing semantic background class selectors,
using static light-appearance white / light-gray colors. Existing native methods are not replaced;
old systems do not gain dynamic dark appearance. `UIKitSemanticColors.swift` exercises the selectors
and invokes the fallback without bypassing SDK availability. The native Swift property remains
SDK-gated; the user's project had explicitly disabled availability checking in its saved settings,
which is how this missing runtime API originally compiled. This is independent of Swift Concurrency.

## Existing concurrency substrate

The embedded `_Concurrency` runtime supplies Tasks, actors, continuations, task groups, AsyncSequence algorithms, AsyncStream/AsyncThrowingStream, clocks and cancellation. Existing device suites exercise these independently of the Foundation adapters. Continuous time across system sleep is not supported before iOS 10; legacy task priority mapping and main-run-loop requirements remain as documented in the runtime qualification results.
