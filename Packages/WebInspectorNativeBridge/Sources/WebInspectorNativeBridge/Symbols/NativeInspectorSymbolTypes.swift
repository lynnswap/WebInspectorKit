#if os(iOS) || os(macOS)
import MachO
import MachOKit

enum NativeInspectorSymbolFailure {
    case sharedCacheUnavailable
    case localSymbolsUnavailable
    case inspectorImageMissing
    case supportImageMissing
    case localSymbolEntryMissing
    case connectDisconnectSymbolMissing
    case runtimeFunctionSymbolMissing
    case resolvedAddressOutsideText
    case resolvedAddressImageMismatch
    case ambiguousSymbolMatch

    var message: String {
        switch self {
        case .sharedCacheUnavailable:
            return "runtime cache unavailable"
        case .localSymbolsUnavailable:
            return "local symbol lookup unavailable"
        case .inspectorImageMissing:
            return "inspector image unavailable"
        case .supportImageMissing:
            return "support image unavailable"
        case .localSymbolEntryMissing:
            return "local symbol entry unavailable"
        case .connectDisconnectSymbolMissing:
            return "attach entry point unavailable"
        case .runtimeFunctionSymbolMissing:
            return "runtime helper unavailable"
        case .resolvedAddressOutsideText:
            return "resolved address invalid"
        case .resolvedAddressImageMismatch:
            return "resolved address image mismatch"
        case .ambiguousSymbolMatch:
            return "symbol lookup ambiguous"
        }
    }
}

enum NativeInspectorSymbolResolutionPhase {
    case loadedImage
    case sharedCache
    case sharedCacheFile
    case fullCache
    case fullCacheFile

    var message: String {
        switch self {
        case .loadedImage:
            return "loaded-image"
        case .sharedCache:
            return "shared-cache"
        case .sharedCacheFile:
            return "shared-cache-file"
        case .fullCache:
            return "full-cache"
        case .fullCacheFile:
            return "full-cache-file"
        }
    }
}

struct LoadedNativeInspectorImage {
    let headerAddress: UInt

    var header: UnsafePointer<mach_header> {
        unsafe UnsafePointer<mach_header>(bitPattern: headerAddress)!
    }
}

struct MachOKitFileBackedLocalSymbols {
    let symbols: MachOFile.Symbols64
    let symbolRange: Range<Int>
}

struct NativeInspectorSymbolLookupFailure: Error {
    let kind: NativeInspectorSymbolFailure
    let detail: String?
}

enum ResolvedNativeInspectorAddress {
    case found(UInt64)
    case missing
    case outsideText(UInt64)
    case ambiguous

    var isFound: Bool {
        if case .found = self {
            return true
        }
        return false
    }
}

struct NativeInspectorSymbolLookupResult: Sendable {
    let functionAddresses: NativeInspectorSymbolAddresses
    let failureReason: String?
    let failureKind: NativeInspectorSymbolFailure?
    let phase: NativeInspectorSymbolResolutionPhase?
    let missingFunctions: [String]
    let source: String?
    let usedConnectDisconnectFallback: Bool
}

enum NativeInspectorSymbolRole: String, Hashable, Sendable {
    case connectFrontend
    case disconnectFrontend
    case stringFromUTF8
    case stringImplToNSString
    case derefStringImpl
    case backendDispatcherDispatch
    case inspectorControllerConnectTarget
    case inspectorControllerDisconnectTarget
}

enum NativeInspectorSymbolOwnerImage: Sendable {
    case webKit
    case javaScriptCore
    case webCore
}

enum NativeInspectorSymbolResolutionPolicy: Sendable {
    case requiredTextSymbol
    case fallbackCallTarget
}

struct NativeInspectorRequiredSymbol: Sendable {
    let role: NativeInspectorSymbolRole
    let ownerImage: NativeInspectorSymbolOwnerImage
    let queries: [NativeInspectorSymbolQuery]
    let resolutionPolicy: NativeInspectorSymbolResolutionPolicy

    func matches(symbolName: String) -> Bool {
        guard mayMatch(rawSymbolName: symbolName) else { return false }
        return matches(decodedName: NativeInspectorSymbolName.decode(symbolName))
    }

    func matches(decodedName: NativeInspectorSymbolName.Decoded) -> Bool {
        queries.contains { $0.matches(decodedName: decodedName) }
    }

    @inline(__always)
    func mayMatch(rawSymbolName: String) -> Bool {
        queries.contains { $0.mayMatch(rawSymbolName: rawSymbolName) }
    }

    @inline(__always)
    @unsafe func mayMatch(symbolNameC: UnsafePointer<CChar>) -> Bool {
        queries.contains { unsafe $0.mayMatch(symbolNameC: symbolNameC) }
    }
}

// C++ names encode parameter types, but generally not return types or object layout.
// The native bridge still owns those ABI assumptions.
struct NativeInspectorSymbolQuery: Sendable {
    private let rawNameNeedles: [NativeInspectorSymbolName.RawNameNeedle]
    private let functionSignature: [UInt8]

    init(functionName: String, parameterTypes: [String]) {
        self.rawNameNeedles = NativeInspectorSymbolName.rawNameNeedles(for: functionName)
        self.functionSignature = NativeInspectorSymbolName.cxxSignatureKey(
            "\(functionName)(\(parameterTypes.joined(separator: ",")))"
        )
    }

    func matches(decodedName: NativeInspectorSymbolName.Decoded) -> Bool {
        decodedName.cxxFunctionSignature == functionSignature
    }

    @inline(__always)
    func mayMatch(rawSymbolName: String) -> Bool {
        rawNameNeedles.allSatisfy { NativeInspectorSymbolName.string(rawSymbolName, containsRawNameNeedle: $0) }
    }

    @inline(__always)
    @unsafe func mayMatch(symbolNameC: UnsafePointer<CChar>) -> Bool {
        rawNameNeedles.allSatisfy { unsafe NativeInspectorSymbolName.cString(symbolNameC, containsRawNameNeedle: $0) }
    }
}

struct NativeInspectorSymbols {
    let connectFrontend: NativeInspectorRequiredSymbol
    let disconnectFrontend: NativeInspectorRequiredSymbol
    let inspectorControllerConnectTargets: NativeInspectorRequiredSymbol
    let inspectorControllerDisconnectTargets: NativeInspectorRequiredSymbol
    let stringFromUTF8: NativeInspectorRequiredSymbol
    let stringImplToNSString: NativeInspectorRequiredSymbol
    let derefStringImpl: NativeInspectorRequiredSymbol
    let backendDispatcherDispatch: NativeInspectorRequiredSymbol
}

struct NativeInspectorResolvedSymbolSet {
    let connectFrontend: ResolvedNativeInspectorAddress
    let disconnectFrontend: ResolvedNativeInspectorAddress
    let stringFromUTF8: ResolvedNativeInspectorAddress
    let stringImplToNSString: ResolvedNativeInspectorAddress
    let derefStringImpl: ResolvedNativeInspectorAddress
    let backendDispatcherDispatch: ResolvedNativeInspectorAddress

    func address(for role: NativeInspectorSymbolRole) -> ResolvedNativeInspectorAddress {
        switch role {
        case .connectFrontend:
            connectFrontend
        case .disconnectFrontend:
            disconnectFrontend
        case .stringFromUTF8:
            stringFromUTF8
        case .stringImplToNSString:
            stringImplToNSString
        case .derefStringImpl:
            derefStringImpl
        case .backendDispatcherDispatch:
            backendDispatcherDispatch
        case .inspectorControllerConnectTarget, .inspectorControllerDisconnectTarget:
            .missing
        }
    }
}

struct NativeInspectorAttachEntryPointFallbackResult {
    let symbols: NativeInspectorResolvedSymbolSet
    let usedFallback: Bool
}
#endif
