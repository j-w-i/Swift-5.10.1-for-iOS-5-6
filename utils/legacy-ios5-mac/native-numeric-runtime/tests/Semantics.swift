// Test executable only. No test declarations are installed into the SDK.
import Darwin

private func doubleBits(_ value: Double?) -> String {
  guard let value = value else { return "nil" }
  return String(value.bitPattern, radix: 16)
}
private func floatBits(_ value: Float?) -> String {
  guard let value = value else { return "nil" }
  return String(value.bitPattern, radix: 16)
}

@main
struct SemanticProbe {
  static func main() {
    #if NATIVE_NUMERIC_REFERENCE
    let parseD: (Substring) -> Double? = { Double($0) }
    let parseF: (Substring) -> Float? = { Float($0) }
    #elseif NATIVE_NUMERIC_CANONICAL_REFERENCE
    let parseD = canonicalReferenceDouble
    let parseF = canonicalReferenceFloat
    #else
    let parseD = nativeNumericTestDouble
    let parseF = nativeNumericTestFloat
    // Directed canonical 5.10 contract; never weaken these to match old Core.
    precondition(parseD("1e9999"[...]) == .infinity)
    precondition(parseF("1e9999"[...]) == .infinity)
    precondition(parseD("-1e-9999"[...])?.bitPattern == 0x8000000000000000)
    precondition(parseF("-1e-9999"[...])?.bitPattern == 0x80000000)
    precondition(parseD("12\0garbage"[...]) == 12)
    precondition(parseF("12\0garbage"[...]) == 12)
    precondition(parseD(" 12"[...]) == nil && parseF("12 "[...]) == nil)
    precondition(parseD(""[...]) == nil && parseF("\0"[...]) == nil)
    precondition(parseD("-sNaN"[...])?.isSignalingNaN == true)
    precondition(parseF("-sNaN"[...])?.isSignalingNaN == true)
    // Canonical C++ numeric_limits special-case ignores the minus sign.
    precondition(parseD("-sNaN"[...])?.sign == .plus)
    precondition(parseF("-sNaN"[...])?.sign == .plus)
    #endif
    var samples = [
      "0", "-0", "+0", "28.375", ".5", "5.", "2837.5e-2", "-1e+3",
      "1.000000059604644775390625", "1.00000000000000011102230246251565404236316680908203125",
      "", "+", "-", ".", "1e", "1e+", "99x", "1_0", "１２", "−1", "1,5",
      "0x1c.6", "0x1.c6p4", "-0X1P-2", "0x", "0x1p", "0x1p+", "0x1p1x",
      "inf", "INFINITY", "-Infinity", "+inf", "infinityx", "infi",
      "nan", "NaN", "+NAN", "-nan", "nan(0x10)", "-nan(0x10)",
      "nan(42)", "nan(0)", "nan(0xffffffffffffffffffffffffffff)",
      "nan(999999999999999999999999999999)", "nan(foo)", "nan(1x)",
      "nan()", "nan(", "nan(42)x", "snan", "-SnAn", "+SNAN", "snan(42)", "snanx",
      "1e9999", "-1e9999", "1e-9999", "-1e-9999",
      "3.4028234663852886e38", "3.4028236e38", "-3.4028236e38",
      "1.1754943508222875e-38", "1.401298464324817e-45", "7.006492321624085e-46",
      "1.7976931348623157e308", "1.7976931348623159e308", "-1.7976931348623159e308",
      "2.2250738585072014e-308", "4.9406564584124654e-324", "2.4703282292062327e-324",
      "0x1p-149", "0x1p-150", "-0x1p-150", "0x1p-1074", "0x1p-1075", "-0x1p-1075",
      "\0", "\012", "12\0", "12\0junk", "-0\0x", "nan\0x", "snan\0x",
      "1.5", "1,5", "\u{a0}1", "1\u{a0}"
    ]
    for whitespace in ["\t", "\n", "\u{b}", "\u{c}", "\r", " "] {
      samples.append(whitespace + "1")
      samples.append("1" + whitespace)
    }
    // Deterministic finite and round-trip cases across magnitudes, no RNG/deps.
    for exponent in [-300, -40, -10, 0, 10, 40, 300] {
      for numerator in [-12345.0, -1.0, 1.0, 12345.0] {
        samples.append(String(numerator * pow(10.0, Double(exponent))))
      }
    }
    let originalLocale = String(cString: setlocale(LC_NUMERIC, nil)!)
    defer { _ = setlocale(LC_NUMERIC, originalLocale) }
    for locale in ["C", "en_US.UTF-8", "fr_FR.UTF-8", "de_DE.UTF-8"] {
      guard setlocale(LC_NUMERIC, locale) != nil else {
        print("SKIP-LOCALE\t\(locale)")
        continue
      }
      let decimal = String(cString: localeconv().pointee.decimal_point)
      print("LOCALE\t\(locale)\tdecimal=\(decimal)")
      for (index, sample) in samples.enumerated() {
        let asciiBase = "unrelated-prefix:" + sample + ":suffix"
        let unicodeBase = "é🙂prefix:" + sample + ":終"
        let asciiStart = asciiBase.index(asciiBase.startIndex, offsetBy: 17)
        let unicodeStart = unicodeBase.index(unicodeBase.startIndex, offsetBy: 9)
        let views: [Substring] = [
          sample[...],
          asciiBase[asciiStart..<asciiBase.index(asciiBase.endIndex, offsetBy: -7)],
          unicodeBase[unicodeStart..<unicodeBase.index(unicodeBase.endIndex, offsetBy: -2)]
        ]
        for (storage, view) in views.enumerated() {
          precondition(String(view) == sample)
          print("\(locale)\t\(index)\t\(storage)\t\(doubleBits(parseD(view)))\t\(floatBits(parseF(view)))\t\(String(reflecting: sample))")
        }
      }
    }
  }
}
