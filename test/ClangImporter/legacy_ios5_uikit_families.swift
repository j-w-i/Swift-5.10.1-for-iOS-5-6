// REQUIRES: objc_interop
// REQUIRES: CODEGENERATOR=ARM
// REQUIRES: CODEGENERATOR=AArch64
// REQUIRES: CODEGENERATOR=X86
// RUN: %empty-directory(%t)
// RUN: %python %S/Inputs/legacy-uikit-families.py %t %swift
//
// The synthetic native SDK tests availability separately from installed runtime
// libraries and the real SDK. Its object payloads avoid any standard-library
// dependency; the importer must preserve the declarations rather than replace
// them with a bridging header or an independently owned compatibility module.
// The helper checks every allowed/denied selector, class-family ceilings,
// iOS 5.0/5.1/6.0/7.0/8.0/9.0/13.0, same-name unrelated modules, and emitted
// Objective-C class/protocol/C linkage. No compiler rebuild is performed.
