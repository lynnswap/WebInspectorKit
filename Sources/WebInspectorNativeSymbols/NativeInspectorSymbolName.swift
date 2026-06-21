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
    struct Part: Sendable {
        let sourceName: String
        let sourceNameUTF8: [UInt8]
        let itaniumEncodedNamePartUTF8s: [[UInt8]]

        init(sourceName: String) {
            self.sourceName = sourceName
            self.sourceNameUTF8 = Array(sourceName.utf8)
            self.itaniumEncodedNamePartUTF8s = NativeInspectorSymbolName
                .itaniumEncodedNamePartAlternatives(for: sourceName)
                .map { Array($0.utf8) }
        }
    }

    private static func decodedString(_ encodedBytes: [UInt8]) -> String {
        let key: UInt8 = 0xA7
        return String(decoding: encodedBytes.map { $0 ^ key }, as: UTF8.self)
    }

    private static let char8TName = decodedString([0xC4, 0xCF, 0xC6, 0xD5, 0x9F, 0xF8, 0xD3])

    struct Variants {
        let rawNameUTF8: [UInt8]
        let directSearchNameUTF8s: [[UInt8]]

        func contains(_ namePart: Part) -> Bool {
            directSearchNameUTF8s.contains { directSearchNameUTF8 in
                NativeInspectorSymbolName.bytes(directSearchNameUTF8, contain: namePart.sourceNameUTF8)
            }
                || namePart.itaniumEncodedNamePartUTF8s.contains { encodedNamePartUTF8 in
                    NativeInspectorSymbolName.bytes(rawNameUTF8, contain: encodedNamePartUTF8)
                }
        }
    }

    static func variants(for symbolName: String) -> Variants {
        let rawNameUTF8 = Array(symbolName.utf8)
        var directSearchNameUTF8s = isLikelyMangledName(symbolName) ? [] : [rawNameUTF8]
        if isLikelySwiftMangledName(symbolName),
           let swiftDemangledName = unsafe swiftDemangledName(symbolName),
           swiftDemangledName != symbolName {
            directSearchNameUTF8s.append(Array(swiftDemangledName.utf8))
        }
        return Variants(
            rawNameUTF8: rawNameUTF8,
            directSearchNameUTF8s: directSearchNameUTF8s
        )
    }

    @unsafe private static func swiftDemangledName(_ symbolName: String) -> String? {
        guard !symbolName.isEmpty else {
            return symbolName
        }

        return unsafe symbolName.utf8CString.withUnsafeBufferPointer { symbolNameUTF8 in
            let demangledName = unsafe _nativeInspectorSwiftDemangle(
                mangledName: symbolNameUTF8.baseAddress,
                mangledNameLength: UInt(symbolNameUTF8.count - 1),
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
            return unsafe String(cString: demangledName!)
        }
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

    private static func isLikelyMangledName(_ symbolName: String) -> Bool {
        if isLikelySwiftMangledName(symbolName) {
            return true
        }

        let trimmedLeadingUnderscores = symbolName.drop { $0 == "_" }
        return trimmedLeadingUnderscores.hasPrefix("Z")
    }

    private static func isLikelySwiftMangledName(_ symbolName: String) -> Bool {
        if symbolName.hasPrefix("$s")
            || symbolName.hasPrefix("_$s")
            || symbolName.hasPrefix("$S")
            || symbolName.hasPrefix("_$S") {
            return true
        }
        return false
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
}
#endif
