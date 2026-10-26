// REQUIRES: objc_interop
// REQUIRES: CODEGENERATOR=ARM
// REQUIRES: CODEGENERATOR=AArch64
// REQUIRES: CODEGENERATOR=X86
// RUN: %empty-directory(%t)
// RUN: %python %S/Inputs/legacy-foundation.py %t %swift
// Native Foundation capability gating, including inherited availability,
// complete selectors, module ownership, actual Clang target, and iOS 6 no-op.
