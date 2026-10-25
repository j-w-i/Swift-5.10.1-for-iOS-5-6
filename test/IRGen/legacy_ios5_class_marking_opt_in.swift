// RUN: %swift -target armv7-apple-ios7.0 -parse-stdlib -parse-as-library -module-name LegacyClasses -emit-ir %s -o %t.stock
// RUN: %FileCheck %s --check-prefix=STOCK < %t.stock
// RUN: %swift -target armv7-apple-ios7.0 -parse-stdlib -parse-as-library -module-name LegacyClasses -emit-ir -enable-legacy-ios5-class-marking %s -o %t.legacy
// RUN: %FileCheck %s --check-prefix=LEGACY < %t.legacy
// RUN: %swift -target armv7-apple-ios7.0 -parse-stdlib -parse-as-library -module-name LegacyClasses -emit-ir -enable-legacy-ios5-runtime %s -o %t.runtime
// RUN: diff %t.legacy %t.runtime
// RUN: %swift -target armv7-apple-ios7.0 -parse-stdlib -parse-as-library -module-name LegacyClasses -emit-ir -enable-legacy-ios5-class-marking -disable-legacy-ios5-class-marking %s -o %t.disabled
// RUN: diff %t.stock %t.disabled
// REQUIRES: CPU=armv7 || CPU=arm64 || CPU=x86_64
// REQUIRES: objc_interop

// No SDK/stdlib import: this verifies the ABI selection independently of the
// installed ios5 modules. The deployment floor alone must never opt in.
public class Plain {}
public class Generic<T> {}

// STOCK-DAG: @_DATA_{{.*}}5Plain = {{.*}}{ i32 128,
// STOCK-DAG: @_METACLASS_DATA_{{.*}}5Plain = {{.*}}{ i32 129,
// STOCK-DAG: i32 add (i32 ptrtoint (ptr @_DATA_{{.*}}5Plain to i32), i32 1)
// LEGACY-DAG: @_DATA_{{.*}}5Plain = {{.*}}{ i32 65664,
// LEGACY-DAG: @_METACLASS_DATA_{{.*}}5Plain = {{.*}}{ i32 65665,
// LEGACY-DAG: i32 ptrtoint (ptr @_DATA_{{.*}}5Plain to i32)
// The generic class's RO data is copied by swift_allocateGenericClassMetadata;
// it must carry the same marker as statically emitted class data.
// LEGACY-DAG: { i32 65664,
// LEGACY-DAG: { i32 65665,
