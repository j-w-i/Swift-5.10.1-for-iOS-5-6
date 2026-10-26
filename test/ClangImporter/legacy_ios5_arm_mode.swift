// REQUIRES: objc_interop
// REQUIRES: CODEGENERATOR=ARM
// RUN: %empty-directory(%t)
//
// IRGen obtains ARM mode from the importer target configuration. Merely fixing
// Objective-C source compilation or passing LLVM's global -mattr is insufficient.
// Inspect every defined object symbol, including the protocol witness thunk.
// RUN: %swift %s -emit-object -parse-stdlib -disable-legacy-type-info -sdk "" -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -o %t/legacy.o
// RUN: %llvm-nm -m --defined-only %t/legacy.o | %FileCheck %s --check-prefix=ARM
// RUN: %swift %s -emit-assembly -parse-stdlib -disable-legacy-type-info -sdk "" -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -o - | %FileCheck %s --check-prefix=ARM-ASM
//
// Native iOS 6 and non-legacy iOS 5 retain their original Thumb default.
// RUN: %swift %s -emit-object -parse-stdlib -disable-legacy-type-info -sdk "" -target armv7-apple-ios6.0 -enable-legacy-ios5-runtime -o %t/native.o
// RUN: %llvm-nm -m --defined-only %t/native.o | %FileCheck %s --check-prefix=THUMB
// RUN: %swift %s -emit-object -parse-stdlib -disable-legacy-type-info -sdk "" -target armv7-apple-ios5.0 -o %t/disabled.o
// RUN: %llvm-nm -m --defined-only %t/disabled.o | %FileCheck %s --check-prefix=THUMB
//
// An explicit Clang mode selection remains an override of the legacy default.
// RUN: %swift %s -emit-object -parse-stdlib -disable-legacy-type-info -sdk "" -target armv7-apple-ios5.0 -enable-legacy-ios5-runtime -Xcc -mthumb -o %t/override.o
// RUN: %llvm-nm -m --defined-only %t/override.o | %FileCheck %s --check-prefix=THUMB
//
// ARM-NOT: [Thumb]
// ARM: (__TEXT,__text)
// ARM-NOT: [Thumb]
// ARM-ASM-NOT: .thumb_func
// ARM-ASM: .code{{[ \t]+}}32
// ARM-ASM-NOT: .thumb_func
// THUMB: (__TEXT,__text){{.*}}[Thumb]

public protocol LegacyARMModeProbe {
  func invoke()
}

public struct LegacyARMModeWitness: LegacyARMModeProbe {
  public func invoke() {}
}

public func legacyARMModeEntry() {}
