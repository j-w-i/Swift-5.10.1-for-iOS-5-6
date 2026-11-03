// REQUIRES: objc_interop
// REQUIRES: CODEGENERATOR=ARM
// REQUIRES: CODEGENERATOR=AArch64
// REQUIRES: CODEGENERATOR=X86
// RUN: %empty-directory(%t)
// RUN: %python %S/Inputs/legacy-optional-objc-witness.py %t %swift
//
// A synthetic UIKit SDK preserves the real availability relationship: UIView's
// gestureRecognizerShouldBegin: is introduced in iOS 6, while the optional
// UIGestureRecognizerDelegate requirement exists in iOS 3.2. No implementation,
// availability lowering, overlay, or installed Apple SDK is involved.
//
// The helper verifies the exact legacy deployment/Clang-target opt-in gate,
// optional Objective-C dispatch, and unchanged diagnostics for required,
// explicit Swift, non-inherited, and direct-call cases. Native iOS 6/7 retain
// their UIView method and optional dispatch. Artifacts stay below %t.
