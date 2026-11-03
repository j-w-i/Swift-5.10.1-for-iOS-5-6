// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception.
// See ../LICENSE.txt. Modified: private names and imported C boundary only.
#ifndef SWIFT_LEGACY_NATIVE_NUMERIC_PARSING_H
#define SWIFT_LEGACY_NATIVE_NUMERIC_PARSING_H
#ifdef __cplusplus
extern "C" {
#endif
// Build-only header. Neither this header nor its Clang module is installed.
__attribute__((visibility("hidden")))
const char *swift_legacy510_numeric_strtod(const char *text, double *result);
__attribute__((visibility("hidden")))
const char *swift_legacy510_numeric_strtof(const char *text, float *result);
#ifdef __cplusplus
}
#endif
#endif
