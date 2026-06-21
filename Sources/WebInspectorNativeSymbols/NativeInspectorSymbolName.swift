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
    private static func decodedString(_ encodedBytes: [UInt8]) -> String {
        let key: UInt8 = 0xA7
        return String(decoding: encodedBytes.map { $0 ^ key }, as: UTF8.self)
    }

    struct Variants {
        let rawName: String
        let directSearchNames: [String]

        func contains(_ namePart: String) -> Bool {
            directSearchNames.contains { $0.contains(namePart) }
                || NativeInspectorSymbolName.itaniumEncodedNamePartAlternatives(for: namePart).contains { encodedNamePart in
                    rawName.contains(encodedNamePart)
                }
        }
    }

    static func variants(for symbolName: String) -> Variants {
        var directSearchNames = isLikelyMangledName(symbolName) ? [] : [symbolName]
        if let swiftDemangledName = unsafe swiftDemangledName(symbolName),
           swiftDemangledName != symbolName {
            directSearchNames.append(swiftDemangledName)
        }
        return Variants(
            rawName: symbolName,
            directSearchNames: directSearchNames
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

    private static func itaniumEncodedNamePartAlternatives(for namePart: String) -> [String] {
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
        if symbolName.hasPrefix("$s")
            || symbolName.hasPrefix("_$s")
            || symbolName.hasPrefix("$S")
            || symbolName.hasPrefix("_$S") {
            return true
        }

        let trimmedLeadingUnderscores = symbolName.drop { $0 == "_" }
        return trimmedLeadingUnderscores.hasPrefix("Z")
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
        if namePart == decodedString([0xC4, 0xCF, 0xC6, 0xD5, 0x9F, 0xF8, 0xD3]) {
            return ["Du"]
        }
        guard !namePart.contains("::"), !namePart.isEmpty else {
            return []
        }
        return ["\(namePart.utf8.count)\(namePart)"]
    }
}
#endif
