// REQUIRES: objc_interop
// REQUIRES: CODEGENERATOR=ARM
// REQUIRES: CODEGENERATOR=X86

// Inspect the importer invocation without an SDK or standard library. The
// deployment floor alone must not opt in; either legacy spelling enables the
// default, and disabling class marking removes it again.
// RUN: %swift %s -typecheck -parse-stdlib -sdk "" -dump-clang-diagnostics -target armv7-apple-ios5.0 2>&1 | %FileCheck %s --check-prefix=UNCHANGED
// RUN: %swift %s -typecheck -parse-stdlib -sdk "" -dump-clang-diagnostics -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime 2>&1 | %FileCheck %s --check-prefix=LEGACY
// RUN: %swift %s -typecheck -parse-stdlib -sdk "" -dump-clang-diagnostics -target armv7-apple-ios5.0 -enable-legacy-ios5-class-marking 2>&1 | %FileCheck %s --check-prefix=LEGACY
// RUN: %swift %s -typecheck -parse-stdlib -sdk "" -dump-clang-diagnostics -target armv7-apple-ios5.0 -enable-legacy-ios5-class-marking -disable-legacy-ios5-class-marking 2>&1 | %FileCheck %s --check-prefix=UNCHANGED

// iOS 6 and later, macOS, and the simulator keep their existing SDK defaults.
// RUN: %swift %s -typecheck -parse-stdlib -sdk "" -dump-clang-diagnostics -target armv7-apple-ios6.0 -enable-legacy-ios5-runtime 2>&1 | %FileCheck %s --check-prefix=UNCHANGED
// RUN: %swift %s -typecheck -parse-stdlib -sdk "" -dump-clang-diagnostics -target x86_64-apple-macosx10.9 2>&1 | %FileCheck %s --check-prefix=UNCHANGED
// RUN: %swift %s -typecheck -parse-stdlib -sdk "" -dump-clang-diagnostics -target i386-apple-ios5.0-simulator 2>&1 | %FileCheck %s --check-prefix=UNCHANGED

// Check the actual Clang target as well, while the Swift target and legacy
// predicate remain unchanged. This catches accidental use of LangOpts.Target.
// RUN: %swift %s -typecheck -parse-stdlib -sdk "" -dump-clang-diagnostics -target armv7-apple-ios5.0 -enable-legacy-ios5-class-marking -clang-target armv7-apple-ios6.0 2>&1 | %FileCheck %s --check-prefix=UNCHANGED
// RUN: %swift %s -typecheck -parse-stdlib -sdk "" -dump-clang-diagnostics -target armv7-apple-ios5.0 -enable-legacy-ios5-class-marking -clang-target x86_64-apple-macosx10.9 2>&1 | %FileCheck %s --check-prefix=UNCHANGED
// RUN: %swift %s -typecheck -parse-stdlib -sdk "" -dump-clang-diagnostics -target armv7-apple-ios5.0 -enable-legacy-ios5-class-marking -clang-target i386-apple-ios5.0-simulator 2>&1 | %FileCheck %s --check-prefix=UNCHANGED

// This is a default, not a forced setting: explicit Clang options come last.
// RUN: %swift %s -typecheck -parse-stdlib -sdk "" -dump-clang-diagnostics -target armv7-apple-ios5.0 -enable-legacy-ios5-class-marking -Xcc -DOS_OBJECT_SWIFT3=1 2>&1 | %FileCheck %s --check-prefix=OVERRIDE

// LEGACY: '-DOS_OBJECT_SWIFT3=0'
// UNCHANGED-NOT: OS_OBJECT_SWIFT3
// UNCHANGED: '-D__swift__=
// UNCHANGED-NOT: OS_OBJECT_SWIFT3
// OVERRIDE: '-DOS_OBJECT_SWIFT3=0'
// OVERRIDE-SAME: '-DOS_OBJECT_SWIFT3=1'
