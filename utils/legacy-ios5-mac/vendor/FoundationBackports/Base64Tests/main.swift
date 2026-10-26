// Differential tests compile the ORIGINAL overlay helper into this host executable.
import Foundation
import Dispatch

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let iterations = Int(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "5000")!
precondition(iterations > 0)
var comparisons = 0
var encodingCases = 0
var decodingCases = 0
var validDataComparisons = 0
var validDataMismatches = 0
var differences = [[String: Any]]()
var categories = [String: Int]()
var random: UInt64 = 0xd18f074c9a8b5e31
func nextRandom() -> UInt64 {
    random ^= random << 13; random ^= random >> 7; random ^= random << 17
    return random
}
func describe(_ bytes: [UInt8]?) -> Any {
    guard let bytes = bytes else { return NSNull() }
    return Data(bytes).base64EncodedString()
}
func compare(_ actual: [UInt8]?, _ expected: [UInt8]?, kind: String, label: String, input: [UInt8], options: UInt) {
    comparisons += 1
    let validData = kind.hasPrefix("encode-Data") || kind == "helper-roundtrip" ||
        (kind.hasPrefix("decode-Data") && label.hasPrefix("native-encoded-"))
    if validData { validDataComparisons += 1 }
    guard actual != expected else { return }
    if validData { validDataMismatches += 1 }
    var category = kind
    if kind.hasPrefix("encode"), let actual = actual, let expected = expected {
        var trimmed = actual
        while trimmed.last == 10 || trimmed.last == 13 { trimmed.removeLast() }
        if trimmed == expected { category = "encode-trailing-line-ending" }
        else if options & 3 == 3 { category = "encode-conflicting-line-length-flags" }
    }
    categories[category, default: 0] += 1
    differences.append(["kind": kind, "category": category, "label": label,
                        "inputBase64": Data(input).base64EncodedString(), "inputLength": input.count,
                        "optionsRawValue": options, "helperOutputBase64": describe(actual),
                        "nativeOutputBase64": describe(expected)])
}

let lineFlags: [NSData.Base64EncodingOptions] = [[], .lineLength64Characters, .lineLength76Characters, [.lineLength64Characters, .lineLength76Characters]]
let endingFlags: [NSData.Base64EncodingOptions] = [[], .endLineWithCarriageReturn, .endLineWithLineFeed, [.endLineWithCarriageReturn, .endLineWithLineFeed]]
var encodingOptions = [NSData.Base64EncodingOptions]()
for line in lineFlags { for ending in endingFlags { encodingOptions.append(line.union(ending)) } }
let decodingOptions: [NSData.Base64DecodingOptions] = [[], .ignoreUnknownCharacters]
var vectors = [(String, [UInt8])]()
for count in 0...256 { vectors.append(("length-\(count)", (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 73 &+ 19) })) }
for count in [47, 48, 49, 56, 57, 58, 95, 96, 97, 113, 114, 115, 1023, 1024, 1025, 4096] {
    vectors.append(("line-boundary-\(count)", (0..<count).map { UInt8(truncatingIfNeeded: $0) }))
}
for byte in 0...255 { vectors.append(("single-byte-\(byte)", [UInt8(byte)])) }
vectors.append(("all-byte-values", Array(UInt8.min...UInt8.max)))
for index in 0..<500 {
    let count = Int(nextRandom() % 4097)
    vectors.append(("seeded-random-\(index)-\(count)", (0..<count).map { _ in UInt8(truncatingIfNeeded: nextRandom()) }))
}

func checkDecode(_ bytes: [UInt8], label: String) {
    for options in decodingOptions {
        decodingCases += 1
        let actual = _LegacyBase64.base64DecodeBytes(bytes, options: options)
        let nativeData = Data(base64Encoded: Data(bytes), options: options).map { Array($0) }
        let nativeNSData = NSData(base64Encoded: Data(bytes), options: options).map { Array($0 as Data) }
        compare(actual, nativeData, kind: "decode-Data-bytes", label: label, input: bytes, options: options.rawValue)
        compare(actual, nativeNSData, kind: "decode-NSData-bytes", label: label, input: bytes, options: options.rawValue)
        if let text = String(bytes: bytes, encoding: .utf8) {
            let nativeString = Data(base64Encoded: text, options: options).map { Array($0) }
            compare(actual, nativeString, kind: "decode-Data-string", label: label, input: bytes, options: options.rawValue)
        }
    }
}

for (label, bytes) in vectors {
    let native = Data(bytes)
    for options in encodingOptions {
        encodingCases += 1
        let actual = _LegacyBase64.base64EncodeBytes(bytes, options: options)
        let encoded = Array(native.base64EncodedData(options: options))
        let nsEncoded = Array((native as NSData).base64EncodedString(options: options).utf8)
        let dataString = Array(native.base64EncodedString(options: options).utf8)
        compare(actual, dataString, kind: "encode-Data-string", label: label, input: bytes, options: options.rawValue)
        compare(actual, encoded, kind: "encode-Data", label: label, input: bytes, options: options.rawValue)
        compare(actual, nsEncoded, kind: "encode-NSData", label: label, input: bytes, options: options.rawValue)
        checkDecode(encoded, label: "native-encoded-\(label)-options-\(options.rawValue)")
        // An independent round trip uses the helper's own output, including its
        // formatting choices. Only ignore-unknown is appropriate for wrapped lines.
        compare(_LegacyBase64.base64DecodeBytes(actual, options: .ignoreUnknownCharacters), bytes,
                kind: "helper-roundtrip", label: label, input: actual, options: options.rawValue)
    }
}

let malformed = ["", "=", "==", "===", "====", "========", "A", "AA", "AAA", "AAAA", "A===", "AA==", "AAA=", "AA===", "AA======", "TQ", "TQ=", "TQ==", "TQ===", "TQ======", "T=Q=", "TQ==AA==", "=TQ=", "TWE=", "TWE==", "TWE=====", "TWFu", "TWFu=", "TWFu====", " T Q = = \n", "TQ==\u{0}", "TQ==!", "TQ==\r\n", "TQ==世界", "TQ==💥", "éTQ==", "\u{feff}TQ==", "____", "----", "////", "AB==", "AAB=", "Zg==", "Zh==", "Zm8=", "Zm9="]
for (index, text) in malformed.enumerated() { checkDecode(Array(text.utf8), label: "malformed-\(index)") }
for (index, bytes) in [[UInt8(0xff)], [0xc0, 0xaf], [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0x54, 0x51, 0x3d, 0x3d, 0xff], [0xff, 0x54, 0x51, 0x3d, 0x3d]].enumerated() {
    checkDecode(bytes, label: "invalid-UTF8-\(index)")
}
let alphabet: [UInt8] = [65, 81, 47, 61, 33, 10]
var exhaustiveCases = 0
func enumerate(_ prefix: [UInt8], remaining: Int) {
    if remaining == 0 {
        exhaustiveCases += 1
        checkDecode(prefix, label: "alphabet-exhaustive-\(exhaustiveCases)")
    } else { for byte in alphabet { enumerate(prefix + [byte], remaining: remaining - 1) } }
}
for count in 0...5 { enumerate([], remaining: count) }
for index in 0..<500 {
    let count = Int(nextRandom() % 129)
    checkDecode((0..<count).map { _ in UInt8(truncatingIfNeeded: nextRandom()) }, label: "random-invalid-\(index)")
}

var strictPolicyChecks = 0
var strictPolicyFailures = [String]()
for text in ["=", "==", "===", "====", "========", "A===", "TQ===", "TQ======", "TWE==", "TWE=====", "T=Q=", "TQ==AA=="] {
    for options in decodingOptions {
        strictPolicyChecks += 1
        if _LegacyBase64.base64DecodeBytes(Array(text.utf8), options: options) != nil {
            strictPolicyFailures.append("accepted malformed padding: \(text), options \(options.rawValue)")
        }
    }
}
for (text, expected) in [("AB==", [UInt8(0)]), ("AAB=", [UInt8(0), 0]), ("Zm9=", [UInt8(102), 111])] {
    strictPolicyChecks += 1
    if _LegacyBase64.base64DecodeBytes(Array(text.utf8)) != expected {
        strictPolicyFailures.append("incorrectly rejected nonzero unused pad bits: \(text)")
    }
}

var checksum: UInt64 = 0
func measure(_ label: String, _ body: () -> Void) -> [String: Any] {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    return ["name": label, "iterations": iterations, "payloadBytes": 1024,
            "seconds": elapsed, "nanosecondsPerIteration": elapsed * 1_000_000_000 / Double(iterations),
            "payloadMiBPerSecond": Double(iterations * 1024) / 1_048_576 / elapsed]
}
var payload = (0..<1024).map { UInt8(truncatingIfNeeded: $0) }
let encodedPayload = Array(Data(payload).base64EncodedData())
// Warm all paths before measuring. The checksum keeps actual results observable.
for _ in 0..<100 {
    checksum &+= UInt64(_LegacyBase64.base64EncodeBytes(payload).count)
    checksum &+= UInt64(_LegacyBase64.base64DecodeBytes(encodedPayload)!.count)
}
let performance = [
    measure("helper-encode-1KiB") {
        for index in 0..<iterations {
            payload[0] = UInt8(truncatingIfNeeded: index)
            let result = _LegacyBase64.base64EncodeBytes(payload)
            checksum &+= UInt64(result.count + Int(result[0]))
        }
    },
    measure("native-encode-1KiB") {
        for index in 0..<iterations {
            payload[0] = UInt8(truncatingIfNeeded: index)
            let result = Data(payload).base64EncodedData()
            checksum &+= UInt64(result.count + Int(result[result.startIndex]))
        }
    },
    measure("helper-decode-1KiB") {
        for _ in 0..<iterations {
            let result = _LegacyBase64.base64DecodeBytes(encodedPayload)!
            checksum &+= UInt64(result.count + Int(result[0]))
        }
    },
    measure("native-decode-1KiB") {
        for _ in 0..<iterations {
            let result = Data(base64Encoded: Data(encodedPayload))!
            checksum &+= UInt64(result.count + Int(result[result.startIndex]))
        }
    }
]
let validContract: [String: Any] = ["comparisons": validDataComparisons, "mismatchCount": validDataMismatches,
    "strictPaddingPolicyChecks": strictPolicyChecks, "strictPaddingPolicyFailures": strictPolicyFailures,
    "passed": validDataMismatches == 0 && strictPolicyFailures.isEmpty,
    "policy": "Native Swift Data parity on valid encoded input/all encoding options; strict padding on malformed input; unused pad bits accepted. Supplemental NSData and malformed-native differences remain in the raw report."]
try JSONSerialization.data(withJSONObject: validContract, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("valid-contract.json"))
let report: [String: Any] = ["seed": "0xd18f074c9a8b5e31", "vectors": vectors.count,
    "encodingOptionCombinations": encodingOptions.count, "encodingCases": encodingCases,
    "decodingCases": decodingCases, "exhaustiveMalformedInputs": exhaustiveCases,
    "comparisons": comparisons, "mismatchCount": differences.count, "mismatchCategories": categories,
    "validEncodedDecodeComparisons": vectors.count * encodingOptions.count * decodingOptions.count * 3,
    "validEncodedDecodeMismatchCount": differences.filter { ($0["label"] as? String)?.hasPrefix("native-encoded-") == true }.count,
    "helperRoundtripComparisons": vectors.count * encodingOptions.count,
    "helperRoundtripMismatchCount": differences.filter { ($0["kind"] as? String) == "helper-roundtrip" }.count,
    "defaultEncodingMismatchCount": differences.filter { ($0["kind"] as? String)?.hasPrefix("encode") == true && ($0["optionsRawValue"] as? UInt) == 0 }.count,
    "performance": performance, "benchmarkChecksum": checksum,
    "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
    "validDataContract": validContract,
    "note": "Differential evidence on the reported OS only. Mismatches are recorded, not suppressed; no iOS5 device claim."]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
try JSONSerialization.data(withJSONObject: differences, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("mismatches.json"))
print("Comparisons: \(comparisons); encode cases: \(encodingCases); decode cases: \(decodingCases); mismatches: \(differences.count)")
for (category, count) in categories.sorted(by: { $0.key < $1.key }) { print("  \(category): \(count)") }
for row in performance { print("\(row["name"]!): \(row["nanosecondsPerIteration"]!) ns/iteration; \(row["payloadMiBPerSecond"]!) MiB/s") }
print("Results and ALL mismatches written to \(output.path)")
exit(strictPolicyFailures.isEmpty ? (differences.isEmpty ? 0 : 2) : 1)
