# Foundation Core qualification

These are original MIT-licensed implementations, not copied FoundationCompatKit
prototypes. The prototypes were inspected for scope only. No Swift corelibs or
other third-party parser source is shipped. CFURLComponents is unavailable on
iOS 5, so URL parsing uses a small independent RFC 3986 delimiter parser.

## Runtime integration

The importer must map NSURLComponents, NSURLQueryItem and
NSISO8601DateFormatter class references to FBPURLComponents, FBPURLQueryItem and
FBPISO8601DateFormatter. These are real linkable Objective-C class symbols.
Allocations, factory results, copies and returned query items always preserve
FBP class identity, including on newer systems, so importer-mapped Swift `is` /
`as?` casts work for objects produced by these APIs. URL components and ISO
formatters wrap native objects when their supported surface is available; query
items own immutable copied strings. No `isa` changes, class swizzles or global
`isKindOfClass:` overrides are used. If a native class is absent, a native-name
FBP subclass is registered for dynamic lookup. A raw third-party native object
on newer systems is **not** an FBP instance: arbitrary dynamic class lookup and
cross-boundary downcasts cannot be universally remapped by this runtime shim.
NSTimer installs its
three block selectors with class_addMethod **only when missing**. It never
replaces a native IMP. The initializer IMP has explicit ARC consumed-self /
retained-return ownership, unlike a plain C function.

Core files require ARC and blocks. No CFURLComponents or new Foundation symbol
is linked. Secure decoding uses guarded iOS 6 APIs and type-checked iOS 5 fallback.

## Supported cutoff and intentional exclusions

* NSURLComponents: iOS 8 original component properties/factories, including
  queryItems; user/password, IPv6 literal host, numeric port, relative/base URL,
  path/query/fragment and percent-encoded counterparts. NSURLQueryItem original
  name/value/factory, copying and coding. Delimiters are split before decoding;
  duplicate items, nil versus empty value, empty query and '+' are preserved.
  Native backing requires the entire implemented selector surface, including
  `string` and `queryItems`, plus a real native query-item class. iOS 7's partial
  NSURLComponents and registered FBP aliases therefore use the fallback engine.
  Native-backed URL initialization uses the native URL/base initializer directly.
  Scheme setters use an ASCII first-letter / subsequent alphanumeric `+.-`
  validator, rejecting empty strings and delimiters before mutating state.
  Equality uses native equality when both sides are backed; fallback compares
  encoded component spellings and numeric ports, ignoring an empty port delimiter
  like native. A bounded 14-by-14 differential matrix covers escaped variants,
  case, empty/numeric ports and absent/empty query and fragment; this is not proof
  of every possible URL equality edge.
* Component ranges, percentEncodedQueryItems, URL encoding-invalid-character
  options and newer host/IDNA APIs are **not implemented** and must stay gated.
  Unicode host IDNA uses NSURL only if that runtime supports it; on iOS 5 callers
  should supply ASCII/punycode host names. This is not full current URL parity.
* ISO8601DateFormatter: native NSUInteger bits; iOS 10 internet/full date/full
  time and dash/colon/space/basic layouts, iOS 11 millisecond fraction formatting,
  UTC/numeric offsets. NSDateFormatter is cached and synchronized; mutation
  invalidates the cache. On iOS 10, fractional-second options use the fallback
  engine because the native formatter silently ignores that bit; native fraction
  backing is guarded by iOS 11 availability. Week dates explicitly throw and
  must remain unavailable.
  Arbitrary partial layouts and every native parser permissiveness edge are not
  qualified; do not claim the entire ISO option space is parity-complete. Both
  numeric offset spellings (+0000/+00:00), short hour offsets, lowercase z,
  whitespace, UTC/GMT, and trailing suffixes such as `Zjunk` are accepted like
  native. Sixteen asserted timezone-prefix differentials include native fallback
  interpretation of out-of-range hour/minute prefixes.
  Host ICU success does not prove behavior on iOS5's older ICU; no device result
  is available.
* NSTimer: iOS 10 block scheduled/unscheduled factories and fire-date initializer.
  Existing NSTimer scheduling/invalidation owns target lifetime. UserInfo is nil.

## Reproduce host differential test

From repository root (all outputs remain under the designated build root):

```sh
OUT=/Users/jwalr/legacy-fresh-proof/build-root/foundation-work
xcrun clang -O2 -fobjc-arc -fblocks -DFBP_FORCE_TEST_RUNTIME=1 \
  -framework Foundation -Wno-deprecated-declarations \
  utils/legacy-ios5-mac/vendor/FoundationBackports/Core/*.m \
  utils/legacy-ios5-mac/vendor/FoundationBackports/Tests/CoreParity.m \
  -o "$OUT/core-parity"
"$OUT/core-parity" > "$OUT/core-parity.log" 2>&1
```

The macro disables native backing, so URL and ISO tests genuinely run the
fallback engines under distinct FBP class names beside Apple classes.
For timers it installs the same IMPs under distinct test selectors, exercises
both factories and the initializer, and verifies native IMPs differ. No fake
benchmark aliases. Benchmarks are host-only, include autorelease pools, compare
identical operations, and do not predict iOS5 device performance. Native URLs
are substantially faster; no parity-performance claim is made.

Reviewed fallback host result: **757 checks, 0 failures**, preserving all original
524 checks plus scheme and equality regressions. Inherited NSFormatter rendering /
parsing and copying/keyed coding round trips remain covered. Median of five
10,000-iteration runs, optimized arm64 host build: URL parse + queryItems + string
60.801 ms versus native 7.301 ms (8.328x slower); cached ISO formatting 9.104 ms
versus native 6.919 ms (1.316x slower). URL stage profiles (independent workloads,
not additive): parse-only 34.512 ms, query getter 8.546 ms, string getter 13.769 ms.
The workload contains user/password, port, escaped path, two items and fragment.
Numbers are observations, not guarantees; fallback URL performance is not native
speed. Native-backed wrappers also have overhead (query conversion, identity
wrapping, synchronization); do not describe them as zero-cost forwarding.

Run the same parity source **without** `-DFBP_FORCE_TEST_RUNTIME=1` as well, with
output `core-native-parity`: **754 native-backed checks, 0 failures** (the three
test-only timer IMP assertions are omitted). Invalid surrogate input is
strictly rejected by fallback; the native-backed test intentionally follows
native behavior rather than imposing that fallback-only rule. Independently:

```sh
xcrun clang -O2 -fobjc-arc -fblocks -framework Foundation \
  -Wno-deprecated-declarations \
  utils/legacy-ios5-mac/vendor/FoundationBackports/Core/*.m \
  utils/legacy-ios5-mac/vendor/FoundationBackports/Tests/CoreForwarding.m \
  -o "$OUT/core-forwarding"
"$OUT/core-forwarding" > "$OUT/core-forwarding.log" 2>&1
```

The native-backed identity suite passes **41 checks, 0 failures**, checking FBP
allocation/copy/query-item identity and native semantic outputs, URL/base
initialization, coding and inherited NSFormatter behavior; it does not require
raw native class identity.

Actual ARMv7 compilation passed with both Xcode 13.4.1 clang and the source-built
clang 16. Reproduce from repository root, setting `DEV` to the Xcode installation
and `CLANG` to either compiler (paths are configuration, not source dependencies):

```sh
DEV=/Users/jwalr/Applications/Xcode-13.4.1.app/Contents/Developer
CLANG="$DEV/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
SDK="$DEV/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS15.5.sdk"
for name in FBPURLComponents FBPISO8601DateFormatter FBPTimer; do
  "$CLANG" -target armv7-apple-ios5.0 -isysroot "$SDK" -marm -O2 \
    -fobjc-arc -fblocks -fno-modules -Werror=unguarded-availability \
    -Werror=unguarded-availability-new -Wno-deprecated-declarations \
    -c "utils/legacy-ios5-mac/vendor/FoundationBackports/Core/$name.m" \
    -o "$OUT/$name.o"
done
```

This proves compilation, **not execution on iOS5, iOS7 or iOS10**. Old-runtime
selector and fractional-option gates are source/compile qualified, not results
from an older device or simulator.
