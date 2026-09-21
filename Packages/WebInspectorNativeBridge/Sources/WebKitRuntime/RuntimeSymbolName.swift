#if os(iOS) || os(macOS)
import Darwin
import Foundation
import WebKitRuntimeObjC

enum RuntimeSymbolName {
    struct RawNameNeedle: Sendable {
        let cString: [CChar]

        init(_ string: String) {
            self.cString = Array(string.utf8CString)
        }
    }

    struct Decoded {
        let cxxFunctionSignature: [UInt8]?
    }

    static func decode(_ symbolName: String) -> Decoded {
        symbolName.withCString { name in
            unsafe decode(name)
        }
    }

    @unsafe static func decode(_ symbolNameC: UnsafePointer<CChar>) -> Decoded {
        Decoded(cxxFunctionSignature: unsafe WKRuntimeDemangleCXXSymbol(symbolNameC).map(cxxSignatureKey))
    }

    // Keep identifier boundaries while ignoring the demangler's punctuation spacing.
    // For example, `String const&` must not become the identifier `Stringconst`.
    static func cxxSignatureKey(_ declaration: String) -> [UInt8] {
        var key: [UInt8] = []
        key.reserveCapacity(declaration.utf8.count * 2)
        var inIdentifier = false
        for byte in declaration.utf8 {
            switch byte {
            case 48...57, 65...90, 97...122, 95:
                if !inIdentifier { key.append(0) }
                key.append(byte)
                inIdentifier = true
            case 9...13, 32:
                inIdentifier = false
            default:
                key.append(0)
                key.append(byte)
                inIdentifier = false
            }
        }
        return key
    }

    static func rawNameNeedles(for functionName: String) -> [RawNameNeedle] {
        let component: String
        if let operatorRange = functionName.range(of: "::operator ") {
            component = String(functionName[operatorRange.upperBound...])
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*&")))
        } else {
            component = functionName.split(separator: "::").last.map(String.init) ?? functionName
        }
        // Check the owner before demangling common method names such as `dispatch`.
        let owner = functionName.split(separator: "::").dropLast().last.map(String.init)
        // Itanium has predefined substitutions for these standard-library names.
        let substitutions: Set<String> = ["std", "allocator", "basic_string", "string", "basic_istream", "basic_ostream", "basic_iostream", "istream", "ostream", "iostream"]
        return [owner, component].compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !substitutions.contains($0) }.map(RawNameNeedle.init)
    }

    @inline(__always)
    static func string(_ haystack: String, containsRawNameNeedle needle: RawNameNeedle) -> Bool {
        haystack.withCString { haystackC in
            unsafe cString(haystackC, containsRawNameNeedle: needle)
        }
    }

    @inline(__always)
    @unsafe static func cString(_ haystack: UnsafePointer<CChar>, containsRawNameNeedle needle: RawNameNeedle) -> Bool {
        needle.cString.withUnsafeBufferPointer { needleBuffer in
            unsafe strstr(haystack, needleBuffer.baseAddress!) != nil
        }
    }
}
#endif
