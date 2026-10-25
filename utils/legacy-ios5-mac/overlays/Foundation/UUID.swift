#if LEGACY_IOS5
// Legacy-iOS fork.
//
// The `UUID` struct below is Apple's swift-corelibs-foundation implementation
// (Foundation/UUID.swift, swift-5.1.5-RELEASE), used verbatim apart from removing
// the NSUUID-based `ReferenceConvertible`/`_ObjectiveCBridgeable` extensions -
// `NSUUID` does not exist on iOS 5, so there is nothing to bridge to.
//
// Apple's implementation is platform-independent but calls three helpers that
// swift-corelibs-foundation supplies per platform. On Darwin they are implemented
// here on top of `CFUUID` (available since iOS 2), which has the same semantics.
import CoreFoundation

private func _legacy_uuid_copy_out(_ cf: CFUUID, _ buf: UnsafeMutablePointer<UInt8>) {
    var bytes = CFUUIDGetUUIDBytes(cf)
    withUnsafeBytes(of: &bytes) { raw in
        if let src = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) {
            buf.assign(from: src, count: 16)
        }
    }
}

internal func _cf_uuid_generate_random(_ buf: UnsafeMutablePointer<UInt8>) {
    guard let cf = CFUUIDCreate(nil) else {
        for i in 0..<16 { buf[i] = UInt8(truncatingIfNeeded: Int(arc4random())) }
        return
    }
    _legacy_uuid_copy_out(cf, buf)
}

internal func _cf_uuid_parse(_ str: String, _ buf: UnsafeMutablePointer<UInt8>) -> Int32 {
    guard let cf = CFUUIDCreateFromString(nil, str as CFString) else { return -1 }
    _legacy_uuid_copy_out(cf, buf)
    return 0
}

internal func _cf_uuid_unparse_upper(_ bytes: UnsafePointer<UInt8>,
                                     _ out: UnsafeMutablePointer<CChar>) {
    var raw = CFUUIDBytes()
    withUnsafeMutableBytes(of: &raw) { dst in
        if let base = dst.baseAddress {
            base.copyMemory(from: UnsafeRawPointer(bytes), byteCount: 16)
        }
    }
    guard let cf = CFUUIDCreateFromUUIDBytes(nil, raw),
          let cfStr = CFUUIDCreateString(nil, cf) else {
        out[0] = 0
        return
    }
    let str = cfStr as String
    let utf8 = Array(str.utf8)
    for (i, ch) in utf8.enumerated() { out[i] = CChar(bitPattern: ch) }
    out[utf8.count] = 0
}

// ---- Apple's swift-corelibs-foundation UUID.swift (verbatim; bridging removed) ----

public typealias uuid_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
public typealias uuid_string_t = (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)

/// Represents UUID strings, which can be used to uniquely identify types, interfaces, and other items.
public struct UUID : Hashable, Equatable, CustomStringConvertible {

    public private(set) var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    /* Create a new UUID with RFC 4122 version 4 random bytes */
    public init() {
        withUnsafeMutablePointer(to: &uuid) {
            $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<uuid_t>.size) {
                _cf_uuid_generate_random($0)
            }
        }
    }

    /// Create a UUID from a string such as "E621E1F8-C36C-495A-93FC-0C247A3E6E5F".
    ///
    /// Returns nil for invalid strings.
    public init?(uuidString string: __shared String) {
        let res = withUnsafeMutablePointer(to: &uuid) {
            $0.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<uuid_t>.size) {
                return _cf_uuid_parse(string, $0)
            }
        }
        if res != 0 {
            return nil
        }
    }

    /// Create a UUID from a `uuid_t`.
    public init(uuid: uuid_t) {
        self.uuid = uuid
    }

    /// Returns a string created from the UUID, such as "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
    public var uuidString: String {
        var bytes: uuid_string_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        return withUnsafePointer(to: uuid) { valPtr in
            valPtr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<uuid_t>.size) { val in
                withUnsafeMutablePointer(to: &bytes) { strPtr in
                    strPtr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<uuid_string_t>.size) { str in
                        _cf_uuid_unparse_upper(val, str)
                        return String(cString: str, encoding: .utf8)!
                    }
                }
            }
        }
    }

    public func hash(into hasher: inout Hasher) {
        withUnsafeBytes(of: uuid) { buffer in
            hasher.combine(bytes: buffer)
        }
    }

    public var description: String {
        return uuidString
    }

    public var debugDescription: String {
        return description
    }

    public static func ==(lhs: UUID, rhs: UUID) -> Bool {
        return lhs.uuid.0 == rhs.uuid.0 &&
            lhs.uuid.1 == rhs.uuid.1 &&
            lhs.uuid.2 == rhs.uuid.2 &&
            lhs.uuid.3 == rhs.uuid.3 &&
            lhs.uuid.4 == rhs.uuid.4 &&
            lhs.uuid.5 == rhs.uuid.5 &&
            lhs.uuid.6 == rhs.uuid.6 &&
            lhs.uuid.7 == rhs.uuid.7 &&
            lhs.uuid.8 == rhs.uuid.8 &&
            lhs.uuid.9 == rhs.uuid.9 &&
            lhs.uuid.10 == rhs.uuid.10 &&
            lhs.uuid.11 == rhs.uuid.11 &&
            lhs.uuid.12 == rhs.uuid.12 &&
            lhs.uuid.13 == rhs.uuid.13 &&
            lhs.uuid.14 == rhs.uuid.14 &&
            lhs.uuid.15 == rhs.uuid.15
    }
}

extension UUID : Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let uuidString = try container.decode(String.self)

        guard let uuid = UUID(uuidString: uuidString) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath,
                                                                    debugDescription: "Attempted to decode UUID from invalid UUID string."))
        }

        self = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.uuidString)
    }
}

#else
//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2017 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

@_exported import Foundation // Clang module
import Darwin.uuid
import _SwiftCoreFoundationOverlayShims

/// Represents UUID strings, which can be used to uniquely identify types, interfaces, and other items.
@available(macOS 10.8, iOS 6.0, *)
public struct UUID : ReferenceConvertible, Hashable, Equatable, CustomStringConvertible {
    public typealias ReferenceType = NSUUID

    public private(set) var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    
    /* Create a new UUID with RFC 4122 version 4 random bytes */
    public init() {
        withUnsafeMutablePointer(to: &uuid) {
            $0.withMemoryRebound(to: UInt8.self, capacity: 16) {
                uuid_generate_random($0)
            }
        }
    }
    
    fileprivate init(reference: __shared NSUUID) {
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutablePointer(to: &bytes) {
            $0.withMemoryRebound(to: UInt8.self, capacity: 16) {
                reference.getBytes($0)
            }
        }
        uuid = bytes
    }

    /// Create a UUID from a string such as "E621E1F8-C36C-495A-93FC-0C247A3E6E5F".
    /// 
    /// Returns nil for invalid strings.
    public init?(uuidString string: __shared String) {
        let res = withUnsafeMutablePointer(to: &uuid) {
            $0.withMemoryRebound(to: UInt8.self, capacity: 16) {
                return uuid_parse(string, $0)
            }
        }
        if res != 0 {
            return nil
        }
    }
    
    /// Create a UUID from a `uuid_t`.
    public init(uuid: uuid_t) {
        self.uuid = uuid
    }
    
    /// Returns a string created from the UUID, such as "E621E1F8-C36C-495A-93FC-0C247A3E6E5F"
    public var uuidString: String {
        var bytes: uuid_string_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        return withUnsafePointer(to: uuid) {
            $0.withMemoryRebound(to: UInt8.self, capacity: 16) { val in
                withUnsafeMutablePointer(to: &bytes) {
                    $0.withMemoryRebound(to: Int8.self, capacity: 37) { str in
                        uuid_unparse(val, str)
                        return String(cString: UnsafePointer(str), encoding: .utf8)!
                    }
                }
            }
        }
    }
    
    public func hash(into hasher: inout Hasher) {
        withUnsafeBytes(of: uuid) { buffer in
            hasher.combine(bytes: buffer)
        }
    }

    public var description: String {
        return uuidString
    }

    public var debugDescription: String {
        return description
    }
    
    // MARK: - Bridging Support
    
    fileprivate var reference: NSUUID {
        return withUnsafePointer(to: uuid) {
            $0.withMemoryRebound(to: UInt8.self, capacity: 16) {
                return NSUUID(uuidBytes: $0)
            }
        }
    }

    public static func ==(lhs: UUID, rhs: UUID) -> Bool {
        return lhs.uuid.0 == rhs.uuid.0 &&
            lhs.uuid.1 == rhs.uuid.1 &&
            lhs.uuid.2 == rhs.uuid.2 &&
            lhs.uuid.3 == rhs.uuid.3 &&
            lhs.uuid.4 == rhs.uuid.4 &&
            lhs.uuid.5 == rhs.uuid.5 &&
            lhs.uuid.6 == rhs.uuid.6 &&
            lhs.uuid.7 == rhs.uuid.7 &&
            lhs.uuid.8 == rhs.uuid.8 &&
            lhs.uuid.9 == rhs.uuid.9 &&
            lhs.uuid.10 == rhs.uuid.10 &&
            lhs.uuid.11 == rhs.uuid.11 &&
            lhs.uuid.12 == rhs.uuid.12 &&
            lhs.uuid.13 == rhs.uuid.13 &&
            lhs.uuid.14 == rhs.uuid.14 &&
            lhs.uuid.15 == rhs.uuid.15
    }
}

extension UUID : CustomReflectable {
    public var customMirror: Mirror {
        let c : [(label: String?, value: Any)] = []
        let m = Mirror(self, children:c, displayStyle: Mirror.DisplayStyle.struct)
        return m
    }
}

extension UUID : _ObjectiveCBridgeable {
    @_semantics("convertToObjectiveC")
    public func _bridgeToObjectiveC() -> NSUUID {
        return reference
    }
    
    public static func _forceBridgeFromObjectiveC(_ x: NSUUID, result: inout UUID?) {
        if !_conditionallyBridgeFromObjectiveC(x, result: &result) {
            fatalError("Unable to bridge \(_ObjectiveCType.self) to \(self)")
        }
    }
    
    public static func _conditionallyBridgeFromObjectiveC(_ input: NSUUID, result: inout UUID?) -> Bool {
        result = UUID(reference: input)
        return true
    }

    @_effects(readonly)
    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSUUID?) -> UUID {
        var result: UUID?
        _forceBridgeFromObjectiveC(source!, result: &result)
        return result!
    }
}

extension NSUUID : _HasCustomAnyHashableRepresentation {
    // Must be @nonobjc to avoid infinite recursion during bridging.
    @nonobjc
    public func _toCustomAnyHashable() -> AnyHashable? {
        return AnyHashable(self as UUID)
    }
}

extension UUID : Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let uuidString = try container.decode(String.self)

        guard let uuid = UUID(uuidString: uuidString) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath,
                                                                    debugDescription: "Attempted to decode UUID from invalid UUID string."))
        }

        self = uuid
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.uuidString)
    }
}

#endif // LEGACY_IOS5
