# Runtime-selection loader experiment

This is an isolated feasibility test, **not** the collection engine or a shipping route.
It changes no device system files. The dylib defines only a `UICollectionView` stand-in
with a marker method; it does not implement collection layout on iOS 5.

Build with `bash build.sh SDK CLANG CRT_DIRECTORY NEW_OUTPUT_DIRECTORY`. The script
builds and signs only. It does not install apps, launch processes, delete bundles,
or respring a device. Check `dependencies.txt`: UIKit must precede the fallback dylib.

## Verified on hardware

A non-UI process calls neither `UIApplicationMain` nor window/application allocation:

| Link dependency order | iOS 5.1.1 | iOS 6.1.3 |
|---|---|---|
| Fallback then UIKit | Not retested as a negative on iOS 5 | Compiled reference selects fallback; runtime lookup selects native; **different class objects** |
| UIKit then fallback | Both select fallback | Both select native |

`binding-uikit-first` exits 0 when the direct and runtime references agree.
`binding-engine-first` exits 2 on iOS 6 when they disagree. Run the negative only as
this non-UI process; never turn it into a GUI app.

The corrected persistent GUI app links UIKit first, returns normally from launch,
creates a root view controller/window, and stays alive. On iOS 6.1.3 it selected
native UICollectionView, laid out native cells, recorded a delayed main-queue callback
and a real button tap, and backgrounded normally when the user pressed Home.
SpringBoard's PID did not change. The user confirmed normal touch and Home operation.

## Earlier freeze investigation

The original experiment had several confounders: fallback-first link order; `exit(0)`
inside `didFinishLaunching`; no root controller/window; a direct root-SSH launch of a
GUI process; hidden launcher errors; and deletion of an installed/running app bundle.
An `anonymous.Spike` process (PID 19170) from the direct launch was still alive after
bundle deletion and repeated resprings. It was terminated before the corrected tests.

These observations do **not** uniquely prove what caused the UI freeze. They establish
a loader identity bug and a leftover GUI process, and demonstrate that the corrected
setup works. A normal persistent flat-namespace control also reached active state and
responded normally. Earlier claims that duplicate classes or flat namespace necessarily
freeze iOS 6, or that the route is impossible, were not justified.

## Limits

Even UIKit-first linkage emits the Objective-C runtime warning that duplicate class
selection is undefined. A passing probe on two OS versions does not remove that risk.
A production design must validate the complete class hierarchy, superclass references,
Swift subclasses/casts/protocols/metadata, library dependency graphs and deployment
packaging. It must not silently change namespace rules for unrelated application code.
The production Swift importer and full PST implementation are not tested here; the
metadata-only Objective-C/Swift probes below cover a narrower necessary condition.

Do not patch UIKit or the dyld shared cache for this experiment. Launch GUI apps
through the device launcher as `mobile`, not as root command-line GUI processes. Do not
remove an app bundle while its process is running. Leave it backgrounded for inspection
or stop the verified application PID before removal.

## Hierarchy and Swift metadata probes

`build.sh` also builds `HierarchyFallback.dylib` and `hierarchy`. Seven metadata-only
stand-ins model collection view, reusable view, cell, layout, flow layout, attributes
and controller. The same program, linked UIKit first, passes 21 checks on each device:
compiled/runtime identity, requested engine, cell/layout inheritance, app-defined
subclasses and Objective-C class membership. Invoke `hierarchy fallback` on iOS 5.1.1
and `hierarchy native` on iOS 6.1.3. No UI application is created.

`build-swift.sh SDK CLANG CRT_DIR NEW_OUT FRONTEND RESOURCE_DIR COMPAT_DIR STDLIB_DIR`
builds that experiment plus `swift-probe`, staging its Swift dylib dependency closure
under a private `Frameworks` directory. Run from a fresh device directory containing
that directory and `HierarchyFallback.dylib`. Do not install those libraries globally.
The same binary returns `Swift typed metadata result=0` on both physical iPods.

The Swift test uses explicitly named imported classes with `objc_runtime_name` equal
to UIKit's native names. This exercises typed Swift subclass metadata and runtime
metatype casts without changing the production importer. It looks classes up by name
before casting so the compiler cannot simply fold known subtype casts to true. It
checks positive cell/reusable and flow/layout casts, a negative flow/reusable cast,
Swift and Objective-C protocol conformance, and canonical ObjC superclasses. It does
not instantiate cells, test their ivar layouts, override UIKit methods, or prove the
production public UIKit spelling/importer path.

The first manual packaging attempt omitted a required `libswift_Concurrency.dylib`
and failed before main; the build script now stages the transitive dependency closure.
The linker still warns about some existing compatibility archive objects carrying an
iOS 7 minimum and newer StringProcessing/RegexParser autolink candidates. The tested
metadata paths execute on iOS 5, but that is not a blanket runtime compatibility claim.

## Full PST implementation experiment

`build-full-engine.sh SDK CLANG CRT_DIRECTORY NEW_OUTPUT_DIRECTORY` generates a private
copy of the PST sources and adds `objc_runtime_name` attributes to eight public class
declarations. It exports native spellings of the header/footer/automatic-size globals.
Original vendor sources are not modified. Internal source names remain PST names.
`PST_TOOLCHAIN_RUNTIME` stays enabled; its constructor sees the now-statically-defined
UICollectionView and does not create/reparent its old wrapper classes.

The generated `RuntimeFallback.dylib` contains the real implementation, not stand-ins.
`engine-identity fallback|native` uses the same hierarchy checks, identifying provider
images rather than a marker method. These passed on iOS 5.1.1 and iOS 6.1.3.

`FullEngineRoute.app` is persistent. The exact same app/dylib bundle passed 15 checks
on both devices: fallback/native provider, canonical identity, visible cells, stored
subclass canary/UILabel ivars, reusable-view casts, 320x50 cell frames, 10,000-point
content height for 200 items, four scroll destinations, prepareForReuse override,
flow-layout override, and willDisplay. Initial run counts:

| OS | Cells constructed | Reuse calls | Layout queries | willDisplay |
|---|---:|---:|---:|---:|
| 5.1.1 | 10 | 15 | 5 | 25 |
| 6.1.3 | 5 | 20 | 4 | 25 |

On the native route only, the app installs the existing Apple collection hooks; it
must not wrap the fallback's already implemented self-sizing machinery on iOS 5.
The user confirmed normal button/Home operation on both iPods. No respring was needed.

Visual inspection found the initial native display had black spaces around each
label. The fixture left collection background colour unspecified; native iOS 6 shows
black through the 280x40 white labels in 320x50 cells, whereas the fallback appeared
white. Explicit white collection backgrounds and clear labels fix the fixture without
changing either engine's defaults. Recaptured screens show no black row gaps; logged
collection/cell/content/label frames match between devices. The iPod touch 5 still
presents this old bundle in legacy 320x480 compatibility mode (scale 2 versus scale 1
on iPod touch 3); the global legacy screen-capture helper also returns a 320x480 image.
That presentation is not proof of a collection geometry discrepancy.

The tests below add real Swift cell-instance and protocol-identity coverage. Still
unverified: the production importer, modern API parity through this new route, animated
mutations, arbitrary dependency graphs and a production-safe solution to duplicate-class
warnings. Shipping routing is unchanged.

## Real Swift cell instances

`build-swift-instances.sh` takes the same eight arguments as `build-swift.sh`. It builds
the real engine, private Swift runtime dependency closure and `SwiftCellRoute.app`.
The same iOS-5-targeted bundle passed 21 checks on both physical iPods: fallback/native
selection, real Swift cell creation, UInt64/String/Array/UILabel state retained through
reuse, positive and negative casts, Swift/ObjC test-protocol conformance, label and cell
geometry, Swift `prepareForReuse` and `layoutSubviews` overrides, flow-layout override,
and exact initial/arrival `willDisplay` counts. The counts are again 10/15/5/25 on iOS 5
and 5/20/4/25 on iOS 6 (created/reused/queries/willDisplay).

The Swift subclass uses test-only imported class spellings with native runtime names,
not the production UIKit importer path. It does not prove every Swift subclass works,
or UIKit delegate/prefetch protocol identity, instance destruction, self-sizing or
animated updates through this new route.

The first Swift instance fixture linked a separate `UICCollectionViewDisplay.m` as well
as the Swift UIKit overlay, which already includes the hook runtime. That produced 50
callbacks on iOS 6 instead of 25. The weak `willDisplay > 0` assertion did not catch it;
manual count review did. The final generator omits the extra source/installer and
requires exact callback counts initially and at every scroll destination. It passes
with 25 callbacks on both routes. Do not link a second hook-runtime copy into an app
already using the overlay. A large Swift numeric-literal comparison also needed an
explicit UInt64 constant to compile with this legacy toolchain; runtime state checks
remain 64-bit.

## Canonical UIKit protocol identities

Initially the generated classes had native runtime names but PST protocols did not.
The non-UI `protocol-identity` negative failed 14/14 checks on iOS 5 and 12/14 on iOS 6:
callback selectors worked, but runtime names, protocol pointer identity and native
conformance did not agree. Native controller conformance accounts for the two passes
on iOS 6. This is a meaningful API defect, not merely a diagnostic warning.

The generator now adds native `objc_runtime_name` attributes to the data-source,
delegate, flow-layout-delegate and prefetch protocols too. `protocol-identity` is built
by `build-full-engine.sh`; it passes 14 checks on each device. The 21 class-hierarchy
checks still pass on each device after this change.

`build-swift-protocols.sh` takes the same eight arguments as `build-swift.sh` and builds
a non-UI combined probe. The same binary passes 24 checks on both devices: canonical
native/fallback protocol identity, Objective-C conformance, Swift casts of an ObjC
source, Swift casts of a Swift source, conformance of that Swift source to both SDK
and fallback declarations, and selected controller conformance. It allocates only
NSObject-based source objects, not a collection or UIApplication. The Swift declarations
remain test-only aliases with native runtime names; public importer integration and
actual delegate/prefetch dispatch through these Swift protocol aliases remain separate.

Capturing command-line stderr also exposes duplicates of private PST helper/wrapper
classes between the existing Swift UIKit overlay and generated fallback library, on
both OS versions. These add to the public UIKit duplicates on iOS 6. Passing these
protocol and cell probes is not a reason to ignore that ambiguity: the generated
private classes need isolation and the instance/API gates need rerunning afterward.
