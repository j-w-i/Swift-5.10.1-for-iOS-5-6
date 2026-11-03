// REQUIRES: objc_interop
// REQUIRES: CODEGENERATOR=ARM
// REQUIRES: CODEGENERATOR=X86
// RUN: %empty-directory(%t)
// RUN: %python %S/Inputs/legacy-linebreak.py %t %swift
//
// A synthetic SDK isolates declaration ownership and target gates. The compiler
// must have the normal iOS Swift standard-library modules in its resource dir.
// This is not a runtime shim or an installed SDK/header modification.
