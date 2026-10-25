// REQUIRES: shell
// RUN: %target-swift-frontend -print-target-info -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime | %FileCheck %s --check-prefix=INFO-LEGACY
// RUN: %target-swift-frontend -print-target-info -target armv7-apple-ios7.0 | %FileCheck %s --check-prefix=INFO-DEFAULT
// RUN: %target-swift-frontend -print-target-info -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -resource-dir /explicit/ios5 | %FileCheck %s --check-prefix=INFO-EXPLICIT
// RUN: not %target-swift-frontend -print-target-info -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -disable-legacy-ios5-class-marking 2>&1 | %FileCheck %s --check-prefix=CONFLICT
// RUN: %empty-directory(%t)
// RUN: mkdir -p %t/resources/iphoneos
// RUN: touch %t/resources/iphoneos/crt1.3.1.o %t/resources/iphoneos/libswiftLegacyIOS5Backports.a
// RUN: %swiftc_driver -sdk "" -target armv7-apple-ios7.0 -driver-print-jobs -enable-legacy-ios5-runtime -resource-dir %t/resources %s 2>&1 | %FileCheck %s --check-prefix=LEGACY
// RUN: %swiftc_driver -sdk "" -target armv7-apple-ios5.0 -driver-print-jobs -enable-legacy-ios5-runtime -resource-dir %t/resources %s 2>&1 | %FileCheck %s --check-prefix=LEGACY
// RUN: %swiftc_driver -sdk "" -target armv7-apple-ios7.0 -driver-print-jobs %s 2>&1 | %FileCheck %s --check-prefix=DEFAULT
// RUN: %swiftc_driver -sdk "" -target armv7-apple-ios7.0 -driver-print-jobs -emit-library -enable-legacy-ios5-runtime -resource-dir %t/resources %s 2>&1 | %FileCheck %s --check-prefix=DYLIB
// RUN: not %swiftc_driver -sdk "" -target armv7-apple-ios7.0 -driver-print-jobs -emit-library -enable-legacy-ios5-runtime -resource-dir %t/missing %s 2>&1 | %FileCheck %s --check-prefix=BACKPORTS-MISSING
// RUN: %swiftc_driver -sdk "" -target armv7-apple-ios7.0 -driver-print-jobs -enable-legacy-ios5-class-marking -resource-dir %t/missing %s 2>&1 | %FileCheck %s --check-prefix=MARKING-ONLY
// RUN: not %swiftc_driver -sdk "" -target armv7-apple-ios7.0 -driver-print-jobs -enable-legacy-ios5-runtime -resource-dir %t/missing %s 2>&1 | %FileCheck %s --check-prefix=MISSING
// RUN: not %swiftc_driver -sdk "" -target armv7-apple-ios7.0 -driver-print-jobs -enable-legacy-ios5-runtime -disable-legacy-ios5-class-marking %s 2>&1 | %FileCheck %s --check-prefix=CONFLICT
// RUN: not %swiftc_driver -sdk "" -target arm64-apple-ios7.0 -driver-print-jobs -enable-legacy-ios5-runtime %s 2>&1 | %FileCheck %s --check-prefix=TARGET
// RUN: not %swiftc_driver -sdk "" -target x86_64-apple-ios7.0-simulator -driver-print-jobs -enable-legacy-ios5-class-marking %s 2>&1 | %FileCheck %s --check-prefix=TARGET

// LEGACY: -enable-legacy-ios5-runtime
// LEGACY: -resource-dir {{.*}}resources
// LEGACY: -no_new_main
// LEGACY-SAME: {{.*}}resources/iphoneos/crt1.3.1.o
// LEGACY-SAME: {{.*}}resources/iphoneos/libswiftLegacyIOS5Backports.a
// LEGACY-SAME: -L {{.*}}resources/iphoneos
// DEFAULT-NOT: legacy-ios5
// DEFAULT-NOT: swift_ios5
// DEFAULT-NOT: -no_new_main
// DEFAULT-NOT: crt1.3.1.o
// DEFAULT: -lobjc
// DEFAULT-NOT: -no_new_main
// DEFAULT-NOT: crt1.3.1.o
// DYLIB: -enable-legacy-ios5-runtime
// DYLIB: -dylib
// DYLIB-NOT: -no_new_main
// DYLIB-NOT: crt1.3.1.o
// DYLIB: {{.*}}resources/iphoneos/libswiftLegacyIOS5Backports.a
// DYLIB-NOT: -force_load
// BACKPORTS-MISSING: error: legacy iOS 5 runtime backports archive is missing:
// BACKPORTS-MISSING-SAME: missing/iphoneos/libswiftLegacyIOS5Backports.a
// MARKING-ONLY: -enable-legacy-ios5-class-marking
// MARKING-ONLY-NOT: libswiftLegacyIOS5Backports.a
// MARKING-ONLY-NOT: -no_new_main
// MISSING: error: legacy iOS 5 executable startup object is missing:
// MISSING-SAME: missing/iphoneos/crt1.3.1.o
// CONFLICT: error: argument '-disable-legacy-ios5-class-marking' is not allowed with '-enable-legacy-ios5-runtime'
// TARGET: error: unsupported option
// INFO-LEGACY: "runtimeResourcePath": "{{.*}}/lib/swift_ios5"
// INFO-DEFAULT: "runtimeResourcePath": "{{.*}}/lib/swift"
// INFO-EXPLICIT: "runtimeResourcePath": "/explicit/ios5"
