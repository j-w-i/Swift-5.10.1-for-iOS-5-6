# Toolchain-native Foundation backports

FoundationCompatKit's requested APIs are integrated into the existing source-built
`Foundation` module and `libswiftFoundation.dylib`; clients use `import Foundation`
and Apple's names, signatures and task hierarchy, not a Compat module or extra
linker flags. The local Compat packages were audited for scope, not blindly
vendored: their prototype behavior and altered APIs are not suitable for this
runtime. New Objective-C implementations are original MIT-licensed source under
`vendor/FoundationBackports`; the existing Swift overlay retains its upstream
Swift license.

## Guard and runtime

Like UIKit, this is opt-in for a legacy iOS 5 native armv7/armv7s invocation only:
`-enable-legacy-ios5-runtime`, Swift deployment target below 6, and the actual
Clang device target below 6. iOS 6 and ordinary modern compilations retain SDK
availability and linkage. This is not a blanket lowering of Foundation.

The importer retains SDK declarations/API notes and maps implemented class
references to real exported FBP facade class symbols. On newer systems, component,
formatter and session facades use native backing where supported while retaining
FBP instance identity, so imported class casts remain valid. Partial native
surfaces fall back by capability; raw unrelated native objects are not substituted
for facade instances. Existing system methods are never replaced: additional Calendar, String, CharacterSet and Timer
methods are installed only when absent. Delegate protocols retain Apple's runtime
names. The entire source archive is force-loaded internally into Foundation for
legacy builds, not into client projects. Sources are optimized ARM-mode armv7,
with availability warnings treated as errors.

## Scope

| Family | Exposed implementation |
|---|---|
| URL components/query items | Original iOS 7/8 factories, decoded/encoded components, relative/base construction, query items, copying/bridging |
| ISO8601DateFormatter | Internet/full calendar date/time layouts, separators, time zone, millisecond fraction option; cached formatter |
| Timer | iOS 10 scheduled/unscheduled block factories and fire-date initializer |
| Calendar | Same-day, today, yesterday and tomorrow predicates using calendar day intervals/arithmetic |
| String/CharacterSet | Percent encoding/decoding and six URL allowed-character sets using the actual Foundation types |
| Data base64 | Existing upstream-derived legacy decoder/encoder and native options, now available through implemented Swift methods |
| URLSession | Foreground default-configuration data, in-memory upload and download tasks, ordered delegate/completion queue, task registry, cancellation and invalidation |

Unsupported members remain unavailable: background and ephemeral sessions,
WebSocket and stream tasks, resume-data operations, transport suspension,
per-session protocol classes, advanced authentication/redirect callbacks, metrics,
modern URL range/IDNA helpers and ISO week-date layouts. The package's Dispatch
lookalikes are not Foundation APIs and are not added; the actual Dispatch overlay
remains authoritative.

This is **not** a claim that all modern Foundation behavior or performance is
identical on iOS 5. The OS supplies the legacy NSURLConnection/TLS implementation;
backporting API spelling cannot modernize its network security stack. Unicode
host IDNA depends on the old NSURL implementation; ASCII/punycode is the supported
portable path. Raw dynamic lookup and subclass identity can differ from Apple's
private class clusters. See the runtime-specific qualification notes for precise
limits and reproducible tests.

## Build and qualification

`build-all.sh` builds Foundation backports from the clone before overlay build and
links them only into the legacy Foundation runtime. `URLComponentsa.swift` is the
existing upstream value/bridging overlay, now included in the source list.
Unimplemented facade selectors are explicitly unavailable in legacy compilations,
even inside newer-OS availability guards: the facade class reference does not
become a different class at runtime. Nonlegacy compilations remain unchanged.

Host differential tests exercise the FBP implementation alongside native Apple
Foundation, not a forwarding facade. A separate non-forced test verifies native
allocation forwarding. Networking uses deterministic local URLProtocol fixtures.
Host timings are not old-device measurements; source compilation, symbol/import
and initializer audits do not establish device execution. The TestingStuff3
stress app contains the device-side checks for subsequent execution.
