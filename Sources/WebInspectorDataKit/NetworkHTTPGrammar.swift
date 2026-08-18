enum NetworkHTTPGrammar {
    static func asciiCaseInsensitiveEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = lhs.utf8
        let rhsBytes = rhs.utf8
        guard lhsBytes.count == rhsBytes.count else {
            return false
        }
        return zip(lhsBytes, rhsBytes).allSatisfy { lhsByte, rhsByte in
            lowercaseASCII(lhsByte) == lowercaseASCII(rhsByte)
        }
    }

    static func lowercaseASCII(_ value: String) -> String {
        String(decoding: value.utf8.map(lowercaseASCII), as: UTF8.self)
    }

    static func lowercaseASCII(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    static func trimOptionalWhitespace(_ value: String) -> String {
        let bytes = value.utf8
        var lowerBound = bytes.startIndex
        var upperBound = bytes.endIndex
        while lowerBound < upperBound, isOptionalWhitespace(bytes[lowerBound]) {
            lowerBound = bytes.index(after: lowerBound)
        }
        while lowerBound < upperBound {
            let preceding = bytes.index(before: upperBound)
            guard isOptionalWhitespace(bytes[preceding]) else {
                break
            }
            upperBound = preceding
        }
        return String(decoding: bytes[lowerBound..<upperBound], as: UTF8.self)
    }

    static func isOptionalWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
    }

    static func isHTTPToken(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.isEmpty == false && bytes.allSatisfy(isHTTPTokenCharacter)
    }

    static func isHTTPTokenCharacter(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...90, 97...122:
            return true
        case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E,
            0x5E, 0x5F, 0x60, 0x7C, 0x7E:
            return true
        default:
            return false
        }
    }
}
