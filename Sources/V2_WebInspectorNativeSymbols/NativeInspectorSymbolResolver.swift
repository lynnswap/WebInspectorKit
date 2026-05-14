#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

struct ObfuscatedSymbolName: Sendable {
    let key: UInt8
    let encodedBytes: [UInt8]

    func decodedString() -> String {
        String(decoding: encodedBytes.map { $0 ^ key }, as: UTF8.self)
    }
}

private enum NativeInspectorSymbolDiagnostics {
    static let verboseConsoleDiagnosticsEnabled =
        ProcessInfo.processInfo.environment["WEBSPECTOR_VERBOSE_CONSOLE_LOGS"] == "1"
}

private enum NativeInspectorSymbolFailure {
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

private enum NativeInspectorSymbolResolutionPhase {
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

private struct LoadedNativeInspectorImage {
    let headerAddress: UInt

    var header: UnsafePointer<mach_header> {
        unsafe UnsafePointer<mach_header>(bitPattern: headerAddress)!
    }
}

private struct MachOKitFileBackedLocalSymbols {
    let symbols: MachOFile.Symbols64
    let symbolRange: Range<Int>
}

private struct NativeInspectorSymbolLookupFailure: Error {
    let kind: NativeInspectorSymbolFailure
    let detail: String?
}

private enum ResolvedNativeInspectorAddress {
    case found(UInt64)
    case missing
    case outsideText(UInt64)
}

private struct NativeInspectorSymbolLookupResult: Sendable {
    let functionAddresses: NativeInspectorSymbolAddresses
    let failureReason: String?
    let failureKind: NativeInspectorSymbolFailure?
    let phase: NativeInspectorSymbolResolutionPhase?
    let missingFunctions: [String]
    let source: String?
    let usedConnectDisconnectFallback: Bool
}

private enum NativeInspectorSymbolRole: String, Sendable {
    case connectFrontend
    case disconnectFrontend
    case stringFromUTF8
    case stringImplToNSString
    case destroyStringImpl
    case backendDispatcherDispatch
    case inspectorControllerConnectTarget
    case inspectorControllerDisconnectTarget
}

private enum NativeInspectorSymbolOwnerImage: Sendable {
    case webKit
    case javaScriptCore
    case webCore
}

private enum NativeInspectorSymbolResolutionPolicy: Sendable {
    case requiredTextSymbol
    case fallbackCallTarget
}

private struct NativeInspectorRequiredSymbol: Sendable {
    let role: NativeInspectorSymbolRole
    let ownerImage: NativeInspectorSymbolOwnerImage
    let candidates: [ObfuscatedSymbolName]
    let resolutionPolicy: NativeInspectorSymbolResolutionPolicy

    func decodedCandidates() -> [String] {
        candidates.map { $0.decodedString() }
    }
}

private struct NativeInspectorSymbols {
    let connectFrontend: NativeInspectorRequiredSymbol
    let disconnectFrontend: NativeInspectorRequiredSymbol
    let inspectorControllerConnectTargets: NativeInspectorRequiredSymbol
    let inspectorControllerDisconnectTargets: NativeInspectorRequiredSymbol
    let stringFromUTF8: NativeInspectorRequiredSymbol
    let stringImplToNSString: NativeInspectorRequiredSymbol
    let destroyStringImpl: NativeInspectorRequiredSymbol
    let backendDispatcherDispatch: NativeInspectorRequiredSymbol
}

private struct NativeInspectorResolvedSymbolSet {
    let connectFrontend: ResolvedNativeInspectorAddress
    let disconnectFrontend: ResolvedNativeInspectorAddress
    let stringFromUTF8: ResolvedNativeInspectorAddress
    let stringImplToNSString: ResolvedNativeInspectorAddress
    let destroyStringImpl: ResolvedNativeInspectorAddress
    let backendDispatcherDispatch: ResolvedNativeInspectorAddress
}

private struct NativeInspectorAttachEntryPointFallbackResult {
    let symbols: NativeInspectorResolvedSymbolSet
    let usedFallback: Bool
}

private enum NativeInspectorSymbolResolverCore {
    private static func decodedString(_ encodedBytes: [UInt8]) -> String {
        ObfuscatedSymbolName(key: 0xA7, encodedBytes: encodedBytes).decodedString()
    }

    fileprivate static let webKitImagePathSuffixes = [
        // Original: /System/Library/Frameworks/WebKit.framework/WebKit
        decodedString([0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xEB, 0xCE, 0xC5, 0xD5, 0xC6, 0xD5, 0xDE, 0x88, 0xE1, 0xD5, 0xC6, 0xCA, 0xC2, 0xD0, 0xC8, 0xD5, 0xCC, 0xD4, 0x88, 0xF0, 0xC2, 0xC5, 0xEC, 0xCE, 0xD3, 0x89, 0xC1, 0xD5, 0xC6, 0xCA, 0xC2, 0xD0, 0xC8, 0xD5, 0xCC, 0x88, 0xF0, 0xC2, 0xC5, 0xEC, 0xCE, 0xD3]),
        // Original: /System/Library/Frameworks/WebKit.framework/Versions/A/WebKit
        decodedString([0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xEB, 0xCE, 0xC5, 0xD5, 0xC6, 0xD5, 0xDE, 0x88, 0xE1, 0xD5, 0xC6, 0xCA, 0xC2, 0xD0, 0xC8, 0xD5, 0xCC, 0xD4, 0x88, 0xF0, 0xC2, 0xC5, 0xEC, 0xCE, 0xD3, 0x89, 0xC1, 0xD5, 0xC6, 0xCA, 0xC2, 0xD0, 0xC8, 0xD5, 0xCC, 0x88, 0xF1, 0xC2, 0xD5, 0xD4, 0xCE, 0xC8, 0xC9, 0xD4, 0x88, 0xE6, 0x88, 0xF0, 0xC2, 0xC5, 0xEC, 0xCE, 0xD3]),
    ]
    fileprivate static let javaScriptCoreImagePathSuffixes = [
        // Original: /System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore
        decodedString([0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xEB, 0xCE, 0xC5, 0xD5, 0xC6, 0xD5, 0xDE, 0x88, 0xE1, 0xD5, 0xC6, 0xCA, 0xC2, 0xD0, 0xC8, 0xD5, 0xCC, 0xD4, 0x88, 0xED, 0xC6, 0xD1, 0xC6, 0xF4, 0xC4, 0xD5, 0xCE, 0xD7, 0xD3, 0xE4, 0xC8, 0xD5, 0xC2, 0x89, 0xC1, 0xD5, 0xC6, 0xCA, 0xC2, 0xD0, 0xC8, 0xD5, 0xCC, 0x88, 0xED, 0xC6, 0xD1, 0xC6, 0xF4, 0xC4, 0xD5, 0xCE, 0xD7, 0xD3, 0xE4, 0xC8, 0xD5, 0xC2]),
        // Original: /System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore
        decodedString([0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xEB, 0xCE, 0xC5, 0xD5, 0xC6, 0xD5, 0xDE, 0x88, 0xE1, 0xD5, 0xC6, 0xCA, 0xC2, 0xD0, 0xC8, 0xD5, 0xCC, 0xD4, 0x88, 0xED, 0xC6, 0xD1, 0xC6, 0xF4, 0xC4, 0xD5, 0xCE, 0xD7, 0xD3, 0xE4, 0xC8, 0xD5, 0xC2, 0x89, 0xC1, 0xD5, 0xC6, 0xCA, 0xC2, 0xD0, 0xC8, 0xD5, 0xCC, 0x88, 0xF1, 0xC2, 0xD5, 0xD4, 0xCE, 0xC8, 0xC9, 0xD4, 0x88, 0xE6, 0x88, 0xED, 0xC6, 0xD1, 0xC6, 0xF4, 0xC4, 0xD5, 0xCE, 0xD7, 0xD3, 0xE4, 0xC8, 0xD5, 0xC2]),
    ]
    fileprivate static let webCoreImagePathSuffixes = [
        // Original: /System/Library/PrivateFrameworks/WebCore.framework/WebCore
        decodedString([0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xEB, 0xCE, 0xC5, 0xD5, 0xC6, 0xD5, 0xDE, 0x88, 0xF7, 0xD5, 0xCE, 0xD1, 0xC6, 0xD3, 0xC2, 0xE1, 0xD5, 0xC6, 0xCA, 0xC2, 0xD0, 0xC8, 0xD5, 0xCC, 0xD4, 0x88, 0xF0, 0xC2, 0xC5, 0xE4, 0xC8, 0xD5, 0xC2, 0x89, 0xC1, 0xD5, 0xC6, 0xCA, 0xC2, 0xD0, 0xC8, 0xD5, 0xCC, 0x88, 0xF0, 0xC2, 0xC5, 0xE4, 0xC8, 0xD5, 0xC2]),
        // Original: /System/Library/PrivateFrameworks/WebCore.framework/Versions/A/WebCore
        decodedString([0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xEB, 0xCE, 0xC5, 0xD5, 0xC6, 0xD5, 0xDE, 0x88, 0xF7, 0xD5, 0xCE, 0xD1, 0xC6, 0xD3, 0xC2, 0xE1, 0xD5, 0xC6, 0xCA, 0xC2, 0xD0, 0xC8, 0xD5, 0xCC, 0xD4, 0x88, 0xF0, 0xC2, 0xC5, 0xE4, 0xC8, 0xD5, 0xC2, 0x89, 0xC1, 0xD5, 0xC6, 0xCA, 0xC2, 0xD0, 0xC8, 0xD5, 0xCC, 0x88, 0xF1, 0xC2, 0xD5, 0xD4, 0xCE, 0xC8, 0xC9, 0xD4, 0x88, 0xE6, 0x88, 0xF0, 0xC2, 0xC5, 0xE4, 0xC8, 0xD5, 0xC2]),
    ]
    // Original: dyld_shared_cache_
    private static let sharedCacheFilePrefix = decodedString([0xC3, 0xDE, 0xCB, 0xC3, 0xF8, 0xD4, 0xCF, 0xC6, 0xD5, 0xC2, 0xC3, 0xF8, 0xC4, 0xC6, 0xC4, 0xCF, 0xC2, 0xF8])
    // Original: __ZN6WebKit26WebPageInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb
    fileprivate static let connectFrontendSymbol = ObfuscatedSymbolName(key: 0xA7, encodedBytes: [0xF8, 0xF8, 0xFD, 0xE9, 0x91, 0xF0, 0xC2, 0xC5, 0xEC, 0xCE, 0xD3, 0x95, 0x91, 0xF0, 0xC2, 0xC5, 0xF7, 0xC6, 0xC0, 0xC2, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0xE4, 0xC8, 0xC9, 0xD3, 0xD5, 0xC8, 0xCB, 0xCB, 0xC2, 0xD5, 0x96, 0x92, 0xC4, 0xC8, 0xC9, 0xC9, 0xC2, 0xC4, 0xD3, 0xE1, 0xD5, 0xC8, 0xC9, 0xD3, 0xC2, 0xC9, 0xC3, 0xE2, 0xF5, 0xE9, 0x9E, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0x96, 0x92, 0xE1, 0xD5, 0xC8, 0xC9, 0xD3, 0xC2, 0xC9, 0xC3, 0xE4, 0xCF, 0xC6, 0xC9, 0xC9, 0xC2, 0xCB, 0xE2, 0xC5, 0xC5])
    // Original: __ZN6WebKit26WebPageInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE
    fileprivate static let disconnectFrontendSymbol = ObfuscatedSymbolName(key: 0xA7, encodedBytes: [0xF8, 0xF8, 0xFD, 0xE9, 0x91, 0xF0, 0xC2, 0xC5, 0xEC, 0xCE, 0xD3, 0x95, 0x91, 0xF0, 0xC2, 0xC5, 0xF7, 0xC6, 0xC0, 0xC2, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0xE4, 0xC8, 0xC9, 0xD3, 0xD5, 0xC8, 0xCB, 0xCB, 0xC2, 0xD5, 0x96, 0x9F, 0xC3, 0xCE, 0xD4, 0xC4, 0xC8, 0xC9, 0xC9, 0xC2, 0xC4, 0xD3, 0xE1, 0xD5, 0xC8, 0xC9, 0xD3, 0xC2, 0xC9, 0xC3, 0xE2, 0xF5, 0xE9, 0x9E, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0x96, 0x92, 0xE1, 0xD5, 0xC8, 0xC9, 0xD3, 0xC2, 0xC9, 0xC3, 0xE4, 0xCF, 0xC6, 0xC9, 0xC9, 0xC2, 0xCB, 0xE2])
    // Original: __ZN3WTF6String8fromUTF8ENSt3__14spanIKDuLm18446744073709551615EEE
    fileprivate static let stringFromUTF8Symbol = ObfuscatedSymbolName(key: 0xA7, encodedBytes: [0xF8, 0xF8, 0xFD, 0xE9, 0x94, 0xF0, 0xF3, 0xE1, 0x91, 0xF4, 0xD3, 0xD5, 0xCE, 0xC9, 0xC0, 0x9F, 0xC1, 0xD5, 0xC8, 0xCA, 0xF2, 0xF3, 0xE1, 0x9F, 0xE2, 0xE9, 0xF4, 0xD3, 0x94, 0xF8, 0xF8, 0x96, 0x93, 0xD4, 0xD7, 0xC6, 0xC9, 0xEE, 0xEC, 0xE3, 0xD2, 0xEB, 0xCA, 0x96, 0x9F, 0x93, 0x93, 0x91, 0x90, 0x93, 0x93, 0x97, 0x90, 0x94, 0x90, 0x97, 0x9E, 0x92, 0x92, 0x96, 0x91, 0x96, 0x92, 0xE2, 0xE2, 0xE2])
    // Original: __ZN3WTF10StringImplcvP8NSStringEv
    fileprivate static let stringImplToNSStringSymbol = ObfuscatedSymbolName(key: 0xA7, encodedBytes: [0xF8, 0xF8, 0xFD, 0xE9, 0x94, 0xF0, 0xF3, 0xE1, 0x96, 0x97, 0xF4, 0xD3, 0xD5, 0xCE, 0xC9, 0xC0, 0xEE, 0xCA, 0xD7, 0xCB, 0xC4, 0xD1, 0xF7, 0x9F, 0xE9, 0xF4, 0xF4, 0xD3, 0xD5, 0xCE, 0xC9, 0xC0, 0xE2, 0xD1])
    // Original: __ZN3WTF10StringImpl7destroyEPS0_
    fileprivate static let destroyStringImplSymbol = ObfuscatedSymbolName(key: 0xA7, encodedBytes: [0xF8, 0xF8, 0xFD, 0xE9, 0x94, 0xF0, 0xF3, 0xE1, 0x96, 0x97, 0xF4, 0xD3, 0xD5, 0xCE, 0xC9, 0xC0, 0xEE, 0xCA, 0xD7, 0xCB, 0x90, 0xC3, 0xC2, 0xD4, 0xD3, 0xD5, 0xC8, 0xDE, 0xE2, 0xF7, 0xF4, 0x97, 0xF8])
    // Original: __ZN9Inspector17BackendDispatcher8dispatchERKN3WTF6StringE
    fileprivate static let backendDispatcherDispatchSymbol = ObfuscatedSymbolName(key: 0xA7, encodedBytes: [0xF8, 0xF8, 0xFD, 0xE9, 0x9E, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0x96, 0x90, 0xE5, 0xC6, 0xC4, 0xCC, 0xC2, 0xC9, 0xC3, 0xE3, 0xCE, 0xD4, 0xD7, 0xC6, 0xD3, 0xC4, 0xCF, 0xC2, 0xD5, 0x9F, 0xC3, 0xCE, 0xD4, 0xD7, 0xC6, 0xD3, 0xC4, 0xCF, 0xE2, 0xF5, 0xEC, 0xE9, 0x94, 0xF0, 0xF3, 0xE1, 0x91, 0xF4, 0xD3, 0xD5, 0xCE, 0xC9, 0xC0, 0xE2])
    // Original: __ZN7WebCore23PageInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb
    fileprivate static let pageInspectorControllerConnectSymbol = ObfuscatedSymbolName(key: 0xA7, encodedBytes: [0xF8, 0xF8, 0xFD, 0xE9, 0x90, 0xF0, 0xC2, 0xC5, 0xE4, 0xC8, 0xD5, 0xC2, 0x95, 0x94, 0xF7, 0xC6, 0xC0, 0xC2, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0xE4, 0xC8, 0xC9, 0xD3, 0xD5, 0xC8, 0xCB, 0xCB, 0xC2, 0xD5, 0x96, 0x92, 0xC4, 0xC8, 0xC9, 0xC9, 0xC2, 0xC4, 0xD3, 0xE1, 0xD5, 0xC8, 0xC9, 0xD3, 0xC2, 0xC9, 0xC3, 0xE2, 0xF5, 0xE9, 0x9E, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0x96, 0x92, 0xE1, 0xD5, 0xC8, 0xC9, 0xD3, 0xC2, 0xC9, 0xC3, 0xE4, 0xCF, 0xC6, 0xC9, 0xC9, 0xC2, 0xCB, 0xE2, 0xC5, 0xC5])
    // Original: __ZN7WebCore23PageInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE
    fileprivate static let pageInspectorControllerDisconnectSymbol = ObfuscatedSymbolName(key: 0xA7, encodedBytes: [0xF8, 0xF8, 0xFD, 0xE9, 0x90, 0xF0, 0xC2, 0xC5, 0xE4, 0xC8, 0xD5, 0xC2, 0x95, 0x94, 0xF7, 0xC6, 0xC0, 0xC2, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0xE4, 0xC8, 0xC9, 0xD3, 0xD5, 0xC8, 0xCB, 0xCB, 0xC2, 0xD5, 0x96, 0x9F, 0xC3, 0xCE, 0xD4, 0xC4, 0xC8, 0xC9, 0xC9, 0xC2, 0xC4, 0xD3, 0xE1, 0xD5, 0xC8, 0xC9, 0xD3, 0xC2, 0xC9, 0xC3, 0xE2, 0xF5, 0xE9, 0x9E, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0x96, 0x92, 0xE1, 0xD5, 0xC8, 0xC9, 0xD3, 0xC2, 0xC9, 0xC3, 0xE4, 0xCF, 0xC6, 0xC9, 0xC9, 0xC2, 0xCB, 0xE2])
    // Original: __ZN7WebCore24FrameInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb
    fileprivate static let frameInspectorControllerConnectSymbol = ObfuscatedSymbolName(key: 0xA7, encodedBytes: [0xF8, 0xF8, 0xFD, 0xE9, 0x90, 0xF0, 0xC2, 0xC5, 0xE4, 0xC8, 0xD5, 0xC2, 0x95, 0x93, 0xE1, 0xD5, 0xC6, 0xCA, 0xC2, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0xE4, 0xC8, 0xC9, 0xD3, 0xD5, 0xC8, 0xCB, 0xCB, 0xC2, 0xD5, 0x96, 0x92, 0xC4, 0xC8, 0xC9, 0xC9, 0xC2, 0xC4, 0xD3, 0xE1, 0xD5, 0xC8, 0xC9, 0xD3, 0xC2, 0xC9, 0xC3, 0xE2, 0xF5, 0xE9, 0x9E, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0x96, 0x92, 0xE1, 0xD5, 0xC8, 0xC9, 0xD3, 0xC2, 0xC9, 0xC3, 0xE4, 0xCF, 0xC6, 0xC9, 0xC9, 0xC2, 0xCB, 0xE2, 0xC5, 0xC5])
    // Original: __ZN7WebCore24FrameInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE
    fileprivate static let frameInspectorControllerDisconnectSymbol = ObfuscatedSymbolName(key: 0xA7, encodedBytes: [0xF8, 0xF8, 0xFD, 0xE9, 0x90, 0xF0, 0xC2, 0xC5, 0xE4, 0xC8, 0xD5, 0xC2, 0x95, 0x93, 0xE1, 0xD5, 0xC6, 0xCA, 0xC2, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0xE4, 0xC8, 0xC9, 0xD3, 0xD5, 0xC8, 0xCB, 0xCB, 0xC2, 0xD5, 0x96, 0x9F, 0xC3, 0xCE, 0xD4, 0xC4, 0xC8, 0xC9, 0xC9, 0xC2, 0xC4, 0xD3, 0xE1, 0xD5, 0xC8, 0xC9, 0xD3, 0xC2, 0xC9, 0xC3, 0xE2, 0xF5, 0xE9, 0x9E, 0xEE, 0xC9, 0xD4, 0xD7, 0xC2, 0xC4, 0xD3, 0xC8, 0xD5, 0x96, 0x92, 0xE1, 0xD5, 0xC8, 0xC9, 0xD3, 0xC2, 0xC9, 0xC3, 0xE4, 0xCF, 0xC6, 0xC9, 0xC9, 0xC2, 0xCB, 0xE2])
    #if os(iOS)
    private static let sharedCacheDirectoryCandidates = [
        // Original: /System/Library/Caches/com.apple.dyld
        decodedString([0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xEB, 0xCE, 0xC5, 0xD5, 0xC6, 0xD5, 0xDE, 0x88, 0xE4, 0xC6, 0xC4, 0xCF, 0xC2, 0xD4, 0x88, 0xC4, 0xC8, 0xCA, 0x89, 0xC6, 0xD7, 0xD7, 0xCB, 0xC2, 0x89, 0xC3, 0xDE, 0xCB, 0xC3]),
        // Original: /System/Cryptexes/OS/System/Library/Caches/com.apple.dyld
        decodedString([0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xE4, 0xD5, 0xDE, 0xD7, 0xD3, 0xC2, 0xDF, 0xC2, 0xD4, 0x88, 0xE8, 0xF4, 0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xEB, 0xCE, 0xC5, 0xD5, 0xC6, 0xD5, 0xDE, 0x88, 0xE4, 0xC6, 0xC4, 0xCF, 0xC2, 0xD4, 0x88, 0xC4, 0xC8, 0xCA, 0x89, 0xC6, 0xD7, 0xD7, 0xCB, 0xC2, 0x89, 0xC3, 0xDE, 0xCB, 0xC3]),
        // Original: /private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
        decodedString([0x88, 0xD7, 0xD5, 0xCE, 0xD1, 0xC6, 0xD3, 0xC2, 0x88, 0xD7, 0xD5, 0xC2, 0xC5, 0xC8, 0xC8, 0xD3, 0x88, 0xE4, 0xD5, 0xDE, 0xD7, 0xD3, 0xC2, 0xDF, 0xC2, 0xD4, 0x88, 0xE8, 0xF4, 0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xEB, 0xCE, 0xC5, 0xD5, 0xC6, 0xD5, 0xDE, 0x88, 0xE4, 0xC6, 0xC4, 0xCF, 0xC2, 0xD4, 0x88, 0xC4, 0xC8, 0xCA, 0x89, 0xC6, 0xD7, 0xD7, 0xCB, 0xC2, 0x89, 0xC3, 0xDE, 0xCB, 0xC3]),
    ]
    #else
    private static let sharedCacheDirectoryCandidates = [
        // Original: /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld
        decodedString([0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xF1, 0xC8, 0xCB, 0xD2, 0xCA, 0xC2, 0xD4, 0x88, 0xF7, 0xD5, 0xC2, 0xC5, 0xC8, 0xC8, 0xD3, 0x88, 0xE4, 0xD5, 0xDE, 0xD7, 0xD3, 0xC2, 0xDF, 0xC2, 0xD4, 0x88, 0xE8, 0xF4, 0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xEB, 0xCE, 0xC5, 0xD5, 0xC6, 0xD5, 0xDE, 0x88, 0xC3, 0xDE, 0xCB, 0xC3]),
        // Original: /System/Library/dyld
        decodedString([0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xEB, 0xCE, 0xC5, 0xD5, 0xC6, 0xD5, 0xDE, 0x88, 0xC3, 0xDE, 0xCB, 0xC3]),
        // Original: /System/Cryptexes/OS/System/Library/dyld
        decodedString([0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xE4, 0xD5, 0xDE, 0xD7, 0xD3, 0xC2, 0xDF, 0xC2, 0xD4, 0x88, 0xE8, 0xF4, 0x88, 0xF4, 0xDE, 0xD4, 0xD3, 0xC2, 0xCA, 0x88, 0xEB, 0xCE, 0xC5, 0xD5, 0xC6, 0xD5, 0xDE, 0x88, 0xC3, 0xDE, 0xCB, 0xC3]),
    ]
    #endif

    private static let cachedResolution = resolve(
        imagePathSuffixes: webKitImagePathSuffixes,
        javaScriptCorePathSuffixes: javaScriptCoreImagePathSuffixes,
        symbols: currentSymbolNames()
    )

    static func resolveCurrentWebKitAttachSymbols() -> NativeInspectorSymbolLookupResult {
        cachedResolution
    }

    static func resolveForTesting(
        imagePathSuffixes: [String] = webKitImagePathSuffixes,
        connectSymbol: ObfuscatedSymbolName = connectFrontendSymbol,
        disconnectSymbol: ObfuscatedSymbolName = disconnectFrontendSymbol,
        alternateConnectSymbols: [ObfuscatedSymbolName] = [],
        alternateDisconnectSymbols: [ObfuscatedSymbolName] = [],
        stringFromUTF8Symbol: ObfuscatedSymbolName? = nil,
        stringImplToNSStringSymbol: ObfuscatedSymbolName? = nil,
        destroyStringImplSymbol: ObfuscatedSymbolName? = nil,
        backendDispatcherDispatchSymbol: ObfuscatedSymbolName? = nil
    ) -> NativeInspectorSymbolLookupResult {
        resolve(
            imagePathSuffixes: imagePathSuffixes,
            javaScriptCorePathSuffixes: javaScriptCoreImagePathSuffixes,
            symbols: NativeInspectorSymbols(
                connectFrontend: NativeInspectorRequiredSymbol(
                    role: .connectFrontend,
                    ownerImage: .webKit,
                    candidates: [connectSymbol] + alternateConnectSymbols,
                    resolutionPolicy: .requiredTextSymbol
                ),
                disconnectFrontend: NativeInspectorRequiredSymbol(
                    role: .disconnectFrontend,
                    ownerImage: .webKit,
                    candidates: [disconnectSymbol] + alternateDisconnectSymbols,
                    resolutionPolicy: .requiredTextSymbol
                ),
                inspectorControllerConnectTargets: NativeInspectorRequiredSymbol(
                    role: .inspectorControllerConnectTarget,
                    ownerImage: .webCore,
                    candidates: [
                        pageInspectorControllerConnectSymbol,
                        frameInspectorControllerConnectSymbol,
                    ],
                    resolutionPolicy: .fallbackCallTarget
                ),
                inspectorControllerDisconnectTargets: NativeInspectorRequiredSymbol(
                    role: .inspectorControllerDisconnectTarget,
                    ownerImage: .webCore,
                    candidates: [
                        pageInspectorControllerDisconnectSymbol,
                        frameInspectorControllerDisconnectSymbol,
                    ],
                    resolutionPolicy: .fallbackCallTarget
                ),
                stringFromUTF8: NativeInspectorRequiredSymbol(
                    role: .stringFromUTF8,
                    ownerImage: .javaScriptCore,
                    candidates: [stringFromUTF8Symbol ?? self.stringFromUTF8Symbol],
                    resolutionPolicy: .requiredTextSymbol
                ),
                stringImplToNSString: NativeInspectorRequiredSymbol(
                    role: .stringImplToNSString,
                    ownerImage: .javaScriptCore,
                    candidates: [stringImplToNSStringSymbol ?? self.stringImplToNSStringSymbol],
                    resolutionPolicy: .requiredTextSymbol
                ),
                destroyStringImpl: NativeInspectorRequiredSymbol(
                    role: .destroyStringImpl,
                    ownerImage: .javaScriptCore,
                    candidates: [destroyStringImplSymbol ?? self.destroyStringImplSymbol],
                    resolutionPolicy: .requiredTextSymbol
                ),
                backendDispatcherDispatch: NativeInspectorRequiredSymbol(
                    role: .backendDispatcherDispatch,
                    ownerImage: .webKit,
                    candidates: [backendDispatcherDispatchSymbol ?? self.backendDispatcherDispatchSymbol],
                    resolutionPolicy: .requiredTextSymbol
                )
            )
        )
    }

    private static func currentSymbolNames() -> NativeInspectorSymbols {
        NativeInspectorSymbols(
            connectFrontend: NativeInspectorRequiredSymbol(
                role: .connectFrontend,
                ownerImage: .webKit,
                candidates: [connectFrontendSymbol],
                resolutionPolicy: .requiredTextSymbol
            ),
            disconnectFrontend: NativeInspectorRequiredSymbol(
                role: .disconnectFrontend,
                ownerImage: .webKit,
                candidates: [disconnectFrontendSymbol],
                resolutionPolicy: .requiredTextSymbol
            ),
            inspectorControllerConnectTargets: NativeInspectorRequiredSymbol(
                role: .inspectorControllerConnectTarget,
                ownerImage: .webCore,
                candidates: [
                    pageInspectorControllerConnectSymbol,
                    frameInspectorControllerConnectSymbol,
                ],
                resolutionPolicy: .fallbackCallTarget
            ),
            inspectorControllerDisconnectTargets: NativeInspectorRequiredSymbol(
                role: .inspectorControllerDisconnectTarget,
                ownerImage: .webCore,
                candidates: [
                    pageInspectorControllerDisconnectSymbol,
                    frameInspectorControllerDisconnectSymbol,
                ],
                resolutionPolicy: .fallbackCallTarget
            ),
            stringFromUTF8: NativeInspectorRequiredSymbol(
                role: .stringFromUTF8,
                ownerImage: .javaScriptCore,
                candidates: [stringFromUTF8Symbol],
                resolutionPolicy: .requiredTextSymbol
            ),
            stringImplToNSString: NativeInspectorRequiredSymbol(
                role: .stringImplToNSString,
                ownerImage: .javaScriptCore,
                candidates: [stringImplToNSStringSymbol],
                resolutionPolicy: .requiredTextSymbol
            ),
            destroyStringImpl: NativeInspectorRequiredSymbol(
                role: .destroyStringImpl,
                ownerImage: .javaScriptCore,
                candidates: [destroyStringImplSymbol],
                resolutionPolicy: .requiredTextSymbol
            ),
            backendDispatcherDispatch: NativeInspectorRequiredSymbol(
                role: .backendDispatcherDispatch,
                ownerImage: .webKit,
                candidates: [backendDispatcherDispatchSymbol],
                resolutionPolicy: .requiredTextSymbol
            )
        )
    }

    private static func resolve(
        imagePathSuffixes: [String],
        javaScriptCorePathSuffixes: [String],
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorSymbolLookupResult {
        guard let loadedImage = loadedWebKitImage(pathSuffixes: imagePathSuffixes) else {
            return failure(.inspectorImageMissing)
        }
        guard let loadedJavaScriptCoreImage = loadedWebKitImage(pathSuffixes: javaScriptCorePathSuffixes) else {
            return failure(.supportImageMissing)
        }
        let loadedWebCoreImage = loadedWebKitImage(pathSuffixes: webCoreImagePathSuffixes)

        let image = unsafe MachOImage(ptr: loadedImage.header)
        guard image.is64Bit, let text = textSegment(in: image) else {
            return failure(.inspectorImageMissing)
        }
        let javaScriptCoreImage = unsafe MachOImage(ptr: loadedJavaScriptCoreImage.header)
        guard javaScriptCoreImage.is64Bit, let javaScriptCoreText = textSegment(in: javaScriptCoreImage) else {
            return failure(.supportImageMissing)
        }
        let webCoreImage = loadedWebCoreImage.map { unsafe MachOImage(ptr: $0.header) }
        let webCoreText = webCoreImage.flatMap { $0.is64Bit ? textSegment(in: $0) : nil }

        let loadedImageResults = NativeInspectorResolvedSymbolSet(
            connectFrontend: resolveLoadedImageSymbol(namedAnyOf: symbols.connectFrontend.decodedCandidates(), in: image, text: text),
            disconnectFrontend: resolveLoadedImageSymbol(namedAnyOf: symbols.disconnectFrontend.decodedCandidates(), in: image, text: text),
            stringFromUTF8: resolveLoadedImageSymbol(namedAnyOf: symbols.stringFromUTF8.decodedCandidates(), in: javaScriptCoreImage, text: javaScriptCoreText),
            stringImplToNSString: resolveLoadedImageSymbol(namedAnyOf: symbols.stringImplToNSString.decodedCandidates(), in: javaScriptCoreImage, text: javaScriptCoreText),
            destroyStringImpl: resolveLoadedImageSymbol(namedAnyOf: symbols.destroyStringImpl.decodedCandidates(), in: javaScriptCoreImage, text: javaScriptCoreText),
            backendDispatcherDispatch: preferredResolvedAddress(
                resolveLoadedImageSymbol(namedAnyOf: symbols.backendDispatcherDispatch.decodedCandidates(), in: image, text: text),
                fallback: resolveLoadedImageSymbol(namedAnyOf: symbols.backendDispatcherDispatch.decodedCandidates(), in: javaScriptCoreImage, text: javaScriptCoreText)
            )
        )
        let loadedImageResultsWithFallback = unsafe resolveConnectDisconnectFallbackIfNeeded(
            loadedImageResults,
            image: image,
            text: text,
            webCoreImage: webCoreImage,
            webCoreText: webCoreText,
            javaScriptCoreImage: javaScriptCoreImage,
            javaScriptCoreText: javaScriptCoreText,
            symbols: symbols
        )
        let loadedImageResolution = successfulResolutionIfComplete(
            loadedImageResultsWithFallback.symbols,
            phase: .loadedImage,
            source: loadedImageResultsWithFallback.usedFallback ? "loaded-image+text-scan" : "loaded-image",
            webKitHeaderAddress: loadedImage.headerAddress,
            javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
            usedConnectDisconnectFallback: loadedImageResultsWithFallback.usedFallback
        )
            ?? finalizeResolution(
                loadedImageResultsWithFallback.symbols,
                phase: .loadedImage,
                source: loadedImageResultsWithFallback.usedFallback ? "loaded-image+text-scan" : "loaded-image",
                webKitHeaderAddress: loadedImage.headerAddress,
                javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
                usedConnectDisconnectFallback: loadedImageResultsWithFallback.usedFallback
            )
            ?? failure(.runtimeFunctionSymbolMissing)

        if loadedImageResolution.failureReason == nil {
            return loadedImageResolution
        }

        let sharedCacheResolution = resolveUsingSharedCache(
            loadedImage: loadedImage,
            imagePathSuffixes: imagePathSuffixes,
            loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
            javaScriptCorePathSuffixes: javaScriptCorePathSuffixes,
            loadedImageSymbols: loadedImageResultsWithFallback.symbols,
            symbols: symbols
        )
        return mergedResolution(
            preferred: loadedImageResolution,
            fallback: sharedCacheResolution
        )
    }

    private static func resolveUsingSharedCache(
        loadedImage: LoadedNativeInspectorImage,
        imagePathSuffixes: [String],
        loadedJavaScriptCoreImage: LoadedNativeInspectorImage,
        javaScriptCorePathSuffixes: [String],
        loadedImageSymbols: NativeInspectorResolvedSymbolSet,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorSymbolLookupResult {
        guard let cache = unsafe MachOKitSymbolLookup.currentSharedCache else {
            return failure(.sharedCacheUnavailable)
        }

        guard let webKitImage = cache.machOImages().first(where: { imagePathMatches($0.path, suffixes: imagePathSuffixes) }) else {
            return failure(.inspectorImageMissing)
        }
        guard let javaScriptCoreImage = cache.machOImages().first(where: { imagePathMatches($0.path, suffixes: javaScriptCorePathSuffixes) }) else {
            return failure(.supportImageMissing)
        }
        let webCoreImage = cache.machOImages().first(where: { imagePathMatches($0.path, suffixes: webCoreImagePathSuffixes) })
        guard webKitImage.is64Bit, let text = textSegment(in: webKitImage) else {
            return failure(.inspectorImageMissing)
        }
        guard javaScriptCoreImage.is64Bit, let javaScriptCoreText = textSegment(in: javaScriptCoreImage) else {
            return failure(.supportImageMissing)
        }
        let webCoreText = webCoreImage.flatMap { $0.is64Bit ? textSegment(in: $0) : nil }
        guard let slide = cache.slide, slide >= 0 else {
            return failure(.sharedCacheUnavailable)
        }

        let textStart = UInt64(loadedImage.headerAddress)
        let textRange = textStart ..< textStart + UInt64(text.virtualMemorySize)
        let dylibOffset = UInt64(text.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
        let javaScriptCoreTextStart = UInt64(loadedJavaScriptCoreImage.headerAddress)
        let javaScriptCoreTextRange = javaScriptCoreTextStart ..< javaScriptCoreTextStart + UInt64(javaScriptCoreText.virtualMemorySize)
        let javaScriptCoreDylibOffset = UInt64(javaScriptCoreText.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
        var lastResolvedSymbols: NativeInspectorResolvedSymbolSet?

        if let localSymbolsInfo = cache.localSymbolsInfo {
            if let entry = localSymbolsInfo.entries(in: cache).first(where: { UInt64($0.dylibOffset) == dylibOffset }),
               let javaScriptCoreEntry = localSymbolsInfo.entries(in: cache).first(where: { UInt64($0.dylibOffset) == javaScriptCoreDylibOffset }),
               let symbols64 = localSymbolsInfo.symbols64(in: cache) {
                let lowerBound = entry.nlistStartIndex
                let upperBound = lowerBound + entry.nlistCount
                let javaScriptCoreLowerBound = javaScriptCoreEntry.nlistStartIndex
                let javaScriptCoreUpperBound = javaScriptCoreLowerBound + javaScriptCoreEntry.nlistCount
                if lowerBound >= 0,
                   upperBound >= lowerBound,
                   upperBound <= symbols64.count,
                   javaScriptCoreLowerBound >= 0,
                   javaScriptCoreUpperBound >= javaScriptCoreLowerBound,
                   javaScriptCoreUpperBound <= symbols64.count {
                    let resolvedSymbols = NativeInspectorResolvedSymbolSet(
                        connectFrontend: resolveSharedCacheSymbol(
                            namedAnyOf: symbols.connectFrontend.decodedCandidates(),
                            symbols: symbols64,
                            symbolRange: lowerBound ..< upperBound,
                            textVMAddress: UInt64(text.virtualMemoryAddress),
                            textRange: textRange,
                            slide: UInt64(slide)
                        ),
                        disconnectFrontend: resolveSharedCacheSymbol(
                            namedAnyOf: symbols.disconnectFrontend.decodedCandidates(),
                            symbols: symbols64,
                            symbolRange: lowerBound ..< upperBound,
                            textVMAddress: UInt64(text.virtualMemoryAddress),
                            textRange: textRange,
                            slide: UInt64(slide)
                        ),
                        stringFromUTF8: resolveSharedCacheSymbol(
                            namedAnyOf: symbols.stringFromUTF8.decodedCandidates(),
                            symbols: symbols64,
                            symbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound,
                            textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                            textRange: javaScriptCoreTextRange,
                            slide: UInt64(slide)
                        ),
                        stringImplToNSString: resolveSharedCacheSymbol(
                            namedAnyOf: symbols.stringImplToNSString.decodedCandidates(),
                            symbols: symbols64,
                            symbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound,
                            textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                            textRange: javaScriptCoreTextRange,
                            slide: UInt64(slide)
                        ),
                        destroyStringImpl: resolveSharedCacheSymbol(
                            namedAnyOf: symbols.destroyStringImpl.decodedCandidates(),
                            symbols: symbols64,
                            symbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound,
                            textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                            textRange: javaScriptCoreTextRange,
                            slide: UInt64(slide)
                        ),
                        backendDispatcherDispatch: preferredResolvedAddress(
                            resolveSharedCacheSymbol(
                                namedAnyOf: symbols.backendDispatcherDispatch.decodedCandidates(),
                                symbols: symbols64,
                                symbolRange: lowerBound ..< upperBound,
                                textVMAddress: UInt64(text.virtualMemoryAddress),
                                textRange: textRange,
                                slide: UInt64(slide)
                            ),
                            fallback: resolveSharedCacheSymbol(
                                namedAnyOf: symbols.backendDispatcherDispatch.decodedCandidates(),
                                symbols: symbols64,
                                symbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound,
                                textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                                textRange: javaScriptCoreTextRange,
                                slide: UInt64(slide)
                            )
                        )
                    )
                    let resolvedSymbolsWithFallback = unsafe resolveConnectDisconnectFallbackIfNeeded(
                        resolvedSymbols,
                        image: webKitImage,
                        text: text,
                        webCoreImage: webCoreImage,
                        webCoreText: webCoreText,
                        javaScriptCoreImage: javaScriptCoreImage,
                        javaScriptCoreText: javaScriptCoreText,
                        symbols: symbols
                    )
                    let usedRuntimeFallback = usesLoadedImageRuntimeFallback(
                        resolvedSymbols: resolvedSymbolsWithFallback.symbols,
                        loadedImageSymbols: loadedImageSymbols
                    )
                    let resolvedSymbolsWithRuntimeFallback = applyingLoadedImageRuntimeFallback(
                        to: resolvedSymbolsWithFallback.symbols,
                        loadedImageSymbols: loadedImageSymbols
                    )
                    lastResolvedSymbols = resolvedSymbolsWithRuntimeFallback
                    if let resolution = successfulResolutionIfComplete(
                            resolvedSymbolsWithRuntimeFallback,
                            phase: .sharedCache,
                            source: sharedCacheSourceDescription(
                                base: "shared-cache",
                                usedConnectDisconnectFallback: resolvedSymbolsWithFallback.usedFallback,
                                usedRuntimeFallback: usedRuntimeFallback
                            ),
                            webKitHeaderAddress: loadedImage.headerAddress,
                            javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
                            usedConnectDisconnectFallback: resolvedSymbolsWithFallback.usedFallback
                        ) {
                        return resolution
                    }
                }
            }
        }

        do {
            let fileBackedSymbols = try fileBackedLocalSymbols(
                mainCacheHeader: cache.mainCacheHeader,
                dylibOffset: dylibOffset
            )
            let javaScriptCoreFileBackedSymbols = try fileBackedLocalSymbols(
                mainCacheHeader: cache.mainCacheHeader,
                dylibOffset: javaScriptCoreDylibOffset
            )
            let resolvedSymbols = NativeInspectorResolvedSymbolSet(
                connectFrontend: resolveSharedCacheSymbol(
                    namedAnyOf: symbols.connectFrontend.decodedCandidates(),
                    symbols: fileBackedSymbols.symbols,
                    symbolRange: fileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(text.virtualMemoryAddress),
                    textRange: textRange,
                    slide: UInt64(slide)
                ),
                disconnectFrontend: resolveSharedCacheSymbol(
                    namedAnyOf: symbols.disconnectFrontend.decodedCandidates(),
                    symbols: fileBackedSymbols.symbols,
                    symbolRange: fileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(text.virtualMemoryAddress),
                    textRange: textRange,
                    slide: UInt64(slide)
                ),
                stringFromUTF8: resolveSharedCacheSymbol(
                    namedAnyOf: symbols.stringFromUTF8.decodedCandidates(),
                    symbols: javaScriptCoreFileBackedSymbols.symbols,
                    symbolRange: javaScriptCoreFileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                    textRange: javaScriptCoreTextRange,
                    slide: UInt64(slide)
                ),
                stringImplToNSString: resolveSharedCacheSymbol(
                    namedAnyOf: symbols.stringImplToNSString.decodedCandidates(),
                    symbols: javaScriptCoreFileBackedSymbols.symbols,
                    symbolRange: javaScriptCoreFileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                    textRange: javaScriptCoreTextRange,
                    slide: UInt64(slide)
                ),
                destroyStringImpl: resolveSharedCacheSymbol(
                    namedAnyOf: symbols.destroyStringImpl.decodedCandidates(),
                    symbols: javaScriptCoreFileBackedSymbols.symbols,
                    symbolRange: javaScriptCoreFileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                    textRange: javaScriptCoreTextRange,
                    slide: UInt64(slide)
                ),
                backendDispatcherDispatch: preferredResolvedAddress(
                    resolveSharedCacheSymbol(
                        namedAnyOf: symbols.backendDispatcherDispatch.decodedCandidates(),
                        symbols: fileBackedSymbols.symbols,
                        symbolRange: fileBackedSymbols.symbolRange,
                        textVMAddress: UInt64(text.virtualMemoryAddress),
                        textRange: textRange,
                        slide: UInt64(slide)
                    ),
                    fallback: resolveSharedCacheSymbol(
                        namedAnyOf: symbols.backendDispatcherDispatch.decodedCandidates(),
                        symbols: javaScriptCoreFileBackedSymbols.symbols,
                        symbolRange: javaScriptCoreFileBackedSymbols.symbolRange,
                        textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                        textRange: javaScriptCoreTextRange,
                        slide: UInt64(slide)
                    )
                )
            )
            let resolvedSymbolsWithFallback = unsafe resolveConnectDisconnectFallbackIfNeeded(
                resolvedSymbols,
                image: webKitImage,
                text: text,
                webCoreImage: webCoreImage,
                webCoreText: webCoreText,
                javaScriptCoreImage: javaScriptCoreImage,
                javaScriptCoreText: javaScriptCoreText,
                symbols: symbols
            )
            let usedRuntimeFallback = usesLoadedImageRuntimeFallback(
                resolvedSymbols: resolvedSymbolsWithFallback.symbols,
                loadedImageSymbols: loadedImageSymbols
            )
            let resolvedSymbolsWithRuntimeFallback = applyingLoadedImageRuntimeFallback(
                to: resolvedSymbolsWithFallback.symbols,
                loadedImageSymbols: loadedImageSymbols
            )
            lastResolvedSymbols = resolvedSymbolsWithRuntimeFallback
            if let resolution = successfulResolutionIfComplete(
                    resolvedSymbolsWithRuntimeFallback,
                    phase: .sharedCacheFile,
                    source: sharedCacheSourceDescription(
                        base: "shared-cache-file",
                        usedConnectDisconnectFallback: resolvedSymbolsWithFallback.usedFallback,
                        usedRuntimeFallback: usedRuntimeFallback
                    ),
                    webKitHeaderAddress: loadedImage.headerAddress,
                    javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
                    usedConnectDisconnectFallback: resolvedSymbolsWithFallback.usedFallback
                ) {
                return resolution
            }
        } catch let lookupFailure as NativeInspectorSymbolLookupFailure {
            if let lastResolvedSymbols {
                return finalizeResolution(
                    lastResolvedSymbols,
                    phase: nil,
                    source: "shared-cache-file",
                    webKitHeaderAddress: loadedImage.headerAddress,
                    javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
                    usedConnectDisconnectFallback: false
                )
                    ?? failure(lookupFailure.kind, detail: lookupFailure.detail)
            }
            return failure(lookupFailure.kind, detail: lookupFailure.detail)
        } catch {
            if let lastResolvedSymbols {
                return finalizeResolution(
                    lastResolvedSymbols,
                    phase: nil,
                    source: "shared-cache-file",
                    webKitHeaderAddress: loadedImage.headerAddress,
                    javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
                    usedConnectDisconnectFallback: false
                )
                    ?? failure(.localSymbolsUnavailable)
            }
            return failure(.localSymbolsUnavailable)
        }

        if let lastResolvedSymbols {
            return finalizeResolution(
                lastResolvedSymbols,
                phase: nil,
                source: "shared-cache",
                webKitHeaderAddress: loadedImage.headerAddress,
                javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
                usedConnectDisconnectFallback: false
            )
                ?? failure(.runtimeFunctionSymbolMissing)
        }
        return failure(.runtimeFunctionSymbolMissing)
    }

    private static func preferredResolvedAddress(
        _ primary: ResolvedNativeInspectorAddress,
        fallback: ResolvedNativeInspectorAddress
    ) -> ResolvedNativeInspectorAddress {
        switch primary {
        case .missing:
            return fallback
        default:
            return primary
        }
    }

    private static func applyingLoadedImageRuntimeFallback(
        to resolvedSymbols: NativeInspectorResolvedSymbolSet,
        loadedImageSymbols: NativeInspectorResolvedSymbolSet
    ) -> NativeInspectorResolvedSymbolSet {
        NativeInspectorResolvedSymbolSet(
            connectFrontend: resolvedSymbols.connectFrontend,
            disconnectFrontend: resolvedSymbols.disconnectFrontend,
            stringFromUTF8: preferredResolvedAddress(
                resolvedSymbols.stringFromUTF8,
                fallback: loadedImageSymbols.stringFromUTF8
            ),
            stringImplToNSString: preferredResolvedAddress(
                resolvedSymbols.stringImplToNSString,
                fallback: loadedImageSymbols.stringImplToNSString
            ),
            destroyStringImpl: preferredResolvedAddress(
                resolvedSymbols.destroyStringImpl,
                fallback: loadedImageSymbols.destroyStringImpl
            ),
            backendDispatcherDispatch: preferredResolvedAddress(
                resolvedSymbols.backendDispatcherDispatch,
                fallback: loadedImageSymbols.backendDispatcherDispatch
            )
        )
    }

    private static func usesLoadedImageRuntimeFallback(
        resolvedSymbols: NativeInspectorResolvedSymbolSet,
        loadedImageSymbols: NativeInspectorResolvedSymbolSet
    ) -> Bool {
        let symbolPairs: [(ResolvedNativeInspectorAddress, ResolvedNativeInspectorAddress)] = [
            (resolvedSymbols.stringFromUTF8, loadedImageSymbols.stringFromUTF8),
            (resolvedSymbols.stringImplToNSString, loadedImageSymbols.stringImplToNSString),
            (resolvedSymbols.destroyStringImpl, loadedImageSymbols.destroyStringImpl),
            (resolvedSymbols.backendDispatcherDispatch, loadedImageSymbols.backendDispatcherDispatch),
        ]

        for (resolved, loadedImage) in symbolPairs {
            if case .missing = resolved, case .found = loadedImage {
                return true
            }
        }

        return false
    }

    private static func sharedCacheSourceDescription(
        base: String,
        usedConnectDisconnectFallback: Bool,
        usedRuntimeFallback: Bool
    ) -> String {
        var parts = [base]
        if usedConnectDisconnectFallback {
            parts.append("text-scan")
        }
        if usedRuntimeFallback {
            parts.append("loaded-image-runtime")
        }
        return parts.joined(separator: "+")
    }

    private static func mergedResolution(
        preferred: NativeInspectorSymbolLookupResult?,
        fallback: NativeInspectorSymbolLookupResult
    ) -> NativeInspectorSymbolLookupResult {
        guard let preferred else {
            return fallback
        }
        if preferred.failureReason == nil {
            return fallback.failureReason == nil ? fallback : preferred
        }
        guard fallback.failureReason != nil else {
            return fallback
        }

        let genericFailureKinds: Set<NativeInspectorSymbolFailure> = [
            .sharedCacheUnavailable,
            .localSymbolsUnavailable,
            .localSymbolEntryMissing,
        ]
        guard let fallbackFailureKind = fallback.failureKind,
              genericFailureKinds.contains(fallbackFailureKind),
              preferred.failureReason != nil else {
            return fallback
        }

        let reason = [fallback.failureReason, preferred.failureReason]
            .compactMap { value in
                guard let value, !value.isEmpty else {
                    return nil
                }
                return value
            }
            .joined(separator: " | loaded-image=")
        return NativeInspectorSymbolLookupResult(
            functionAddresses: .zero,
            failureReason: reason.isEmpty ? fallback.failureReason : reason,
            failureKind: fallback.failureKind ?? preferred.failureKind,
            phase: fallback.phase ?? preferred.phase,
            missingFunctions: fallback.missingFunctions.isEmpty ? preferred.missingFunctions : fallback.missingFunctions,
            source: fallback.source ?? preferred.source,
            usedConnectDisconnectFallback: fallback.usedConnectDisconnectFallback || preferred.usedConnectDisconnectFallback
        )
    }

    private static func resolveLoadedImageSymbol(
        namedAnyOf symbolNames: [String],
        in image: MachOImage,
        text: SegmentCommand64
    ) -> ResolvedNativeInspectorAddress {
        resolveFirstAvailableSymbol(namedAnyOf: symbolNames) { symbolName in
            resolveLoadedImageSymbol(named: symbolName, in: image, text: text)
        }
    }

    private static func resolveSharedCacheSymbol(
        namedAnyOf symbolNames: [String],
        symbols: MachOImage.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> ResolvedNativeInspectorAddress {
        resolveFirstAvailableSymbol(namedAnyOf: symbolNames) { symbolName in
            resolveSharedCacheSymbol(
                named: symbolName,
                symbols: symbols,
                symbolRange: symbolRange,
                textVMAddress: textVMAddress,
                textRange: textRange,
                slide: slide
            )
        }
    }

    private static func resolveSharedCacheSymbol(
        namedAnyOf symbolNames: [String],
        symbols: MachOFile.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> ResolvedNativeInspectorAddress {
        resolveFirstAvailableSymbol(namedAnyOf: symbolNames) { symbolName in
            resolveSharedCacheSymbol(
                named: symbolName,
                symbols: symbols,
                symbolRange: symbolRange,
                textVMAddress: textVMAddress,
                textRange: textRange,
                slide: slide
            )
        }
    }

    private static func resolveFirstAvailableSymbol(
        namedAnyOf symbolNames: [String],
        resolver: (String) -> ResolvedNativeInspectorAddress
    ) -> ResolvedNativeInspectorAddress {
        var outsideTextResult: ResolvedNativeInspectorAddress?
        for symbolName in symbolNames {
            let result = resolver(symbolName)
            switch result {
            case .found:
                return result
            case .outsideText:
                if outsideTextResult == nil {
                    outsideTextResult = result
                }
            case .missing:
                continue
            }
        }
        return outsideTextResult ?? .missing
    }

    @unsafe private static func resolveConnectDisconnectFallbackIfNeeded(
        _ resolvedSymbols: NativeInspectorResolvedSymbolSet,
        image: MachOImage,
        text: SegmentCommand64,
        webCoreImage: MachOImage?,
        webCoreText: SegmentCommand64?,
        javaScriptCoreImage: MachOImage,
        javaScriptCoreText: SegmentCommand64,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorAttachEntryPointFallbackResult {
        let connectNeedsFallback: Bool
        switch resolvedSymbols.connectFrontend {
        case .missing, .outsideText:
            connectNeedsFallback = true
        case .found:
            connectNeedsFallback = false
        }

        let disconnectNeedsFallback: Bool
        switch resolvedSymbols.disconnectFrontend {
        case .missing, .outsideText:
            disconnectNeedsFallback = true
        case .found:
            disconnectNeedsFallback = false
        }

        guard connectNeedsFallback || disconnectNeedsFallback else {
            return .init(
                symbols: resolvedSymbols,
                usedFallback: false
            )
        }

        let webCoreConnectTargets = unsafe resolvedCallTargetAddresses(
            symbolNames: symbols.inspectorControllerConnectTargets.decodedCandidates(),
            in: webCoreImage,
            text: webCoreText
        )
        let webCoreDisconnectTargets = unsafe resolvedCallTargetAddresses(
            symbolNames: symbols.inspectorControllerDisconnectTargets.decodedCandidates(),
            in: webCoreImage,
            text: webCoreText
        )
        let webKitBoundConnectTargets = unsafe boundCallTargetAddresses(
            symbolNames: symbols.inspectorControllerConnectTargets.decodedCandidates(),
            in: image
        )
        let webKitBoundDisconnectTargets = unsafe boundCallTargetAddresses(
            symbolNames: symbols.inspectorControllerDisconnectTargets.decodedCandidates(),
            in: image
        )

        let connectTargetAddresses = webCoreConnectTargets.union(webKitBoundConnectTargets)
        let disconnectTargetAddresses = webCoreDisconnectTargets.union(webKitBoundDisconnectTargets)

        guard let functionStarts = image.functionStarts else {
            #if DEBUG
            if NativeInspectorSymbolDiagnostics.verboseConsoleDiagnosticsEnabled {
                NSLog(
                    "[V2_WebInspectorTransport] native inspector text scan unavailable functionStarts=nil webCoreConnectTargets=%lu webCoreDisconnectTargets=%lu webKitBoundConnectTargets=%lu webKitBoundDisconnectTargets=%lu",
                    webCoreConnectTargets.count,
                    webCoreDisconnectTargets.count,
                    webKitBoundConnectTargets.count,
                    webKitBoundDisconnectTargets.count
                )
            }
            #endif
            return .init(
                symbols: resolvedSymbols,
                usedFallback: false
            )
        }

        let webKitHeaderAddress = unsafe UInt64(UInt(bitPattern: image.ptr))
        let textRange = webKitHeaderAddress ..< webKitHeaderAddress + UInt64(text.virtualMemorySize)
        let functionStartAddresses = functionStarts
            .map { webKitHeaderAddress + UInt64($0.offset) }
            .filter { textRange.contains($0) }

        let resolvedConnect = unsafe resolvedFallbackFunctionStartAddress(
            in: image,
            text: text,
            functionStartAddresses: functionStartAddresses,
            callTargetAddresses: connectTargetAddresses
        )
        let resolvedDisconnect = unsafe resolvedFallbackFunctionStartAddress(
            in: image,
            text: text,
            functionStartAddresses: functionStartAddresses,
            callTargetAddresses: disconnectTargetAddresses
        )

        #if DEBUG
        if NativeInspectorSymbolDiagnostics.verboseConsoleDiagnosticsEnabled {
            NSLog(
                "[V2_WebInspectorTransport] native inspector text scan webCoreConnectTargets=%lu webCoreDisconnectTargets=%lu webKitBoundConnectTargets=%lu webKitBoundDisconnectTargets=%lu connectTargets=%lu disconnectTargets=%lu resolvedConnect=%@ resolvedDisconnect=%@",
                webCoreConnectTargets.count,
                webCoreDisconnectTargets.count,
                webKitBoundConnectTargets.count,
                webKitBoundDisconnectTargets.count,
                connectTargetAddresses.count,
                disconnectTargetAddresses.count,
                debugResolvedAddress(resolvedConnect),
                debugResolvedAddress(resolvedDisconnect)
            )
        }
        #endif

        let resolvedWrapperSymbols = NativeInspectorResolvedSymbolSet(
            connectFrontend: connectNeedsFallback && isFound(resolvedConnect) ? resolvedConnect : resolvedSymbols.connectFrontend,
            disconnectFrontend: disconnectNeedsFallback && isFound(resolvedDisconnect) ? resolvedDisconnect : resolvedSymbols.disconnectFrontend,
            stringFromUTF8: resolvedSymbols.stringFromUTF8,
            stringImplToNSString: resolvedSymbols.stringImplToNSString,
            destroyStringImpl: resolvedSymbols.destroyStringImpl,
            backendDispatcherDispatch: resolvedSymbols.backendDispatcherDispatch
        )
        let usedWrapperFallback =
            (connectNeedsFallback && isFound(resolvedConnect))
            || (disconnectNeedsFallback && isFound(resolvedDisconnect))

        return .init(
            symbols: resolvedWrapperSymbols,
            usedFallback: usedWrapperFallback
        )
    }

    private static func resolvedFunctionAddresses(
        from resolvedSymbols: NativeInspectorResolvedSymbolSet
    ) -> NativeInspectorSymbolAddresses? {
        guard
            case let .found(connectAddress) = resolvedSymbols.connectFrontend,
            case let .found(disconnectAddress) = resolvedSymbols.disconnectFrontend,
            case let .found(stringFromUTF8Address) = resolvedSymbols.stringFromUTF8,
            case let .found(stringImplToNSStringAddress) = resolvedSymbols.stringImplToNSString,
            case let .found(destroyStringImplAddress) = resolvedSymbols.destroyStringImpl,
            case let .found(backendDispatcherDispatchAddress) = resolvedSymbols.backendDispatcherDispatch
        else {
            return nil
        }

        return NativeInspectorSymbolAddresses(
            connectFrontendAddress: connectAddress,
            disconnectFrontendAddress: disconnectAddress,
            stringFromUTF8Address: stringFromUTF8Address,
            stringImplToNSStringAddress: stringImplToNSStringAddress,
            destroyStringImplAddress: destroyStringImplAddress,
            backendDispatcherDispatchAddress: backendDispatcherDispatchAddress
        )
    }

    private static func expectedHeaderAddressesForAttachEntryPoints(
        webKitHeaderAddress: UInt,
        javaScriptCoreHeaderAddress: UInt
    ) -> [UInt] {
        return [webKitHeaderAddress]
    }

    private static func successResolution(
        _ functionAddresses: NativeInspectorSymbolAddresses,
        phase: NativeInspectorSymbolResolutionPhase?,
        source: String?,
        usedConnectDisconnectFallback: Bool
    ) -> NativeInspectorSymbolLookupResult {
        if let phase, NativeInspectorSymbolDiagnostics.verboseConsoleDiagnosticsEnabled {
            NSLog(
                "[V2_WebInspectorNativeSymbols] native inspector symbols resolved backend=%@ phase=%@",
                "native-inspector",
                phase.message
            )
        }
        return NativeInspectorSymbolLookupResult(
            functionAddresses: functionAddresses,
            failureReason: nil,
            failureKind: nil,
            phase: phase,
            missingFunctions: [],
            source: source,
            usedConnectDisconnectFallback: usedConnectDisconnectFallback
        )
    }

    private static func successfulResolutionIfComplete(
        _ resolvedSymbols: NativeInspectorResolvedSymbolSet,
        phase: NativeInspectorSymbolResolutionPhase?,
        source: String?,
        webKitHeaderAddress: UInt,
        javaScriptCoreHeaderAddress: UInt,
        usedConnectDisconnectFallback: Bool
    ) -> NativeInspectorSymbolLookupResult? {
        let allResults = [
            resolvedSymbols.connectFrontend,
            resolvedSymbols.disconnectFrontend,
            resolvedSymbols.stringFromUTF8,
            resolvedSymbols.stringImplToNSString,
            resolvedSymbols.destroyStringImpl,
            resolvedSymbols.backendDispatcherDispatch,
        ]

        guard allResults.allSatisfy({
            if case .found = $0 {
                return true
            }
            return false
        }) else {
            return nil
        }

        for result in allResults {
            if case .outsideText = result {
                return nil
            }
        }

        let attachHeaders = expectedHeaderAddressesForAttachEntryPoints(
            webKitHeaderAddress: webKitHeaderAddress,
            javaScriptCoreHeaderAddress: javaScriptCoreHeaderAddress
        )
        let expectedHeadersBySymbol: [(ResolvedNativeInspectorAddress, [UInt])] = [
            (resolvedSymbols.connectFrontend, attachHeaders),
            (resolvedSymbols.disconnectFrontend, attachHeaders),
            (resolvedSymbols.stringFromUTF8, [javaScriptCoreHeaderAddress]),
            (resolvedSymbols.stringImplToNSString, [javaScriptCoreHeaderAddress]),
            (resolvedSymbols.destroyStringImpl, [javaScriptCoreHeaderAddress]),
            (resolvedSymbols.backendDispatcherDispatch, [webKitHeaderAddress, javaScriptCoreHeaderAddress]),
        ]
        for (result, expectedHeaders) in expectedHeadersBySymbol {
            guard case let .found(address) = result else {
                return nil
            }
            guard resolvedAddress(address, belongsToAnyOf: expectedHeaders) else {
                return nil
            }
        }

        guard let functionAddresses = resolvedFunctionAddresses(from: resolvedSymbols) else {
            return nil
        }
        return successResolution(
            functionAddresses,
            phase: phase,
            source: source,
            usedConnectDisconnectFallback: usedConnectDisconnectFallback
        )
    }

    private static func finalizeResolution(
        _ resolvedSymbols: NativeInspectorResolvedSymbolSet,
        phase: NativeInspectorSymbolResolutionPhase?,
        source: String?,
        webKitHeaderAddress: UInt,
        javaScriptCoreHeaderAddress: UInt,
        usedConnectDisconnectFallback: Bool
    ) -> NativeInspectorSymbolLookupResult? {
        let allResults = [
            resolvedSymbols.connectFrontend,
            resolvedSymbols.disconnectFrontend,
            resolvedSymbols.stringFromUTF8,
            resolvedSymbols.stringImplToNSString,
            resolvedSymbols.destroyStringImpl,
            resolvedSymbols.backendDispatcherDispatch,
        ]

        for result in allResults {
            if case .outsideText = result {
                return failure(
                    .resolvedAddressOutsideText,
                    phase: phase,
                    source: source,
                    missingFunctions: unsafe missingFunctionNames(in: resolvedSymbols),
                    usedConnectDisconnectFallback: usedConnectDisconnectFallback
                )
            }
        }

        let attachHeaders = expectedHeaderAddressesForAttachEntryPoints(
            webKitHeaderAddress: webKitHeaderAddress,
            javaScriptCoreHeaderAddress: javaScriptCoreHeaderAddress
        )
        let expectedHeadersBySymbol: [(ResolvedNativeInspectorAddress, [UInt])] = [
            (resolvedSymbols.connectFrontend, attachHeaders),
            (resolvedSymbols.disconnectFrontend, attachHeaders),
            (resolvedSymbols.stringFromUTF8, [javaScriptCoreHeaderAddress]),
            (resolvedSymbols.stringImplToNSString, [javaScriptCoreHeaderAddress]),
            (resolvedSymbols.destroyStringImpl, [javaScriptCoreHeaderAddress]),
            (resolvedSymbols.backendDispatcherDispatch, [webKitHeaderAddress, javaScriptCoreHeaderAddress]),
        ]
        for (result, expectedHeaders) in expectedHeadersBySymbol {
            guard case let .found(address) = result else {
                continue
            }
            guard resolvedAddress(address, belongsToAnyOf: expectedHeaders) else {
                return failure(
                    .resolvedAddressImageMismatch,
                    phase: phase,
                    source: source,
                    missingFunctions: unsafe missingFunctionNames(in: resolvedSymbols),
                    usedConnectDisconnectFallback: usedConnectDisconnectFallback
                )
            }
        }

        let missingFunctions = unsafe missingFunctionNames(in: resolvedSymbols)
        let missingConnectDisconnect = missingFunctions.filter {
            $0 == "connectFrontend" || $0 == "disconnectFrontend"
        }
        if !missingConnectDisconnect.isEmpty {
            return failure(
                .connectDisconnectSymbolMissing,
                phase: phase,
                source: source,
                missingFunctions: missingConnectDisconnect,
                usedConnectDisconnectFallback: usedConnectDisconnectFallback
            )
        }

        let missingRuntimeFunctions = missingFunctions.filter {
            $0 != "connectFrontend" && $0 != "disconnectFrontend"
        }
        if !missingRuntimeFunctions.isEmpty {
            return failure(
                .runtimeFunctionSymbolMissing,
                phase: phase,
                source: source,
                missingFunctions: missingRuntimeFunctions,
                usedConnectDisconnectFallback: usedConnectDisconnectFallback
            )
        }

        guard let functionAddresses = resolvedFunctionAddresses(from: resolvedSymbols) else {
            return failure(
                .runtimeFunctionSymbolMissing,
                phase: phase,
                source: source,
                missingFunctions: unsafe missingFunctionNames(in: resolvedSymbols),
                usedConnectDisconnectFallback: usedConnectDisconnectFallback
            )
        }
        return successResolution(
            functionAddresses,
            phase: phase,
            source: source,
            usedConnectDisconnectFallback: usedConnectDisconnectFallback
        )
    }

    fileprivate static func loadedWebKitImage(pathSuffixes: [String]) -> LoadedNativeInspectorImage? {
        guard let image = unsafe MachOKitSymbolLookup.loadedImage(matching: pathSuffixes) else {
            return nil
        }

        return LoadedNativeInspectorImage(
            headerAddress: unsafe UInt(bitPattern: image.ptr)
        )
    }

    private static func imagePathMatches(_ path: String?, suffixes: [String]) -> Bool {
        guard let path else {
            return false
        }
        return suffixes.contains { path.hasSuffix($0) }
    }

    private static func textSegment(in image: MachOImage) -> SegmentCommand64? {
        image.segments64.first(where: { $0.segmentName == "__TEXT" })
    }

    private static func sharedCacheSymbolFileURLs() -> [URL] {
        sharedCacheSymbolFileURLs(activeSharedCachePath: unsafe MachOKitSymbolLookup.hostSharedCachePath)
    }

    fileprivate static func sharedCacheSymbolFileURLs(activeSharedCachePath: String?) -> [URL] {
        let fileManager = FileManager.default
        var urls = [URL]()
        var seenPaths = Set<String>()

        func appendURL(_ url: URL) {
            let standardizedPath = url.standardizedFileURL.path
            guard seenPaths.insert(standardizedPath).inserted else {
                return
            }
            urls.append(url)
        }

        if let activeSharedCacheSymbolURL = activeSharedCacheSymbolFileURL(activeSharedCachePath: activeSharedCachePath) {
            appendURL(activeSharedCacheSymbolURL)
        }

        for directoryPath in sharedCacheDirectoryCandidates {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directoryPath) else {
                continue
            }

            let sortedEntries = entries
                .filter { entry in
                    entry.hasPrefix(sharedCacheFilePrefix) && entry.hasSuffix(".symbols")
                }
                .sorted { lhs, rhs in
                    sharedCacheSortKey(for: lhs) < sharedCacheSortKey(for: rhs)
                }

            for entry in sortedEntries {
                appendURL(
                    URL(fileURLWithPath: directoryPath, isDirectory: true)
                        .appendingPathComponent(entry)
                )
            }
        }
        return urls
    }

    private static func activeSharedCacheSymbolFileURL(activeSharedCachePath: String?) -> URL? {
        guard let activeSharedCachePath,
              !activeSharedCachePath.isEmpty else {
            return nil
        }

        if activeSharedCachePath.hasSuffix(".symbols") {
            return URL(fileURLWithPath: activeSharedCachePath)
        }

        return URL(fileURLWithPath: activeSharedCachePath + ".symbols")
    }

    private static func sharedCacheSortKey(for fileName: String) -> Int {
        if fileName.contains("arm64e") {
            return 0
        }
        if fileName.contains("arm64") {
            return 1
        }
        return 2
    }

    private static func fileBackedLocalSymbols(
        mainCacheHeader: DyldCacheHeader,
        dylibOffset: UInt64
    ) throws -> MachOKitFileBackedLocalSymbols {
        let symbolCacheURLs = sharedCacheSymbolFileURLs()
        guard !symbolCacheURLs.isEmpty else {
            throw NativeInspectorSymbolLookupFailure(
                kind: .localSymbolsUnavailable,
                detail: nil
            )
        }

        var lastFailure: NativeInspectorSymbolLookupFailure?

        for symbolCacheURL in symbolCacheURLs {
            do {
                let symbolCache = try DyldCache(
                    subcacheUrl: symbolCacheURL,
                    mainCacheHeader: mainCacheHeader
                )
                guard let localSymbolsInfo = symbolCache.localSymbolsInfo else {
                    lastFailure = NativeInspectorSymbolLookupFailure(
                        kind: .localSymbolsUnavailable,
                        detail: nil
                    )
                    continue
                }
                guard let entry = localSymbolsInfo.entries(in: symbolCache).first(where: { UInt64($0.dylibOffset) == dylibOffset }) else {
                    lastFailure = NativeInspectorSymbolLookupFailure(
                        kind: .localSymbolEntryMissing,
                        detail: nil
                    )
                    continue
                }
                guard let symbols = localSymbolsInfo.symbols64(in: symbolCache) else {
                    lastFailure = NativeInspectorSymbolLookupFailure(
                        kind: .localSymbolsUnavailable,
                        detail: nil
                    )
                    continue
                }

                return MachOKitFileBackedLocalSymbols(
                    symbols: symbols,
                    symbolRange: entry.nlistRange
                )
            } catch {
                lastFailure = NativeInspectorSymbolLookupFailure(
                    kind: .localSymbolsUnavailable,
                    detail: nil
                )
            }
        }

        throw lastFailure ?? NativeInspectorSymbolLookupFailure(
            kind: .localSymbolsUnavailable,
            detail: nil
        )
    }

    private static func resolveLoadedImageSymbol(
        named symbolName: String,
        in image: MachOImage,
        text: SegmentCommand64
    ) -> ResolvedNativeInspectorAddress {
        guard let symbol = image.symbol(named: symbolName, mangled: true, inSection: 0, isGlobalOnly: false) else {
            return unsafe resolveLoadedImageExportedSymbol(
                named: symbolName,
                in: image,
                text: text
            )
        }
        guard symbol.offset >= 0 else {
            return .missing
        }

        let offset = UInt64(symbol.offset)
        let address = unsafe UInt64(UInt(bitPattern: image.ptr)) + offset
        guard offset < UInt64(text.virtualMemorySize) else {
            return .outsideText(address)
        }

        return .found(address)
    }

    @unsafe private static func resolveLoadedImageExportedSymbol(
        named symbolName: String,
        in image: MachOImage,
        text: SegmentCommand64
    ) -> ResolvedNativeInspectorAddress {
        let exportTrie = image.exportTrie
        if let exportedSymbol = exportTrie?.search(by: symbolName),
           let offset = exportedSymbol.offset,
           offset >= 0 {
            let unsignedOffset = UInt64(offset)
            let address = unsafe UInt64(UInt(bitPattern: image.ptr)) + unsignedOffset
            guard unsignedOffset < UInt64(text.virtualMemorySize) else {
                logLoadedImageExportLookup(
                    symbolName: symbolName,
                    image: image,
                    exportTrieAvailable: exportTrie != nil,
                    exportTrieFound: true,
                    dlsymAddress: nil,
                    failedReason: "export-trie-outside-text"
                )
                return .outsideText(address)
            }
            return .found(address)
        }

        guard let address = unsafe MachOKitSymbolLookup.exportedRuntimeSymbolAddress(named: symbolName) else {
            logLoadedImageExportLookup(
                symbolName: symbolName,
                image: image,
                exportTrieAvailable: exportTrie != nil,
                exportTrieFound: false,
                dlsymAddress: nil,
                failedReason: "dlsym-missing"
            )
            return .missing
        }

        let expectedHeaderAddress = unsafe UInt(bitPattern: image.ptr)
        guard resolvedAddress(address, belongsToAnyOf: [expectedHeaderAddress]) else {
            logLoadedImageExportLookup(
                symbolName: symbolName,
                image: image,
                exportTrieAvailable: exportTrie != nil,
                exportTrieFound: false,
                dlsymAddress: address,
                failedReason: "dlsym-header-mismatch"
            )
            return .missing
        }

        let imageBaseAddress = UInt64(expectedHeaderAddress)
        let textStart = imageBaseAddress
        let textEnd = textStart + UInt64(text.virtualMemorySize)
        guard address >= textStart, address < textEnd else {
            logLoadedImageExportLookup(
                symbolName: symbolName,
                image: image,
                exportTrieAvailable: exportTrie != nil,
                exportTrieFound: false,
                dlsymAddress: address,
                failedReason: "dlsym-outside-text"
            )
            return .outsideText(address)
        }
        return .found(address)
    }

    private static func logLoadedImageExportLookup(
        symbolName: String,
        image: MachOImage,
        exportTrieAvailable: Bool,
        exportTrieFound: Bool,
        dlsymAddress: UInt64?,
        failedReason: String
    ) {
        #if DEBUG
        if NativeInspectorSymbolDiagnostics.verboseConsoleDiagnosticsEnabled {
            let headerAddress = unsafe UInt(bitPattern: image.ptr)
            let dlsymDescription: String
            if let dlsymAddress {
                dlsymDescription = unsafe String(format: "0x%llx", dlsymAddress)
            } else {
                dlsymDescription = "nil"
            }
            NSLog(
                "[V2_WebInspectorTransport] native inspector export lookup failed symbol=%@ header=0x%llx exportTrieAvailable=%@ exportTrieFound=%@ dlsym=%@ reason=%@",
                symbolName,
                UInt64(headerAddress),
                exportTrieAvailable ? "true" : "false",
                exportTrieFound ? "true" : "false",
                dlsymDescription,
                failedReason
            )
        }
        #endif
    }

    private static func resolveSharedCacheSymbol(
        named symbolName: String,
        symbols: MachOImage.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> ResolvedNativeInspectorAddress {
        for symbolIndex in symbolRange {
            let symbol = symbols[symbolIndex]
            guard symbol.name == symbolName else {
                continue
            }
            guard symbol.offset >= 0 else {
                return .missing
            }

            let unslidAddress = UInt64(symbol.offset)
            let actualAddress = slide + unslidAddress
            guard unslidAddress >= textVMAddress else {
                return .outsideText(actualAddress)
            }

            let offsetWithinText = unslidAddress - textVMAddress
            let resolvedAddress = textRange.lowerBound + offsetWithinText
            guard textRange.contains(resolvedAddress), resolvedAddress == actualAddress else {
                return .outsideText(actualAddress)
            }
            return .found(actualAddress)
        }

        return .missing
    }

    private static func resolveSharedCacheSymbol(
        named symbolName: String,
        symbols: MachOFile.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> ResolvedNativeInspectorAddress {
        for symbolIndex in symbolRange {
            let symbol = symbols[symbolIndex]
            guard symbol.name == symbolName else {
                continue
            }
            guard symbol.offset >= 0 else {
                return .missing
            }

            let unslidAddress = UInt64(symbol.offset)
            let actualAddress = slide + unslidAddress
            guard unslidAddress >= textVMAddress else {
                return .outsideText(actualAddress)
            }

            let offsetWithinText = unslidAddress - textVMAddress
            let resolvedAddress = textRange.lowerBound + offsetWithinText
            guard textRange.contains(resolvedAddress), resolvedAddress == actualAddress else {
                return .outsideText(actualAddress)
            }
            return .found(actualAddress)
        }

        return .missing
    }

    @unsafe private static func resolvedCallTargetAddresses(
        symbolNames: [String],
        in image: MachOImage?,
        text: SegmentCommand64?
    ) -> Set<UInt64> {
        guard let image, let text else {
            return []
        }
        var addresses = Set<UInt64>()
        for symbolName in symbolNames {
            let resolved = resolveLoadedImageSymbol(
                named: symbolName,
                in: image,
                text: text
            )
            if case let .found(address) = resolved {
                addresses.insert(address)
            }
        }
        return addresses
    }

    @unsafe private static func boundCallTargetAddresses(
        symbolNames: [String],
        in image: MachOImage
    ) -> Set<UInt64> {
        let nameSet = Set(symbolNames)
        var addresses = Set<UInt64>()
        for bindingSymbol in image.bindingSymbols where nameSet.contains(bindingSymbol.symbolName) {
            if let address = bindingSymbol.address(in: image) {
                addresses.insert(UInt64(address))
            }
        }
        for bindingSymbol in image.lazyBindingSymbols where nameSet.contains(bindingSymbol.symbolName) {
            if let address = bindingSymbol.address(in: image) {
                addresses.insert(UInt64(address))
            }
        }
        if let indirectSymbols = image.indirectSymbols {
            let symbols = image.symbols
            for section in image.sections {
                guard let indirectSymbolIndex = section.indirectSymbolIndex,
                      let count = section.numberOfIndirectSymbols,
                      count > 0 else {
                    continue
                }
                let stride = section.size / count
                for elementIndex in 0 ..< count {
                    let indirectSymbol = indirectSymbols[indirectSymbolIndex + elementIndex]
                    guard let symbolIndex = indirectSymbol.index else {
                        continue
                    }
                    let symbolPosition = symbols.index(symbols.startIndex, offsetBy: symbolIndex)
                    let symbol = symbols[symbolPosition]
                    guard nameSet.contains(symbol.name) else {
                        continue
                    }
                    let address = section.address + stride * elementIndex
                    addresses.insert(UInt64(address))
                }
            }
        }
        return addresses
    }

    @unsafe private static func resolvedFallbackFunctionStartAddress(
        in image: MachOImage,
        text: SegmentCommand64,
        functionStartAddresses: [UInt64],
        callTargetAddresses: Set<UInt64>
    ) -> ResolvedNativeInspectorAddress {
        guard !callTargetAddresses.isEmpty else {
            return .missing
        }
        let textPointer = unsafe image.ptr.assumingMemoryBound(to: UInt8.self)
        let imageBase = unsafe UInt64(UInt(bitPattern: image.ptr))
        let textBaseAddress = imageBase
        let textSize = Int(text.virtualMemorySize)
        let uniqueFunctionStart = unsafe uniqueFunctionStartContainingCallTargets(
            architecture: currentArchitectureName(),
            textBaseAddress: textBaseAddress,
            textPointer: textPointer,
            textSize: textSize,
            functionStartAddresses: functionStartAddresses,
            callTargetAddresses: callTargetAddresses
        )
        guard let uniqueFunctionStart else {
            return .missing
        }
        return .found(uniqueFunctionStart)
    }

    @unsafe fileprivate static func uniqueFunctionStartContainingCallTargets(
        architecture: String,
        textBaseAddress: UInt64,
        textPointer: UnsafePointer<UInt8>,
        textSize: Int,
        functionStartAddresses: [UInt64],
        callTargetAddresses: Set<UInt64>
    ) -> UInt64? {
        guard !callTargetAddresses.isEmpty else {
            return nil
        }

        let sortedFunctionStarts = functionStartAddresses.sorted()
        var matches = Set<UInt64>()
        for (index, functionStart) in sortedFunctionStarts.enumerated() {
            let functionEnd = index + 1 < sortedFunctionStarts.count
                ? sortedFunctionStarts[index + 1]
                : textBaseAddress + UInt64(textSize)
            guard functionStart >= textBaseAddress, functionEnd > functionStart else {
                continue
            }
            let startOffset = Int(functionStart - textBaseAddress)
            let endOffset = Int(functionEnd - textBaseAddress)
            guard startOffset >= 0, endOffset <= textSize else {
                continue
            }
            if unsafe functionContainsCallTarget(
                architecture: architecture,
                textBaseAddress: textBaseAddress,
                textPointer: textPointer,
                startOffset: startOffset,
                endOffset: endOffset,
                callTargetAddresses: callTargetAddresses
            ) {
                matches.insert(functionStart)
            }
        }
        guard matches.count == 1 else {
            return nil
        }
        return matches.first
    }

    @unsafe private static func functionContainsCallTarget(
        architecture: String,
        textBaseAddress: UInt64,
        textPointer: UnsafePointer<UInt8>,
        startOffset: Int,
        endOffset: Int,
        callTargetAddresses: Set<UInt64>
    ) -> Bool {
        #if arch(arm64) || arch(arm64e)
        if architecture == "arm64" || architecture == "arm64e" {
            var offset = startOffset
            while offset + MemoryLayout<UInt32>.size <= endOffset {
                let instruction = unsafe UnsafeRawPointer(textPointer.advanced(by: offset)).load(as: UInt32.self)
                if let target = decodedArm64BranchTarget(
                    instruction: instruction,
                    instructionAddress: textBaseAddress + UInt64(offset)
                ), callTargetAddresses.contains(target) {
                    return true
                }
                offset += MemoryLayout<UInt32>.size
            }
            return false
        }
        #endif

        if architecture == "x86_64" {
            var offset = startOffset
            while offset + 5 <= endOffset {
                if unsafe textPointer.advanced(by: offset).pointee == 0xE8,
                   let target = unsafe decodedX86CallTarget(
                    textPointer: textPointer,
                    callOffset: offset,
                    textBaseAddress: textBaseAddress
                   ),
                   callTargetAddresses.contains(target) {
                    return true
                }
                offset += 1
            }
        }
        return false
    }

    #if arch(arm64) || arch(arm64e)
    private static func decodedArm64BranchTarget(
        instruction: UInt32,
        instructionAddress: UInt64
    ) -> UInt64? {
        // Match both `B` and `BL` immediate branches.
        let opcodeMask: UInt32 = 0x7C000000
        let branchOpcode: UInt32 = 0x14000000
        guard instruction & opcodeMask == branchOpcode else {
            return nil
        }

        let immediateMask: UInt32 = 0x03FFFFFF
        let immediate = Int32(bitPattern: instruction & immediateMask)
        let signedImmediate = (immediate << 6) >> 4
        let target = Int64(bitPattern: instructionAddress) + Int64(signedImmediate)
        guard target >= 0 else {
            return nil
        }
        return UInt64(target)
    }
    #endif

    private static func decodedX86CallTarget(
        textPointer: UnsafePointer<UInt8>,
        callOffset: Int,
        textBaseAddress: UInt64
    ) -> UInt64? {
        let displacement = unsafe UnsafeRawPointer(textPointer).loadUnaligned(
            fromByteOffset: callOffset + 1,
            as: Int32.self
        )
        let nextInstructionAddress = Int64(textBaseAddress) + Int64(callOffset + 5)
        let target = nextInstructionAddress + Int64(displacement)
        guard target >= 0 else {
            return nil
        }
        return UInt64(target)
    }

    private static func currentArchitectureName() -> String {
        #if arch(arm64e)
        return "arm64e"
        #elseif arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unsupported"
        #endif
    }

    @unsafe private static func missingFunctionNames(
        in resolvedSymbols: NativeInspectorResolvedSymbolSet
    ) -> [String] {
        let symbolResults: [(String, ResolvedNativeInspectorAddress)] = [
            ("connectFrontend", resolvedSymbols.connectFrontend),
            ("disconnectFrontend", resolvedSymbols.disconnectFrontend),
            ("stringFromUTF8", resolvedSymbols.stringFromUTF8),
            ("stringImplToNSString", resolvedSymbols.stringImplToNSString),
            ("destroyStringImpl", resolvedSymbols.destroyStringImpl),
            ("backendDispatcherDispatch", resolvedSymbols.backendDispatcherDispatch),
        ]
        return symbolResults.compactMap { name, result in
            if case .missing = result {
                return name
            }
            return nil
        }
    }

    private static func isFound(_ result: ResolvedNativeInspectorAddress) -> Bool {
        if case .found = result {
            return true
        }
        return false
    }

    private static func debugResolvedAddress(_ result: ResolvedNativeInspectorAddress) -> String {
        switch result {
        case let .found(address):
            return unsafe String(format: "found(0x%llx)", address)
        case let .outsideText(address):
            return unsafe String(format: "outsideText(0x%llx)", address)
        case .missing:
            return "missing"
        }
    }

    fileprivate static func resolvedAddress(
        _ address: UInt64,
        belongsToAnyOf expectedHeaderAddresses: [UInt]
    ) -> Bool {
        guard let image = unsafe MachOKitSymbolLookup.image(containingAddress: address) else {
            return false
        }
        return expectedHeaderAddresses.contains(unsafe UInt(bitPattern: image.ptr))
    }

    private static func failure(
        _ kind: NativeInspectorSymbolFailure,
        detail: String? = nil,
        phase: NativeInspectorSymbolResolutionPhase? = nil,
        source: String? = nil,
        missingFunctions: [String] = [],
        usedConnectDisconnectFallback: Bool = false
    ) -> NativeInspectorSymbolLookupResult {
        let reason = formattedFailureReason(
            kind: kind,
            detail: detail,
            phase: phase,
            source: source,
            missingFunctions: missingFunctions,
            usedConnectDisconnectFallback: usedConnectDisconnectFallback
        )
        NSLog(
            "[V2_WebInspectorNativeSymbols] native inspector symbol lookup failed backend=%@ reason=%@",
            "native-inspector",
            reason
        )
        return NativeInspectorSymbolLookupResult(
            functionAddresses: .zero,
            failureReason: reason,
            failureKind: kind,
            phase: phase,
            missingFunctions: missingFunctions,
            source: source,
            usedConnectDisconnectFallback: usedConnectDisconnectFallback
        )
    }

    private static func formattedFailureReason(
        kind: NativeInspectorSymbolFailure,
        detail: String?,
        phase: NativeInspectorSymbolResolutionPhase?,
        source: String?,
        missingFunctions: [String],
        usedConnectDisconnectFallback: Bool
    ) -> String {
        var parts = [String]()
        if let phase {
            parts.append("phase=\(phase.message)")
        }
        if let source, !source.isEmpty {
            parts.append("source=\(source)")
        }
        if !missingFunctions.isEmpty {
            parts.append("missing=\(missingFunctions.joined(separator: ","))")
        }
        if usedConnectDisconnectFallback {
            parts.append("fallback=text-scan")
        }
        if let detail, !detail.isEmpty {
            parts.append(detail)
        }
        if parts.isEmpty {
            return kind.message
        }
        return "\(kind.message): \(parts.joined(separator: " "))"
    }
}

package enum NativeInspectorSymbolResolver {
    package static func resolveCurrent() -> NativeInspectorSymbolResolution {
        makeAttachResolution(from: NativeInspectorSymbolResolverCore.resolveCurrentWebKitAttachSymbols())
    }

    static func resolveForTesting(
        imagePathSuffixes: [String] = NativeInspectorSymbolResolverCore.webKitImagePathSuffixes,
        connectSymbol: ObfuscatedSymbolName = NativeInspectorSymbolResolverCore.connectFrontendSymbol,
        disconnectSymbol: ObfuscatedSymbolName = NativeInspectorSymbolResolverCore.disconnectFrontendSymbol,
        alternateConnectSymbols: [ObfuscatedSymbolName] = [],
        alternateDisconnectSymbols: [ObfuscatedSymbolName] = [],
        stringFromUTF8Symbol: ObfuscatedSymbolName? = nil,
        stringImplToNSStringSymbol: ObfuscatedSymbolName? = nil,
        destroyStringImplSymbol: ObfuscatedSymbolName? = nil,
        backendDispatcherDispatchSymbol: ObfuscatedSymbolName? = nil
    ) -> NativeInspectorSymbolResolution {
        makeAttachResolution(
            from: NativeInspectorSymbolResolverCore.resolveForTesting(
                imagePathSuffixes: imagePathSuffixes,
                connectSymbol: connectSymbol,
                disconnectSymbol: disconnectSymbol,
                alternateConnectSymbols: alternateConnectSymbols,
                alternateDisconnectSymbols: alternateDisconnectSymbols,
                stringFromUTF8Symbol: stringFromUTF8Symbol,
                stringImplToNSStringSymbol: stringImplToNSStringSymbol,
                destroyStringImplSymbol: destroyStringImplSymbol,
                backendDispatcherDispatchSymbol: backendDispatcherDispatchSymbol
            )
        )
    }

    static func loadedImageHeaderAddressesForTesting() -> (webKit: UInt, javaScriptCore: UInt)? {
        guard let loadedImage = NativeInspectorSymbolResolverCore.loadedWebKitImage(
            pathSuffixes: NativeInspectorSymbolResolverCore.webKitImagePathSuffixes
        ), let loadedJavaScriptCoreImage = NativeInspectorSymbolResolverCore.loadedWebKitImage(
            pathSuffixes: NativeInspectorSymbolResolverCore.javaScriptCoreImagePathSuffixes
        ) else {
            return nil
        }

        return (
            webKit: loadedImage.headerAddress,
            javaScriptCore: loadedJavaScriptCoreImage.headerAddress
        )
    }

    static func resolvedAddressMatchesExpectedImageForTesting(
        _ address: UInt64,
        expectedHeaderAddresses: [UInt]
    ) -> Bool {
        NativeInspectorSymbolResolverCore.resolvedAddress(
            address,
            belongsToAnyOf: expectedHeaderAddresses
        )
    }

    static func sharedCacheSymbolFileURLsForTesting(activeSharedCachePath: String?) -> [URL] {
        NativeInspectorSymbolResolverCore.sharedCacheSymbolFileURLs(
            activeSharedCachePath: activeSharedCachePath
        )
    }

    static func imagePathSuffixesForTesting() -> (
        webKit: [String],
        javaScriptCore: [String],
        webCore: [String]
    ) {
        (
            webKit: NativeInspectorSymbolResolverCore.webKitImagePathSuffixes,
            javaScriptCore: NativeInspectorSymbolResolverCore.javaScriptCoreImagePathSuffixes,
            webCore: NativeInspectorSymbolResolverCore.webCoreImagePathSuffixes
        )
    }

    static func connectSymbolsForTesting() -> [ObfuscatedSymbolName] {
        [NativeInspectorSymbolResolverCore.connectFrontendSymbol]
    }

    static func disconnectSymbolsForTesting() -> [ObfuscatedSymbolName] {
        [NativeInspectorSymbolResolverCore.disconnectFrontendSymbol]
    }

    static func sensitiveSymbolsForBinarySafetyTesting() -> [ObfuscatedSymbolName] {
        [
            NativeInspectorSymbolResolverCore.connectFrontendSymbol,
            NativeInspectorSymbolResolverCore.disconnectFrontendSymbol,
            NativeInspectorSymbolResolverCore.stringFromUTF8Symbol,
            NativeInspectorSymbolResolverCore.stringImplToNSStringSymbol,
            NativeInspectorSymbolResolverCore.destroyStringImplSymbol,
            NativeInspectorSymbolResolverCore.backendDispatcherDispatchSymbol,
            NativeInspectorSymbolResolverCore.pageInspectorControllerConnectSymbol,
            NativeInspectorSymbolResolverCore.pageInspectorControllerDisconnectSymbol,
            NativeInspectorSymbolResolverCore.frameInspectorControllerConnectSymbol,
            NativeInspectorSymbolResolverCore.frameInspectorControllerDisconnectSymbol,
        ]
    }

    @unsafe static func uniqueFunctionStartContainingCallTargetsForTesting(
        architecture: String,
        textBaseAddress: UInt64,
        textPointer: UnsafePointer<UInt8>,
        textSize: Int,
        functionStartAddresses: [UInt64],
        callTargetAddresses: Set<UInt64>
    ) -> UInt64? {
        unsafe NativeInspectorSymbolResolverCore.uniqueFunctionStartContainingCallTargets(
            architecture: architecture,
            textBaseAddress: textBaseAddress,
            textPointer: textPointer,
            textSize: textSize,
            functionStartAddresses: functionStartAddresses,
            callTargetAddresses: callTargetAddresses
        )
    }

    private static func makeAttachResolution(from resolution: NativeInspectorSymbolLookupResult) -> NativeInspectorSymbolResolution {
        NativeInspectorSymbolResolution(
            addresses: resolution.functionAddresses,
            failureReason: resolution.failureReason,
            failureKind: resolution.failureKind?.message,
            phase: resolution.phase?.message,
            missingFunctions: resolution.missingFunctions,
            source: resolution.source,
            usedConnectDisconnectFallback: resolution.usedConnectDisconnectFallback
        )
    }
}
#endif

#if !os(iOS) && !os(macOS)
package enum NativeInspectorSymbolResolver {
    package static func resolveCurrent() -> NativeInspectorSymbolResolution {
        NativeInspectorSymbolResolution(
            addresses: .zero,
            failureReason: "V2_WebInspectorTransport is only available on iOS and macOS.",
            failureKind: "unsupported",
            phase: nil,
            missingFunctions: [],
            source: nil,
            usedConnectDisconnectFallback: false
        )
    }

    static func resolveForTesting(
        imagePathSuffixes: [String] = [],
        connectSymbol: String = "",
        disconnectSymbol: String = "",
        alternateConnectSymbols: [String] = [],
        alternateDisconnectSymbols: [String] = [],
        stringFromUTF8Symbol: String? = nil,
        stringImplToNSStringSymbol: String? = nil,
        destroyStringImplSymbol: String? = nil,
        backendDispatcherDispatchSymbol: String? = nil
    ) -> NativeInspectorSymbolResolution {
        return resolveCurrent()
    }
}
#endif
