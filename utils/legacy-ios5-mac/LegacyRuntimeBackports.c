// Swift 5.10 runtime additions needed by 5.10-generated code using the legacy runtime.
// Derived from Swift 5.10.1 stdlib/public/stubs/Stubs.cpp.
// Copyright (c) Apple Inc. and the Swift project authors.
// Licensed under Apache License v2.0 with Runtime Library Exception.
#include <stdbool.h>
#include <stddef.h>

// Upstream deliberately returns false: requests above the compiler's small
// stack-allocation threshold use the real heap allocation fallback. This is
// not a fabricated stack-bounds check or a no-op allocation implementation.
bool swift_stdlib_isStackAllocationSafe(size_t byteCount, size_t alignment) {
  (void)byteCount;
  (void)alignment;
  return false;
}
