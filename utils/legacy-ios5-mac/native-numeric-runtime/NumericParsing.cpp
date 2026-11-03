//===----------------------------------------------------------------------===//
// This source file is part of the Swift.org open source project
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
// See LICENSE.txt, https://swift.org/LICENSE.txt and
// https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors.
//===----------------------------------------------------------------------===//
// Modified source backport: extracted Apple locale Float/Double path from
// stdlib/public/stubs/Stubs.cpp:144-150,280-293,386-449 (Swift 5.10.1).
// Renamed private implementation symbols. Omitted unused `huge` parameter,
// Float80/Float16 and non-Apple platform branches. No ERANGE rejection added.
#include "private/NumericParsing.h"
#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <xlocale.h>

#if !defined(__APPLE__)
#error "This source backport requires Apple's xlocale C-locale semantics"
#endif

static inline locale_t getCLocale() {
  // Apple xlocale convenience functions interpret nullptr as the C locale.
  return nullptr;
}

static bool stringIsSignalingNaN(const char *nptr) {
  if (nptr[0] == '+' || nptr[0] == '-') {
    ++nptr;
  }
  if ((nptr[0] == 's' || nptr[0] == 'S') &&
      (nptr[1] == 'n' || nptr[1] == 'N') &&
      (nptr[2] == 'a' || nptr[2] == 'A') &&
      (nptr[3] == 'n' || nptr[3] == 'N') && (nptr[4] == '\0')) {
    return true;
  }
  return false;
}

template <typename T>
static const char *parseCLocale(
    const char *nptr, T *outResult,
    T (*posixImpl)(const char *, char **, locale_t)) {
  if (stringIsSignalingNaN(nptr)) {
    // Canonical TODO retained: ensure this matches Swift's sNaN bit pattern.
    // Canonical behavior does not copy an input '-' onto this special result.
    *outResult = std::numeric_limits<T>::signaling_NaN();
    return nptr + std::strlen(nptr);
  }
  char *EndPtr;
  errno = 0;
  const auto result = posixImpl(nptr, &EndPtr, getCLocale());
  *outResult = result;
  return EndPtr;
}

const char *swift_legacy510_numeric_strtod(const char *text, double *result) {
  return parseCLocale(text, result, strtod_l);
}

const char *swift_legacy510_numeric_strtof(const char *text, float *result) {
  return parseCLocale(text, result, strtof_l);
}
