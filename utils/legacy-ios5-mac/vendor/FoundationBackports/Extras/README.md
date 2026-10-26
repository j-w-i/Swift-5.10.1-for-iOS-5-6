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
