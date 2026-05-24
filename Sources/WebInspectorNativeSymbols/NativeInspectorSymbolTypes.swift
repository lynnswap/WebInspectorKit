#if os(iOS) || os(macOS)
import MachO
import MachOKit

struct ObfuscatedSymbolName: Sendable {
    let key: UInt8
    let encodedBytes: [UInt8]

    func decodedString() -> String {
        String(decoding: encodedBytes.map { $0 ^ key }, as: UTF8.self)
    }
}

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
        }
    }
}

enum NativeInspectorSymbolResolutionPhase {
    case loadedImage
    case sharedCache
    case sharedCacheFile

    var message: String {
        switch self {
        case .loadedImage:
            return "loaded-image"
        case .sharedCache:
            return "shared-cache"
        case .sharedCacheFile:
            return "shared-cache-file"
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

enum NativeInspectorSymbolRole: String, Sendable {
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
    let candidates: [ObfuscatedSymbolName]
    let resolutionPolicy: NativeInspectorSymbolResolutionPolicy

    func decodedCandidates() -> [String] {
        candidates.map { $0.decodedString() }
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
