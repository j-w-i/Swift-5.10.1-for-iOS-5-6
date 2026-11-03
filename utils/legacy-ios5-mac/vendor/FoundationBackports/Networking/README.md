# Foundation networking runtime subset

The guarded importer maps SDK NSURLSession family references to the concrete FBP class hierarchy. Configurations, sessions and tasks **always retain FBP identity**, including on newer systems: they wrap actual native Foundation instances discovered with `NSClassFromString`. No raw native object is substituted for an FBP allocation/factory result; no isa, superclass, swizzle or global runtime-name alias is used. SDK delegate protocol names and metadata are retained.

On iOS 5/6 (or with the test-only `FBP_FORCE_TEST_RUNTIME` macro), the transport is NSURLConnection, scheduled on one dedicated network thread (never `-setDelegateQueue:`: on iOS 5 that makes CFNetwork deliver from the main run loop and block it in `-[NSOperation waitUntilFinished]` while holding the connection lock, which deadlocks the app against `+cancelConnection` - device report 0x8badf00d, 2026-10-27). On iOS 7+, native Foundation does the transport; a private delegate bridge maps back to the original FBP session/task instances. Public sharedSession is one stable wrapper, with default native-backed transport and no-op invalidation, not Apple's unrelated singleton object.

## Supported surface

* Default configuration snapshot/copy, timeoutIntervalForRequest, requestCachePolicy, HTTPAdditionalHeaders, HTTPShouldSetCookies, HTTPShouldUsePipelining.
* Session factories/sharedSession, delegate/delegateQueue/sessionDescription, finishTasksAndInvalidate, invalidateAndCancel, getTasksWithCompletionHandler.
* Data URL/request tasks, NSData uploads, URL/request downloads, with completion handlers or supported delegates.
* Task identity/descriptions, original/current requests, response/error/state/byte counts, resume/cancel; upload inherits data task, download inherits task directly.
* Invalidation, completion, upload progress, data chunks, download progress and temporary-file delegate callbacks. Bridges never expose raw native objects. Completion-handler tasks suppress task/data delegate callbacks. An operation dependency chain preserves callback order and a distinct callback monitor serializes memory access even on a supplied concurrent queue. The session monitor is not held while executing client callbacks.
* Download files are streamed by the transport and valid only during the public file callback. Native temporary files are moved to wrapper-owned temporary paths before changing queues, then removed after the public callback. Move/copy files before returning.
* Every externally readable mutable task/configuration/session property uses the same monitor as its ARC/scalar writes, including strong-return lifetimes and 64-bit counters on ARMv7. No KVO progress guarantees are made.

Request-specific headers and **nondefault request timeout/cache values win** over legacy session defaults. A native host probe observed originalRequest/currentRequest retaining 60/cache0 for an ordinary request and 23/cache1 for a customized request, with session configuration 12/cache3. Legacy task creation now preserves these values too. The legacy transport applies configuration timeout/cache only when the request has the normal 60/cache0 values; Foundation's private distinction between explicitly set default values and implicit defaults is not reproduced. Normal cookie/cache/credential behavior on old systems is process-wide Foundation behavior.

## Explicitly unavailable, not emulated

No ephemeral/background sessions, per-session protocolClasses/cache/cookie/credential stores, resource timeout, cellular-policy overrides, advanced authentication/redirect/response/cache delegate decisions, metrics, task priority, suspension, file/stream upload, download resume data, stream/WebSocket tasks, async APIs or modern enumeration additions. The internal suspend selector is denied by the importer; legacy it only pauses callback delivery, not transport. Byte counts are delivered bytes/progress, not encrypted wire traffic. Existing iOS5 TLS/security limitations remain unchanged.

Session/task/native-delegate retain cycles keep active or suspended tasks alive; finish or invalidate sessions to release them. The global shared wrapper intentionally lives for the process lifetime. Global NSURLProtocol registration is a deterministic old-engine fixture only; native sessions may ignore it (the AppFoundation1 global-protocol test may therefore SKIP on newer OS versions).

## Reproducible host tests

All binaries, logs and temporary files must remain under `/Users/jwalr/legacy-fresh-proof/build-root/foundation-work`. The loopback-only server has no third-party dependencies. Start it as a managed job and stop it after the native suite:

```sh
S=/Users/jwalr/Developer/Swift-5.10.1-for-iOS-5-6/utils/legacy-ios5-mac/vendor/FoundationBackports/Networking
W=/Users/jwalr/legacy-fresh-proof/build-root/foundation-work
PYTHONDONTWRITEBYTECODE=1 python3 "$S/TestHTTPServer.py"
```

In another shell (omit FORCE only for actual native integration):

```sh
X=/Users/jwalr/Applications/Xcode-13.4.1.app/Contents/Developer
C="$X/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
SDK="$X/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
"$C" -isysroot "$SDK" -O2 -fobjc-arc -fblocks -DFBP_FORCE_TEST_RUNTIME=1 \
  -Wno-deprecated-declarations "$S/FBPURLSession.m" "$S/NetworkingTests.m" \
  -framework Foundation -o "$W/network-legacy-reviewed"
TMPDIR="$W/" "$W/network-legacy-reviewed"
# Native: remove -DFBP_FORCE_TEST_RUNTIME=1, output network-native-reviewed,
# run with TMPDIR="$W/" FBP_TEST_SERVER=http://127.0.0.1:18764.
```

For TSan use the **current host** `/usr/bin/clang` and SDK from `xcrun --sdk macosx --show-sdk-path`, with `-O1 -g -fsanitize=thread`, the same source files and FORCE selection, and `TSAN_OPTIONS=halt_on_error=1`. Xcode13's sanitizer runtime aborts before main on the current host even with early DYLD injection; this is not a test pass. Current-host TSan passes both modes without suppressions.

Reviewed suites cover FBP subclass casts and callback identity, all three task enumeration arrays, configuration snapshots, request precedence, supplied concurrent callback queue, completion-delegate suppression, data/upload/download, temporary-file lifetime, shared-session identity/invalidation, cancellation-before-resume, exactly-once terminal behavior, invalidation ordering, 100 completion/cancel races, and 4x10,000 concurrent getter iterations racing 10,000 direct callback ARC/scalar writes. A 100-task microbenchmark is printed (not device/network performance qualification).

Handler-less native shared-session tasks also have a private retirement handler;
without it there is no delegate bridge to remove completed wrappers from the
singleton registry. `SharedSessionLifetimeTests.m` independently verifies data,
upload and download retirement, weak-reference release, and 100 repeated tasks
using an unsupported local URL scheme (no server or network needed):

```sh
/usr/bin/clang -O2 -fobjc-arc -fblocks -Wno-deprecated-declarations \
  "$S/FBPURLSession.m" "$S/SharedSessionLifetimeTests.m" \
  -framework Foundation -o "$W/network-shared-retirement"
"$W/network-shared-retirement"
# Repeat with -O1 -g -fsanitize=thread and TSAN_OPTIONS=halt_on_error=1.
```

Strict ARM-mode armv7/iOS5 compilation, export/undefined-symbol audit and packaged notices are produced by the parent runtime builder. Host tests and successful compilation are not iOS5 device, TLS, or full Foundation conformance qualification.
