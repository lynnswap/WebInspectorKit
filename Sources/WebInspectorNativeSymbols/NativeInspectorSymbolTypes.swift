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
    case destroyStringImpl
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
        matches(variants: NativeInspectorSymbolName.variants(for: symbolName))
    }

    func matches(variants: NativeInspectorSymbolName.Variants) -> Bool {
        return queries.contains { $0.matches(variants: variants) }
    }

    @unsafe func matches(cStringVariants: NativeInspectorSymbolName.CStringVariants) -> Bool {
        return queries.contains { unsafe $0.matches(cStringVariants: cStringVariants) }
    }
}

struct NativeInspectorSymbolQuery: Sendable {
    private let requiredNameParts: [NativeInspectorSymbolName.Part]
    private let forbiddenNameParts: [NativeInspectorSymbolName.Part]

    init(
        requiredNameParts: [String],
        forbiddenNameParts: [String] = []
    ) {
        self.requiredNameParts = requiredNameParts.map(NativeInspectorSymbolName.Part.init(sourceName:))
        self.forbiddenNameParts = forbiddenNameParts.map(NativeInspectorSymbolName.Part.init(sourceName:))
    }

    func matches(symbolName: String) -> Bool {
        matches(variants: NativeInspectorSymbolName.variants(for: symbolName))
    }

    func matches(variants: NativeInspectorSymbolName.Variants) -> Bool {
        requiredNameParts.allSatisfy { variants.contains($0) }
            && !forbiddenNameParts.contains { variants.contains($0) }
    }

    @unsafe func matches(cStringVariants: NativeInspectorSymbolName.CStringVariants) -> Bool {
        requiredNameParts.allSatisfy { unsafe cStringVariants.contains($0) }
            && !forbiddenNameParts.contains { unsafe cStringVariants.contains($0) }
    }
}

struct NativeInspectorSymbols {
    let connectFrontend: NativeInspectorRequiredSymbol
    let disconnectFrontend: NativeInspectorRequiredSymbol
    let inspectorControllerConnectTargets: NativeInspectorRequiredSymbol
    let inspectorControllerDisconnectTargets: NativeInspectorRequiredSymbol
    let stringFromUTF8: NativeInspectorRequiredSymbol
    let stringImplToNSString: NativeInspectorRequiredSymbol
    let destroyStringImpl: NativeInspectorRequiredSymbol
    let backendDispatcherDispatch: NativeInspectorRequiredSymbol
}

struct NativeInspectorResolvedSymbolSet {
    let connectFrontend: ResolvedNativeInspectorAddress
    let disconnectFrontend: ResolvedNativeInspectorAddress
    let stringFromUTF8: ResolvedNativeInspectorAddress
    let stringImplToNSString: ResolvedNativeInspectorAddress
    let destroyStringImpl: ResolvedNativeInspectorAddress
    let backendDispatcherDispatch: ResolvedNativeInspectorAddress
}

struct NativeInspectorAttachEntryPointFallbackResult {
    let symbols: NativeInspectorResolvedSymbolSet
    let usedFallback: Bool
}
#endif
