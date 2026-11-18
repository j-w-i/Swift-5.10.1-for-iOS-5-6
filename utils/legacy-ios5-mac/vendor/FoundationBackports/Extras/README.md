# FoundationBackports Extras

Original implementations (no FoundationCompatKit source copied) of native
Foundation APIs that are missing on the iOS 5 deployment target. They are
installed with `class_addMethod` only when the running OS does not provide the
selector, so iOS 6+ and modern Foundation are untouched.

| Domain | Missing native API | Implementation |
| --- | --- | --- |
| `NSCalendar` | `isDateInToday:`, `isDateInYesterday:`, `isDateInTomorrow:`, `isDate:inSameDayAsDate:` (iOS 8) | `FBPCalendarExtras.m`: calendar day-interval arithmetic (`rangeOfUnit:` + `dateByAddingComponents:`), DST-safe. If the calendar cannot produce a day interval the predicate returns `NO`; there is no 86400 fallback. `BOOL` method encodings are derived from `@encode(BOOL)` (armv7 `c`, modern `B`). |
| `NSString` | `stringByAddingPercentEncodingWithAllowedCharacters:`, `stringByRemovingPercentEncoding` (iOS 7) | `FBPStringExtras.m`: UTF-8 only, strict invalid-sequence `nil`, single-allocation encode/decode buffers, native system URL-set rules. |
| `NSCharacterSet` | `URLUserAllowedCharacterSet`, `URLPasswordAllowedCharacterSet`, `URLHostAllowedCharacterSet`, `URLPathAllowedCharacterSet`, `URLQueryAllowedCharacterSet`, `URLFragmentAllowedCharacterSet` (iOS 7) | `FBPCharacterSetExtras.m`: exact native ASCII membership, one `dispatch_once` singleton per set (safe publish under concurrency), no newer/private C symbols. |
| `NSArray`, `NSMutableArray`, `NSDictionary`, `NSMutableDictionary`, `NSOrderedSet`, `NSMutableOrderedSet` | `objectAtIndexedSubscript:`, `setObject:atIndexedSubscript:`, `objectForKeyedSubscript:`, `setObject:forKeyedSubscript:` (iOS 6; absent on iOS 5.1.1, and ARCLite is not linked) | `FBPSubscriptExtras.m`: forwards to the primitive methods. Index `== count` appends, other bad indexes and `nil` objects raise the native exceptions, `d[k] = nil` removes the key (current Foundation). Selectors registered by name, so the image carries no iOS 6 selector reference. Swift's subscripts on these classes are made available by the importer (`legacyFoundationDeclarationCeiling`). Host tests: `Testing/fbp_subscript_tests.m`; device: `concurrency-tests/FoundationSubscripts.swift`. |
| `objc_lookUpClass` (libobjc) | none: a speed fix (iOS 5-7) | `FBPClassLookupCache.m`: hash and `strcmp` cache keyed on the name's contents, in front of every image's `objc_lookUpClass` lazy pointer, and in front of ARCLite's Swift-name wrapper when it is linked (its `Module.Class` names still resolve). Only non-nil results for image classes are cached: a dynamically allocated class can be disposed and its name reused. Classes are handled as `void *` so ARC never retains them. Scheduled from `+load`, installed on the main queue once ARCLite's `+load` has run; not installed where `objc_readClassPair` exists (iOS 8+). Host tests: `Testing/fbp_lookup_cache_tests.m`; device (with and without ARCLite): `Testing/fbp_lookup_cache_device.m`. |

`FBPExtrasInstaller.m` defines `FBPInstallFoundationExtras()`, called from
`+load`, and the public entry points in `FoundationBackportsExtras.h` let host
tests exercise the implementations directly rather than driving absent native
selectors.

## Tests

`Testing/run-extras-tests.sh [OUT]` builds the host differential tests, compares
every FBP implementation with native Foundation on the host, runs a concurrent
first-use test (also under ThreadSanitizer), compiles the Extras for
`armv7-apple-ios5.0` when `DEVICE_SDK` / `DEVICE_CLANG` are set, and cross-checks
the `LEGACY_IOS5` overlay branches. Outputs default to
`/Users/jwalr/legacy-fresh-proof/build-root/foundation-work/foundation-extras-<stamp>`.
