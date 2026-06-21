#if os(iOS) || os(macOS)
import Darwin
import Foundation

@_silgen_name("swift_demangle")
private func _nativeInspectorSwiftDemangle(
    mangledName: UnsafePointer<CChar>?,
    mangledNameLength: UInt,
    outputBuffer: UnsafeMutablePointer<CChar>?,
    outputBufferSize: UnsafeMutablePointer<UInt>?,
    flags: UInt32
) -> UnsafeMutablePointer<CChar>?

enum NativeInspectorSymbolName {
    struct RawNameNeedle: Sendable {
        let string: String
        let utf8: [UInt8]
        let cString: [CChar]

        init(_ string: String) {
            self.string = string
            self.utf8 = Array(string.utf8)
            self.cString = Array(string.utf8CString)
        }
    }

    struct Part: Sendable {
        let sourceName: String
        let sourceNameUTF8: [UInt8]
        let sourceNameCString: [CChar]
        let rawNameNeedle: RawNameNeedle?
        let itaniumEncodedNamePartStrings: [String]
        let itaniumEncodedNamePartCStrings: [[CChar]]

        init(sourceName: String) {
            self.sourceName = sourceName
            self.sourceNameUTF8 = Array(sourceName.utf8)
            self.sourceNameCString = Array(sourceName.utf8CString)
            self.rawNameNeedle = NativeInspectorSymbolName.rawNameNeedle(for: sourceName)
            let itaniumEncodedNamePartAlternatives = NativeInspectorSymbolName
                .itaniumEncodedNamePartAlternatives(for: sourceName)
            self.itaniumEncodedNamePartStrings = itaniumEncodedNamePartAlternatives
            self.itaniumEncodedNamePartCStrings = itaniumEncodedNamePartAlternatives.map { Array($0.utf8CString) }
        }
    }

    private static func decodedString(_ encodedBytes: [UInt8]) -> String {
        let key: UInt8 = 0xA7
        return String(decoding: encodedBytes.map { $0 ^ key }, as: UTF8.self)
    }

    private static let char8TName = decodedString([0xC4, 0xCF, 0xC6, 0xD5, 0x9F, 0xF8, 0xD3])

    struct Variants {
        let rawName: String
        let directSearchNames: [String]

        @inline(__always)
        func contains(_ namePart: Part) -> Bool {
            for directSearchName in directSearchNames {
                if directSearchName.contains(namePart.sourceName) {
                    return true
                }
            }
            for encodedNamePart in namePart.itaniumEncodedNamePartStrings {
                if rawName.contains(encodedNamePart) {
                    return true
                }
            }
            return false
        }

        @inline(__always)
        func containsRawNameNeedle(_ needle: RawNameNeedle) -> Bool {
            for directSearchName in directSearchNames {
                if unsafe NativeInspectorSymbolName.string(directSearchName, containsRawNameNeedle: needle) {
                    return true
                }
            }
            return unsafe NativeInspectorSymbolName.string(rawName, containsRawNameNeedle: needle)
        }
    }

    @unsafe struct CStringVariants {
        let rawName: UnsafePointer<CChar>
        let shouldSearchRawNameDirectly: Bool
        let directSearchNameUTF8s: [[UInt8]]

        @inline(__always)
        @unsafe func contains(_ namePart: Part) -> Bool {
            if unsafe shouldSearchRawNameDirectly,
               unsafe NativeInspectorSymbolName.cString(rawName, contains: namePart.sourceNameCString) {
                return true
            }
            for directSearchNameUTF8 in unsafe directSearchNameUTF8s {
                if NativeInspectorSymbolName.bytes(directSearchNameUTF8, contain: namePart.sourceNameUTF8) {
                    return true
                }
            }
            for encodedNamePartCString in namePart.itaniumEncodedNamePartCStrings {
                if unsafe NativeInspectorSymbolName.cString(rawName, contains: encodedNamePartCString) {
                    return true
                }
            }
            return false
        }

        @inline(__always)
        @unsafe func containsRawNameNeedle(_ needle: RawNameNeedle) -> Bool {
            if unsafe NativeInspectorSymbolName.cString(rawName, contains: needle.cString) {
                return true
            }
            for directSearchNameUTF8 in unsafe directSearchNameUTF8s {
                if NativeInspectorSymbolName.bytes(directSearchNameUTF8, contain: needle.utf8) {
                    return true
                }
            }
            return false
        }
    }

    static func variants(for symbolName: String) -> Variants {
        var directSearchNames = isLikelyMangledName(symbolName) ? [] : [symbolName]
        if isLikelySwiftMangledName(symbolName),
           let swiftDemangledName = unsafe swiftDemangledName(symbolName),
           swiftDemangledName != symbolName {
            directSearchNames.append(swiftDemangledName)
        }
        return Variants(
            rawName: symbolName,
            directSearchNames: directSearchNames
        )
    }

    @unsafe static func variants(for symbolNameC: UnsafePointer<CChar>) -> CStringVariants {
        var directSearchNameUTF8s = [[UInt8]]()
        let isMangled = unsafe isLikelyMangledName(symbolNameC)
        if unsafe isLikelySwiftMangledName(symbolNameC),
           let swiftDemangledNameUTF8 = unsafe swiftDemangledNameUTF8(symbolNameC) {
            directSearchNameUTF8s.append(swiftDemangledNameUTF8)
        }
        return unsafe CStringVariants(
            rawName: symbolNameC,
            shouldSearchRawNameDirectly: !isMangled,
            directSearchNameUTF8s: directSearchNameUTF8s
        )
    }

    @unsafe private static func swiftDemangledName(_ symbolName: String) -> String? {
        guard !symbolName.isEmpty else {
            return symbolName
        }

        guard let symbolNameC = unsafe strdup(symbolName) else {
            return nil
        }
        defer {
            unsafe free(symbolNameC)
        }

        guard let demangledNameUTF8 = unsafe swiftDemangledNameUTF8(symbolNameC) else {
            return nil
        }
        return String(decoding: demangledNameUTF8, as: UTF8.self)
    }

    @unsafe private static func swiftDemangledNameUTF8(_ symbolNameC: UnsafePointer<CChar>) -> [UInt8]? {
        let symbolNameLength = unsafe strlen(symbolNameC)
        guard symbolNameLength > 0 else {
            return []
        }

        let demangledName = unsafe _nativeInspectorSwiftDemangle(
            mangledName: symbolNameC,
            mangledNameLength: UInt(symbolNameLength),
            outputBuffer: nil,
            outputBufferSize: nil,
            flags: 0
        )
        guard unsafe demangledName != nil else {
            return nil
        }
        defer {
            unsafe free(demangledName)
        }

        let demangledNameLength = unsafe strlen(demangledName!)
        let demangledNameBytes = unsafe UnsafeBufferPointer(
            start: UnsafeRawPointer(demangledName!).assumingMemoryBound(to: UInt8.self),
            count: demangledNameLength
        )
        return unsafe Array(demangledNameBytes)
    }

    static func itaniumEncodedNamePartAlternatives(for namePart: String) -> [String] {
        if let operatorRange = namePart.range(of: "::operator ") {
            let ownerName = String(namePart[..<operatorRange.lowerBound])
            let targetName = String(namePart[operatorRange.upperBound...])
            return itaniumEncodedScopedNameAlternatives(for: ownerName).flatMap { ownerName in
                itaniumEncodedTypeAlternatives(for: targetName).flatMap { typeName in
                    [
                        ownerName + "cv" + typeName,
                        ownerName + "cvP" + typeName,
                    ]
                }
            }
        }
        return itaniumEncodedScopedNameAlternatives(for: namePart)
            + itaniumEncodedTypeAlternatives(for: namePart)
    }

    static func rawNameNeedle(for namePart: String) -> RawNameNeedle? {
        let component: String
        if let operatorRange = namePart.range(of: "::operator ") {
            component = String(namePart[operatorRange.upperBound...])
        } else {
            component = namePart
                .split(separator: "::")
                .last
                .map(String.init) ?? namePart
        }

        let trimmedComponent = component.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedComponent.isEmpty,
              trimmedComponent != char8TName else {
            return nil
        }
        return RawNameNeedle(trimmedComponent)
    }

    @inline(__always)
    private static func isLikelyMangledName(_ symbolName: String) -> Bool {
        if isLikelySwiftMangledName(symbolName) {
            return true
        }

        let bytes = symbolName.utf8
        var cursor = bytes.startIndex
        while cursor != bytes.endIndex, bytes[cursor] == 95 {
            bytes.formIndex(after: &cursor)
        }
        return cursor != bytes.endIndex && bytes[cursor] == 90
    }

    @unsafe private static func isLikelyMangledName(_ symbolNameC: UnsafePointer<CChar>) -> Bool {
        if unsafe isLikelySwiftMangledName(symbolNameC) {
            return true
        }

        var cursor = unsafe UnsafeRawPointer(symbolNameC).assumingMemoryBound(to: UInt8.self)
        while unsafe cursor.pointee == 95 {
            unsafe cursor = cursor.advanced(by: 1)
        }
        return unsafe cursor.pointee == 90
    }

    @inline(__always)
    static func isLikelySwiftMangledName(_ symbolName: String) -> Bool {
        let bytes = symbolName.utf8
        guard let first = bytes.first else {
            return false
        }

        if first == 36 {
            let markerIndex = bytes.index(after: bytes.startIndex)
            guard markerIndex != bytes.endIndex else {
                return false
            }
            let marker = bytes[markerIndex]
            return marker == 115 || marker == 83
        }

        if first == 95 {
            let dollarIndex = bytes.index(after: bytes.startIndex)
            guard dollarIndex != bytes.endIndex,
                  bytes[dollarIndex] == 36 else {
                return false
            }
            let markerIndex = bytes.index(after: dollarIndex)
            guard markerIndex != bytes.endIndex else {
                return false
            }
            let marker = bytes[markerIndex]
            return marker == 115 || marker == 83
        }

        return false
    }

    @unsafe static func isLikelySwiftMangledName(_ symbolNameC: UnsafePointer<CChar>) -> Bool {
        let bytes = unsafe UnsafeRawPointer(symbolNameC).assumingMemoryBound(to: UInt8.self)
        switch unsafe bytes.pointee {
        case 36:
            let next = unsafe bytes.advanced(by: 1).pointee
            return next == 115 || next == 83
        case 95:
            let dollar = unsafe bytes.advanced(by: 1).pointee
            let marker = unsafe bytes.advanced(by: 2).pointee
            return dollar == 36 && (marker == 115 || marker == 83)
        default:
            return false
        }
    }

    private static func itaniumEncodedScopedNameAlternatives(for namePart: String) -> [String] {
        let components = namePart
            .split(separator: "::")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !components.isEmpty else {
            return []
        }

        let encodedComponents = components.map { "\($0.utf8.count)\($0)" }.joined()
        if components.count == 1 {
            return [encodedComponents]
        }
        return [
            encodedComponents,
            "N" + encodedComponents + "E",
        ]
    }

    private static func itaniumEncodedTypeAlternatives(for namePart: String) -> [String] {
        // char8_t
        if namePart == char8TName {
            return ["Du"]
        }
        guard !namePart.contains("::"), !namePart.isEmpty else {
            return []
        }
        return ["\(namePart.utf8.count)\(namePart)"]
    }

    @inline(__always)
    private static func bytes(_ haystack: [UInt8], contain needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else {
            return true
        }
        guard needle.count <= haystack.count else {
            return false
        }
        if needle.count == 1 {
            return haystack.contains(needle[0])
        }

        let firstByte = needle[0]
        let lastStartIndex = haystack.count - needle.count
        var haystackIndex = 0
        while haystackIndex <= lastStartIndex {
            if haystack[haystackIndex] == firstByte {
                var needleIndex = 1
                while needleIndex < needle.count,
                      haystack[haystackIndex + needleIndex] == needle[needleIndex] {
                    needleIndex += 1
                }
                if needleIndex == needle.count {
                    return true
                }
            }
            haystackIndex += 1
        }
        return false
    }

    @inline(__always)
    @unsafe
    static func string(_ haystack: String, containsRawNameNeedle needle: RawNameNeedle) -> Bool {
        unsafe haystack.withCString { haystackC in
            unsafe cString(haystackC, contains: needle.cString)
        }
    }

    @inline(__always)
    @unsafe
    static func cString(_ haystack: UnsafePointer<CChar>, containsRawNameNeedle needle: RawNameNeedle) -> Bool {
        unsafe cString(haystack, contains: needle.cString)
    }

    @inline(__always)
    @unsafe
    private static func cString(_ haystack: UnsafePointer<CChar>, contains needle: [CChar]) -> Bool {
        guard needle.count > 1 else {
            return true
        }

        return unsafe needle.withUnsafeBufferPointer { needleBuffer in
            guard let needleBaseAddress = needleBuffer.baseAddress else {
                return false
            }
            return unsafe strstr(haystack, needleBaseAddress) != nil
        }
    }
}
#endif
