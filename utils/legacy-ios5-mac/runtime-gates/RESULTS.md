# Runtime gate results (pipeline-built toolchain)

Toolchain: built by `build-all.sh` in a clean root (`legacy-build-fix7`), all six iOS 5 qualification
checks passing, published as the environment profile.

| Check | Result |
|---|---|
| `check-binary-gates.sh` on the kit-built IPA | PASS (armv7, arm64) |
| Simulator cast-corruption gate on the toolchain runtime | PASS |
| `battery-sim.sh` on the kit-built app, iOS 27 simulator | PASS: 12/12 launches, 90 s soak, appearance/background/content-size, malloc scribble + guard edges, no crash reports |
| Layout A/B vs native, two identical iOS 27 simulators | 0.00 % differing pixels |
| API gating probe, iOS 27 simulator, pipeline runtime vs native | identical behaviour lines |
| Kit-built app, iPhone 6 (iOS 10.3.3) | launches signed in, server list loads, no crash reports |
| Kit-built app, iPod touch (iOS 5.1.1) | launches: 6/6 cold launches; 98-second offline soak remained responsive; no new crash reports; after Wi-Fi recovery, gateway READY observed and server sidebar populated |

2026-11-09 follow-up: fixed the iOS 5 constraint registration ordering gap (missing visual-format
class factory) and the kit's armv7 companion packaging order (previously copied Xcode's runtime
before qualified closure replacement). Rebuilt overlays, all three runtime slices, assembly and
sanitization through `build-all.sh`; six qualification checks pass. UUID of the packaged armv7
UIKit matches the qualified runtime. Project-command regression tests now require companion
creation after the runtime closure; the binary gate rejects an IPA path instead of falsely passing.
The rebuilt current-iOS simulator battery passes. Its A/B screenshot differs by 0.13% overall,
confined to status-bar pixels; application pixels below y=150 differ by 0.00%.

The iPod initially had no network address (all DNS probes failed; HTTP -1009). Enabling its existing
Wi-Fi connection restored DHCP/DNS/HTTP without changing certificates or TLS. The app reached
READY using its existing credentials; after a 91-second online soak it remained responsive with
seven populated sidebar cells (122 views). Detached message-shaped stack layout (12 items) and
stack-append lifecycle (10 items) also pass on the device, with no new crash reports. The signed
combined IPA was reinstalled on iPhone 6 / iOS 10.3.3; gateway READY and heartbeat ACK were observed,
with no app crash reports collected. A network disconnect/reconnect occurred during that run,
so uninterrupted connection stability is not claimed. A separate pre-existing immediate gateway retry loop was
identified while offline. Its repair is committed in Neocord2 `cb3b007`: serialized lifecycle,
one cancellable retry with 1/2/4/8/16/30-second capped spacing, stale-socket/generation guards,
and stop-on-invalid-token. Focused policy/LegacyWorkItem tests pass 20,368 checks, also under
Thread Sanitizer. Full armv7/arm64 app rebuild passes; final iPod build reaches READY, receives
heartbeat ACK and displays seven sidebar cells with no new crashes. Final iOS 10 build reaches
READY and receives repeated heartbeat ACKs. Current-iOS simulator battery again passes all gates.
A forced-offline device test is NOT qualified: the existing Wi-Fi switch listener did not reliably
make the link unreachable (and one attempt lost its SSH forwarder). Wi-Fi was restored and the
online app rechecked. The current-iOS phone accepted installation of this final build but launch
was explicitly denied by its lock screen; final-build phone launch remains pending.

Further lifecycle review (`ef0fa48`) fixed old rate-bucket replenishment callbacks mutating the
new generation's counter/queue, and removed asynchronous READY parsing's stale write through
the client's potentially replaced gateway. Focused bucket FIFO/rate/reset tests pass, including
Thread Sanitizer; both reset regressions fail against the original implementation (negative
controls). Retry tests still pass 20,368 checks. Full app rebuild succeeds. The latest iOS 5 build
passes a 90-second signed-in soak with READY, heartbeat ACK, seven sidebar cells and unchanged
crash count. The latest iOS 10 build reaches READY with repeated heartbeat ACKs and no reconnects
or connection failures during the observed interval. All 15 packaged Mach-O images pass the iOS 5
strong-import audit; combined binary gates pass armv7/arm64. Project availability checking remains
enabled (no blanket bypass). Apple's Xcode SourceKit framework remains intact and code-signature
verification passes. Runtime profile hashes reverified and published with observed device evidence.
The final `ef0fa48` app also passes the complete current-iOS simulator battery and its repeated
native A/B comparison reports 0.00% differing pixels.

Build tiers (important when reproducing): the saved project configuration builds a **6.0-floor**
armv7+arm64 product (`LC_MAIN`, `MinimumOSVersion 6.0`) for iOS 6 and later; the iOS 5 device needs
the same generator run with `deploymentTarget: 5.0`, armv7 only (`LC_UNIXTHREAD`, floor 5.0). A
6.0-floor app installed on iOS 5.1.1 segfaults at launch, which is an artifact mismatch, not a
runtime defect; the device installer now refuses it. The regenerated saved command was executed
end to end: the 6.0 product passed the current-iOS simulator battery and reached READY with three
heartbeat ACKs on iPhone 6 / iOS 10.3.3, while the 5.0 product reached READY, popped seven sidebar
cells, produced heartbeat ACKs and answered twenty consecutive main-thread commands in 1.1-1.9 s
with zero timeouts.

Known limitation observed on the iPod: over two idle minutes the gateway re-established the socket
twice, resuming its session each time (two RESUMEs, two ACKs, no READY, no crash). The queue drains,
the UI stays responsive, but connection churn on that iOS 5 network path remains.

iPhone 15 Pro / iOS 27 (physical, after unlocking): the shipped 6.0-floor armv7+arm64 build launches,
reaches READY and took nine heartbeat ACKs over seven minutes with zero reconnect or connection
failure lines and no crash reports for the app. A native build of the same commit was produced with
Xcode (`iphoneos`, unsigned, then signed with the same development identity) and installed on the
same phone for comparison. The first comparison was NOT identical (native title top 176 px vs 180,
native bottom borders 2228/2261 vs 2223/2256; 6.1% pixel diff). Root cause, found by bisecting the
bundle one difference at a time on the phone: the fat executable's **armv7 slice** still carried
linked SDK 15.5, and iOS 27 judges a fat file by that slice, so the whole app ran in the zoomed
compatibility size (screen 390x844 instead of 393x852) even though the arm64 slice was tagged 19.0.
Info.plist keys, DT* SDK keys, asset catalog and launch storyboard were each tested and ruled out.
The sanitiser now retags every executable slice (`strip-system-swift-deps.py`, test updated). After
rebuilding through the saved kit command both slices read SDK 19.0 and the phone reports 393x852.
Measured against the native build on the physical iPhone 15 Pro: all panel borders identical
(32, 143, 176, 335, 368, 2228, 2261, 2367 px), and 0.00% differing pixels in title bar, sidebar,
content and toolbar; the whole-screen difference is 0.11%, entirely the status bar (clock/battery).
A raw-pixel iOS 27 simulator comparison on iPhone 13 and iPhone 15 Pro simulators is also 0.00%.

iPhone 6 / iOS 10.3.3: the shipped backport launches signed in with the DM list, title bar, sidebar
and toolbar rendered as expected, and `idevicescreenshot` output is archived as evidence. A native
iOS 10 comparison build is NOT possible with the installed Xcode: the project's SwiftPM packages
declare a supported deployment range starting at 15.0, so `IPHONEOS_DEPLOYMENT_TARGET=10.0` fails
before compiling. iOS 10.3.3 therefore covers launch, sign-in, data loading and crash-freedom, not
pixel parity; pixel parity is established on the iOS 27 simulator and the physical iOS 27 phone.

Known limits: `UILayoutGuide`/anchor types are the backport's own Swift types on every OS (the
constraints they build are native `NSLayoutConstraint`); iOS 7–9 and 11–26 are covered by these
property-based gates, not by device runs.

iOS 10.3.3 re-check after the retag: sidebar and toolbar are pixel-identical to the previous run
(0.00%); title/content differ only by live data state (DM list loaded in one capture, empty panel in
the other, because a gateway reconnect was in progress), not by geometry. The iOS 5 build path does
not pass `--linked-sdk`, so it is unaffected by this change.


## Swift Concurrency backport (2026-11-10)

`async`/`await`, `Task`, actors, `@MainActor`, task groups, `async let`, continuations, `AsyncStream`,
task-locals, cancellation and `Task.sleep` work at the iOS 5.0 floor (armv7) and at the iOS 7.0 floor
(armv7s/arm64), from one generic binary. Nothing is gated by a flag: the stock compiler's availability
errors came from two compiler rules, both changed.

**Compiler** (`lib/AST/Availability.cpp`, `lib/AST/Decl.cpp`): when the program ships its own Swift runtime
(the legacy backport), declarations of the `Swift` and `_Concurrency` modules are treated as available at
every deployment target and linked strongly. Everything else keeps its real availability: a
`safeAreaInsets` use below iOS 11 is still an error.

**Runtime** (`stdlib/public/Concurrency`, built from source by `build-all.sh`, stage `legacy-core-510`):
the iOS 5.1.1 system lacks `qos_class_self`, vouchers, `dispatch_activate`, `clock_gettime`, `memset_s`,
`os_signpost`, and its dispatch queues are not Objective-C objects. Each is handled in the runtime from
what the OS actually exports at run time (not from a version number): native paths are used where the
symbol exists, a documented fallback otherwise.

| Evidence | Result |
|---|---|
| iPod touch, iOS 5.1.1, 14 runtime checks (actors under contention, task groups, async let, continuations, AsyncStream, cancellation, MainActor on the main thread, detached, task-local, timing, 500 tasks) | ALL PASS |
| iPod touch, Duration / ContinuousClock / SuspendingClock / `Task.sleep(for:)` | PASS |
| Kit-built UIKit async app, floor 5.0, armv7-only IPA, iPod 5.1.1 | `ASYNC OK` |
| Same app, combined armv7+arm64 IPA (floor 6.0), iPhone 6 iOS 10.3.3 | actor total 51, continuation 42, onMain true |
| Same app, arm64 slice, iOS 27 simulator | identical output |
| Strict concurrency diagnostics (Sendable, actor isolation) on armv7 iOS 5.0 and arm64 | identical to stock Swift |
| `check-concurrency.sh` on the assembled toolchain | PASS |

**Hard limits and deviations (documented, not hidden)**
* The "continuous" clock cannot include device sleep time on an OS without `clock_gettime` (iOS < 10):
  `mach_absolute_time` stops during sleep, so there it behaves like the suspending clock.
* Cooperative global queues (iOS 15+) and QoS-based priorities (iOS 8+) are not available before those
  versions; jobs run on the plain global queues for the nearest legacy priority.
* An app that drives `@MainActor` work must drain the main queue with a run loop (any UIApplication does);
  `dispatchMain()` alone does not on iOS 5.
* Signpost tracing of concurrency events is compiled out on the legacy runtime.
* armv7s/arm64 run on iOS 7.0+ and use the standard object model; only armv7 uses the iOS 5 class-marking ABI.
  The OS-support shims (pthread mutexes instead of `os_unfair_lock`, no vouchers, run-time-checked
  QoS/`clock_gettime`/`dispatch_activate`, no `memset_s`, no signposts) are compiled into **every** legacy
  slice (`SWIFT_LEGACY_OS_SHIMS`), because iOS 7-9 lack those facilities too. `check-concurrency.sh` fails if
  any slice's Core or `_Concurrency` strongly imports one. iOS 7-9 themselves were not run (no device or
  simulator runtime available); iOS 10.3.3 (arm64) and iOS 27 (arm64) were.
* The embedded `_Concurrency`/`Core` are used on every OS including iOS 13+ (the system copies are loaded
  by Apple's own frameworks in the same process but never used by the app's Swift code).

Neocord2 re-verified with the concurrency-enabled toolchain (no source changes to the app): the iOS 5.0
armv7-only build launches on the iPod touch (iOS 5.1.1), reaches Discord READY, shows seven server icons,
stays responsive, no new crash reports. The 6.0-floor armv7+arm64 build passes the binary gates. The app
did not itself use Swift Concurrency, so at that checkpoint `_Concurrency` was not linked into it.
The Foundation-adapter follow-up below changes that closure: Foundation now depends on the embedded
concurrency runtime, even for an app without direct async calls.

### Foundation async adapters follow-up (2026-11-10)

Rebuilt overlays, multiarch, assembly, sanitization and iOS 5 qualification through `build-all.sh`.
Foundation explicitly links the source-built `_Concurrency` runtime for armv7, armv7s and arm64.
Fixed stage error propagation: shell `errexit` had been disabled inside stage functions called under
`||`, allowing a Foundation link failure to surface later as a missing media dependency. A host
regression verifies failed stages neither continue nor receive stamps.

| Verification | Result |
|---|---|
| FoundationAsync on iPod touch iOS 5.1.1, legacy transport | 57 passed, 0 failed, 0 skipped |
| FoundationAsync on iPhone 6 iOS 10.3.3, native transport | 57 passed, 0 failed, 0 skipped; process exit 0 |
| FoundationAsync on iOS 27 simulator, private retagged shipping arm64 runtime | 57 passed, 0 failed, 0 skipped |
| 14 concurrency runtime checks on iPod with Foundation's new dependency | ALL PASS |
| Compiler/import/slice concurrency gates | PASS |
| TestingConcurrency user's original project, iOS 5.0 armv7 through published kit profile | BUILD PASS; project itself has inherited `-disable-availability-checking` (not added by kit command) |

Tests include an in-process HTTP fixture (no external DNS/TLS), upload echo, temporary download
preservation and caller deletion, 404 response handling, cancellation before the slow response and
subsequent session reuse, JSON scalar fragments/struct round trip, path methods, notifications,
buffered file/network bytes and line splitting. Raw logs are retained in the build root; compact
pass-marker evidence is committed with the compiler fork's concurrency tests. Initial path-test
expectations were corrected after comparison with native Foundation (directory trailing slash and
preservation of the prior `.txt` extension). The fixture now disables SIGPIPE on accepted sockets:
a cancelled slow request closes the peer before the fixture writes, otherwise iOS 5 exits 141.

Non-async regression: the rebuilt Neocord2 iOS 5 app launches with the new Foundation→_Concurrency
closure and responds to a main-thread bridge dump (78 views, seven sidebar cells). No new Neocord2
crash report was generated during this recheck.

The user's photo project exposed an additional UIKit gap during launch: the compiled
`UIColor.systemBackground` call reaches missing `+[UIColor systemBackgroundColor]` on iOS 5.
Symbolication of the Objective-C exception site resolved that selector. Missing semantic background
selectors now receive light-appearance fallback colors; modern UIKit implementations are left intact.
After the all-slice rebuild and kit-profile republication, the original app source was rebuilt,
installed in its existing iPod application container and launched normally through SpringBoard.
Clearing stale direct-launch processes resolved a bootstrap registration collision. The fixed app
remained alive (`killall -0 LegacyApp` succeeds), with no crash report newer than the pre-fix tests.
The seven semantic-color regression checks pass on iOS 5; native modern UIKit selectors also pass
on the simulator. A screenshot could not be captured through screenshotr (service unavailable),
so visual/UI correctness of this photo app is not claimed.
The source's original `https://nasa.gov` request was not a JSON photo endpoint. A subsequent
Picsum image URL was also incorrectly sent to JSONDecoder. A direct-image test on iOS 5 proved
`http://http.badssl.com/icons/icon-red.png` returns HTTP 200, 3858 bytes and a decodable 180×180 image;
Picsum's redirect failed SSL (-1200) there. The app now supplies the verified URL directly to its
image loader, with a narrow ATS HTTP exception for that host.

### iOS 10 photo-app crash follow-up

Reproduced the reported iPhone 6 / iOS 10.3.3 abort. A flushed uncaught-exception handler records
`NSInvalidArgumentException: -[__NSPlaceholderArray initWithCapacity:]: capacity (1103101952) is ridiculous`.
The failure occurs before viewDidLoad. A controlled change from UIActivityIndicatorView `.large`
(raw value 101, introduced iOS 13) to `.whiteLarge` makes initialization and all layout finish and
reaches the network/JSON error handler. The UIKit runtime now maps 100→gray and 101→whiteLarge on
systems lacking UIKit's dynamic-color capability, for both initializer and style setter; modern
UIKit stays unchanged. All three slices rebuilt and qualification passed; the kit profile was
republished with 32 matching resource hashes. The diagnostic clone on physical iOS 10 passes all
five spinner values (init/set/animate) and logs `PHOTO IMAGE OK 180.0x180.0, main=true`. Screenshot
`photo-ios10-fixed.png` in the build root shows the image and label. The original bundle identifier's
in-place update was rejected by installation verification; its data was not deleted. A clean normal
unsigned IPA is rebuilt for the user's existing signing/install path. The app's diagnostic handler
and extra spinner checks were removed after verification; its `.large` style remains unchanged.

The final runtime also passes FoundationAsync 57/57 on iOS 5. The same photo/spinner-validation
bundle launched through SpringBoard on the iPod stays alive with no new crash report. Direct CLI
spinner tests are not valid: iOS 5 has no system image table before UIApplicationMain and the
modern simulator's non-bundled UIKit entry also traps. No modern spinner simulator pass is claimed.
The kit app itself rebuilt and code-signature verification passed; restart it to load the generator fix.

The crash also proves a packaging defect: armv7-only executable with fat dylibs loaded armv7s
standard-ABI Core/UIKit/_Concurrency. The kit generator now thins the embedded runtime closure to
armv7 for an armv7-only build. ProjectBuildScriptTests pass and assert both the single-slice
thinning and preservation of combined-build wide slices. Thinning alone does not fix the spinner
exception; it is an independent ABI correctness fix.

The profile was republished against fresh qualification hashes; its generic `deviceExecution` field
remains `pending` rather than reusing old artifact evidence. The exact device adapter executions
are recorded above independently. iOS 7–9 remain untested. No iOS 27 phone run was performed.

Limitations: byte/line adapters currently buffer whole bodies and expose non-native type names;
URL/FileHandle line/byte properties are async rather than native lazy synchronous sequence properties.
FileHandle reads cannot be cancelled while waiting for EOF; restrict them to finite regular files.
URLSession per-request delegates, upload-from-file and resume-data download overloads are not implemented.
Notification streams use unbounded buffering; a bare loop `break` does not promise immediate observer
removal. Existing compiler diagnostics remain enabled for APIs without actual backports. See the fork's
`concurrency-tests/API-INVENTORY.md` for the remaining API inventory.

### Stack view as the first Auto Layout operation (2026-11-10)

TestingAPIs crashed on iPod touch 3 / iOS 5.1.1 before starting its async task. Its first Auto Layout
operation was `UIStackView(arrangedSubviews: [label, button])`. The captured exception was
`-[UILabel setTranslatesAutoresizingMaskIntoConstraints:]: unrecognized selector`, symbolicated to
OAStackView's arranged-subview initialization. Public UIStackView registration inherited directly
from OAStackView, while the UICStackView allocator redirected to that public class; this skipped
the facade initializers which lazily install the iOS 5 Auto Layout bridge. Prior tests constructing
an unrelated constraint first masked the missing initialization.

The fallback public class now inherits UICStackView when the toolchain facade is present. Standalone
OAStackView retains its original fallback, and systems with native UIStackView are untouched.
All three runtime slices rebuilt and static qualification passed; the local kit profile was updated.
The actual user's button was dispatched after launch: Starting, Step 1/5 through Step 5/5, then
Async/Await works, with the button re-enabled and every sample on the main thread. The app remained
alive with no new crash report. Temporary instrumentation was removed and the clean app rebuilt
and reinstalled without changing the user's ViewController or async logic.

Host registration regression passes with actual constructor/facade code; restoring the old superclass
is a required failing negative control. A dedicated first-use UIKit app regression typechecks at the
armv7 iOS 5 and arm64 iOS 7 floors without availability bypass flags. FoundationAsync still passes
57/57 on the iPod. The user's own saved Xcode project has availability checking disabled; no new
bypass was introduced to implement this fix. iOS 6–8 device execution is not newly claimed.

### Layout and composite-control parity follow-up

The first follow-up checked state/liveness but missed zero-sized visible frames. That was insufficient.
Subsequent device verification found and corrected pending-layout flags consumed by the update walk,
zero natural width of centered direct stacks, and no-intrinsic text views receiving zero height while
a title label absorbed all spare height. The direct optimization now declines slack/compression cases
with unmodeled intrinsic semantics and explicit dimension preferences; tight-fitting layouts retain
its fast path. Bounds changes also re-evaluate eligibility.

Native control implementation subviews must not be solved as client-authored geometry. Replaying
stale text-canvas/progress-track frames caused a 480-point text document inside a 280-point viewport
and a 160-point track inside a 280-point progress control. Composite-control ownership is now opaque
unless client subviews explicitly opt into constraints. Public setters still notify controls such as
UISlider; if a setter clamps a required dimension, UIView's native primitive implementation restores
the actual constraint result. Pre-TextKit UITextView additionally needs its native frame-resize
notification to update the WebKit viewport. This is capability-gated and bypasses app overrides.

Final same-launch physical iPod evidence (probe UUID 886E5CFE-1DC2-4A1C-9B7B-F310648CB69A): initial
progress and track both width280; text view280x282 and document/content width280; long log lines wrap;
real button hit-test passes; all six user concurrency tests complete and the app remains alive.
The rendered screenshot was inspected, not merely object properties. Diagnostics/automatic test
invocation were then removed; the clean app was rebuilt/reinstalled, remained alive and had no newer
crash report. The user changed the app during testing and removed the unsupported monospaced font
request themselves; that API was not newly backported.

The proper-lifecycle native simulator suite now compares 116 half-point-normalized observations,
including control internals, required progress height32, slider/button/text-field layout, three text
viewport widths and geometry-setter callback counts. Fresh run tokens, completion markers and required
case checks prevent stale or incomplete output from passing. A pre-correction geometry writer is a
failing native-difference control. Callback/root/fitting and direct-stack priority/free-text-view
regressions pass. Idle direct-stack checks perform zero fitting work; one tiny simulator fixture
measured 2000 dirty/idle passes at native72.204/0.116ms and direct2.888/0.102ms. These timings do not
claim device application performance or universal native parity.

Foundation async remains57/57. A newly exposed Data.write URL failure on iOS5 used iOS7 byte-range
enumeration; the fallback now uses NSData bytes/length with identical write/error handling. Seven file
I/O cases produce the same output as native Foundation. See the compiler fork's Tests/PARITY-GATES.md
and concurrency-tests/evidence/layout-composite-controls-ios5.txt for scope and limits. Exhaustive
pixel, accessibility, animation, every-class/every-OS parity is not claimed; armv7s physical coverage
and iOS6–9 device execution remain absent. No iOS27 phone test was performed.
