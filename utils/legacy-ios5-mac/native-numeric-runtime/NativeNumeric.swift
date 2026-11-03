//===----------------------------------------------------------------------===//
// This source file is part of the Swift.org open source project
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
// See LICENSE.txt, https://swift.org/LICENSE.txt and
// https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors.
//===----------------------------------------------------------------------===//
// Modified source backport of FloatingPointParsing.swift.gyb:198-219, expanded
// for Float/Double only. Use private imported C helpers and scoped public
// withUnsafeMutablePointer instead of stdlib-internal unprotected pointer API.
// Result/validation semantics are unchanged, including embedded NUL behavior.
@_implementationOnly import _SwiftLegacyNativeNumericPrivate

private func parseDouble(_ text: Substring) -> Double? {
  var result: Double = 0.0
  let success = withUnsafeMutablePointer(to: &result) { p -> Bool in
    text.withCString { chars -> Bool in
      switch chars[0] {
      case 9, 10, 11, 12, 13, 32:
        return false // Reject leading ASCII whitespace
      case 0:
        return false // Reject empty string
      default:
        break
      }
      let endPtr = swift_legacy510_numeric_strtod(chars, p)
      // Intentionally NOT a full Swift-string-length check: match Swift 5.10.
      return endPtr != nil && endPtr![0] == 0
    }
  }
  if !success { return nil }
  return result
}

private func parseFloat(_ text: Substring) -> Float? {
  var result: Float = 0.0
  let success = withUnsafeMutablePointer(to: &result) { p -> Bool in
    text.withCString { chars -> Bool in
      switch chars[0] {
      case 9, 10, 11, 12, 13, 32:
        return false // Reject leading ASCII whitespace
      case 0:
        return false // Reject empty string
      default:
        break
      }
      let endPtr = swift_legacy510_numeric_strtof(chars, p)
      return endPtr != nil && endPtr![0] == 0
    }
  }
  if !success { return nil }
  return result
}

#if NATIVE_NUMERIC_RUNTIME_TESTING
// Internal test-only spellings avoid overriding the host's native symbols.
// This branch is never compiled into the SDK archive; no test module ships.
@inline(never)
func nativeNumericTestDouble(_ text: Substring) -> Double? { parseDouble(text) }
@inline(never)
func nativeNumericTestFloat(_ text: Substring) -> Float? { parseFloat(text) }
#else
@available(iOS 5.0, *)
@_originallyDefinedIn(module: "Swift", iOS 5.0)
extension Double {
  public init?(_ text: Substring) {
    guard let result = parseDouble(text) else { return nil }
    self = result
  }
}

@available(iOS 5.0, *)
@_originallyDefinedIn(module: "Swift", iOS 5.0)
extension Float {
  public init?(_ text: Substring) {
    guard let result = parseFloat(text) else { return nil }
    self = result
  }
}
#endif
