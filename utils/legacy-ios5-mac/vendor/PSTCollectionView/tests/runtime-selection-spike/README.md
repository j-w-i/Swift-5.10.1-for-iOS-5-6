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
