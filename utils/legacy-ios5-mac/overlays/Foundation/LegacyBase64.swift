//===--- LegacyBase64.swift - NSData base64 for iOS < 7 -----------------------===//
//
// iOS 5/6 NSData has `base64Encoding` / `initWithBase64Encoding:` but NOT the iOS 7
// `base64EncodedStringWithOptions:` family that the Darwin Foundation overlay's `Data`
// forwards to. Sending those selectors raises `unrecognized selector`.
//
// The implementation below is Apple's swift-corelibs-foundation `NSData.swift`
// (tag swift-5.1.5-RELEASE, `// MARK: - Base64 Methods`), copied UNMODIFIED: it is pure
// Swift with no platform dependency. Only the surrounding namespace differs (an
// `enum`, so the `private static` members become `fileprivate`-reachable helpers).
//
// Compiled only when LEGACY_IOS5 is defined; stock builds use the real NSData methods.
//
//===----------------------------------------------------------------------===//

#if LEGACY_IOS5

import Foundation

@usableFromInline
internal enum _LegacyBase64 {
    @usableFromInline typealias Base64EncodingOptions = NSData.Base64EncodingOptions
    @usableFromInline typealias Base64DecodingOptions = NSData.Base64DecodingOptions

    private static let base64ByteMappings: [Range<UInt8>] = [
        65 ..< 91,      // A-Z
        97 ..< 123,     // a-z
        48 ..< 58,      // 0-9
        43 ..< 44,      // +
        47 ..< 48,      // /
    ]
    /**
     Padding character used when the number of bytes to encode is not divisible by 3
     */
    private static let base64Padding : UInt8 = 61 // =
    
    /**
     This method takes a byte with a character from Base64-encoded string
     and gets the binary value that the character corresponds to.
     
     - parameter byte:       The byte with the Base64 character.
     - returns:              Base64DecodedByte value containing the result (Valid , Invalid, Padding)
     */
    private enum Base64DecodedByte {
        case valid(UInt8)
        case invalid
        case padding
    }

    private static func base64DecodeByte(_ byte: UInt8) -> Base64DecodedByte {
        guard byte != base64Padding else {return .padding}
        var decodedStart: UInt8 = 0
        for range in base64ByteMappings {
            if range.contains(byte) {
                let result = decodedStart + (byte - range.lowerBound)
                return .valid(result)
            }
            decodedStart += range.upperBound - range.lowerBound
        }
        return .invalid
    }
    
    /**
     This method takes six bits of binary data and encodes it as a character
     in Base64.
     
     The value in the byte must be less than 64, because a Base64 character
     can only represent 6 bits.
     
     - parameter byte:       The byte to encode
     - returns:              The ASCII value for the encoded character.
     */
    private static func base64EncodeByte(_ byte: UInt8) -> UInt8 {
        assert(byte < 64)
        var decodedStart: UInt8 = 0
        for range in base64ByteMappings {
            let decodedRange = decodedStart ..< decodedStart + (range.upperBound - range.lowerBound)
            if decodedRange.contains(byte) {
                return range.lowerBound + (byte - decodedStart)
            }
            decodedStart += range.upperBound - range.lowerBound
        }
        return 0
    }

    /**
     This method decodes Base64-encoded data.
     
     If the input contains any bytes that are not valid Base64 characters,
     this will return nil.
     
     - parameter bytes:      The Base64 bytes
     - parameter options:    Options for handling invalid input
     - returns:              The decoded bytes.
     */
    @usableFromInline
    static func base64DecodeBytes(_ bytes: [UInt8], options: Base64DecodingOptions = []) -> [UInt8]? {
        var decodedBytes = [UInt8]()
        decodedBytes.reserveCapacity((bytes.count/3)*2)
        
        var currentByte : UInt8 = 0
        var validCharacterCount = 0
        var paddingCount = 0
        var index = 0
        
        
        for base64Char in bytes {
            
            let value : UInt8
            
            switch base64DecodeByte(base64Char) {
            case .valid(let v):
                value = v
                validCharacterCount += 1
            case .invalid:
                if options.contains(.ignoreUnknownCharacters) {
                    continue
                } else {
                    return nil
                }
            case .padding:
                paddingCount += 1
                continue
            }
            
            //padding found in the middle of the sequence is invalid
            if paddingCount > 0 {
                return nil
            }
            
            switch index%4 {
            case 0:
                currentByte = (value << 2)
            case 1:
                currentByte |= (value >> 4)
                decodedBytes.append(currentByte)
                currentByte = (value << 4)
            case 2:
                currentByte |= (value >> 2)
                decodedBytes.append(currentByte)
                currentByte = (value << 6)
            case 3:
                currentByte |= value
                decodedBytes.append(currentByte)
            default:
                fatalError()
            }
            
            index += 1
        }
        
        guard (validCharacterCount + paddingCount)%4 == 0 else {
            //invalid character count
            return nil
        }
        return decodedBytes
    }

    /**
     This method encodes data in Base64.
     
     - parameter bytes:      The bytes you want to encode
     - parameter options:    Options for formatting the result
     - returns:              The Base64-encoding for those bytes.
     */
    @usableFromInline
    static func base64EncodeBytes(_ bytes: [UInt8], options: Base64EncodingOptions = []) -> [UInt8] {
        var result = [UInt8]()
        result.reserveCapacity((bytes.count/3)*4)
        
        let lineOptions : (lineLength : Int, separator : [UInt8])? = {
            let lineLength: Int
            
            if options.contains(.lineLength64Characters) { lineLength = 64 }
            else if options.contains(.lineLength76Characters) { lineLength = 76 }
            else {
                return nil
            }
            
            var separator = [UInt8]()
            if options.contains(.endLineWithCarriageReturn) { separator.append(13) }
            if options.contains(.endLineWithLineFeed) { separator.append(10) }
            
            //if the kind of line ending to insert is not specified, the default line ending is Carriage Return + Line Feed.
            if separator.isEmpty { separator = [13,10] }
            
            return (lineLength,separator)
        }()
        
        var currentLineCount = 0
        let appendByteToResult : (UInt8) -> Void = {
            result.append($0)
            currentLineCount += 1
            if let options = lineOptions, currentLineCount == options.lineLength {
                result.append(contentsOf: options.separator)
                currentLineCount = 0
            }
        }
        
        var currentByte : UInt8 = 0
        
        for (index,value) in bytes.enumerated() {
            switch index%3 {
            case 0:
                currentByte = (value >> 2)
                appendByteToResult(_LegacyBase64.base64EncodeByte(currentByte))
                currentByte = ((value << 6) >> 2)
            case 1:
                currentByte |= (value >> 4)
                appendByteToResult(_LegacyBase64.base64EncodeByte(currentByte))
                currentByte = ((value << 4) >> 2)
            case 2:
                currentByte |= (value >> 6)
                appendByteToResult(_LegacyBase64.base64EncodeByte(currentByte))
                currentByte = ((value << 2) >> 2)
                appendByteToResult(_LegacyBase64.base64EncodeByte(currentByte))
            default:
                fatalError()
            }
        }
        //add padding
        switch bytes.count%3 {
        case 0: break //no padding needed
        case 1:
            appendByteToResult(_LegacyBase64.base64EncodeByte(currentByte))
            appendByteToResult(self.base64Padding)
            appendByteToResult(self.base64Padding)
        case 2:
            appendByteToResult(_LegacyBase64.base64EncodeByte(currentByte))
            appendByteToResult(self.base64Padding)
        default:
            fatalError()
        }
        return result
    }
}

#endif // LEGACY_IOS5
