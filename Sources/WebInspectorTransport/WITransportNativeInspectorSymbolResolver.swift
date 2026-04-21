#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

private enum WITransportNativeInspectorObfuscation {
    static func deobfuscate(_ reverseTokens: [String]) -> String {
        reverseTokens.reversed().joined()
    }
}

private enum WITransportNativeInspectorSymbolFailure {
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
            // runtime cache unavailable
            return WITransportNativeInspectorObfuscation.deobfuscate(["e", "availabl", "cache un", "runtime "])
        case .localSymbolsUnavailable:
            // local symbol lookup unavailable
            return WITransportNativeInspectorObfuscation.deobfuscate(["ailable", "kup unav", "mbol loo", "local sy"])
        case .inspectorImageMissing:
            // inspector image unavailable
            return WITransportNativeInspectorObfuscation.deobfuscate(["ble", "unavaila", "r image ", "inspecto"])
        case .supportImageMissing:
            // support image unavailable
            return WITransportNativeInspectorObfuscation.deobfuscate(["e", "availabl", "image un", "support "])
        case .localSymbolEntryMissing:
            // local symbol entry unavailable
            return WITransportNativeInspectorObfuscation.deobfuscate(["ilable", "ry unava", "mbol ent", "local sy"])
        case .connectDisconnectSymbolMissing:
            // attach entry point unavailable
            return WITransportNativeInspectorObfuscation.deobfuscate(["ilable", "nt unava", "ntry poi", "attach e"])
        case .runtimeFunctionSymbolMissing:
            // runtime helper unavailable
            return WITransportNativeInspectorObfuscation.deobfuscate(["le", "navailab", "helper u", "runtime "])
        case .resolvedAddressOutsideText:
            // resolved address invalid
            return WITransportNativeInspectorObfuscation.deobfuscate([" invalid", " address", "resolved"])
        case .resolvedAddressImageMismatch:
            // resolved address image mismatch
            return WITransportNativeInspectorObfuscation.deobfuscate(["ismatch", " image m", " address", "resolved"])
        }
    }
}

private enum WITransportNativeInspectorResolutionPhase {
    case loadedImage
    case sharedCache
    case sharedCacheFile

    var message: String {
        switch self {
        case .loadedImage:
            // loaded-image
            return WITransportNativeInspectorObfuscation.deobfuscate(["mage", "loaded-i"])
        case .sharedCache:
            // shared-cache
            return WITransportNativeInspectorObfuscation.deobfuscate(["ache", "shared-c"])
        case .sharedCacheFile:
            // shared-cache-file
            return WITransportNativeInspectorObfuscation.deobfuscate(["e", "ache-fil", "shared-c"])
        }
    }
}

private struct WITransportLoadedWebKitImage {
    let headerAddress: UInt

    var header: UnsafePointer<mach_header> {
        unsafe UnsafePointer<mach_header>(bitPattern: headerAddress)!
    }
}

private struct WITransportFileBackedLocalSymbols {
    let symbols: MachOFile.Symbols64
    let symbolRange: Range<Int>
}

private struct WITransportLookupFailure: Error {
    let kind: WITransportNativeInspectorSymbolFailure
    let detail: String?
}

private enum WITransportResolvedAddress {
    case found(UInt64)
    case missing
    case outsideText(UInt64)
}

private struct WITransportResolvedFunctionAddresses: Sendable {
    let connectFrontendAddress: UInt64
    let disconnectFrontendAddress: UInt64
    let stringFromUTF8Address: UInt64
    let stringImplToNSStringAddress: UInt64
    let destroyStringImplAddress: UInt64
    let backendDispatcherDispatchAddress: UInt64

    static let zero = WITransportResolvedFunctionAddresses(
        connectFrontendAddress: 0,
        disconnectFrontendAddress: 0,
        stringFromUTF8Address: 0,
        stringImplToNSStringAddress: 0,
        destroyStringImplAddress: 0,
        backendDispatcherDispatchAddress: 0
    )
}

private struct WITransportNativeInspectorSymbolResolution: Sendable {
    let functionAddresses: WITransportResolvedFunctionAddresses
    let failureReason: String?
    let failureKind: WITransportNativeInspectorSymbolFailure?
    let phase: WITransportNativeInspectorResolutionPhase?
    let missingFunctions: [String]
    let source: String?
    let usedConnectDisconnectFallback: Bool
}

private struct WITransportNativeInspectorSymbolNames {
    let connectFrontend: [String]
    let disconnectFrontend: [String]
    let inspectorControllerConnectTargets: [String]
    let inspectorControllerDisconnectTargets: [String]
    let stringFromUTF8: [String]
    let stringImplToNSString: [String]
    let destroyStringImpl: [String]
    let backendDispatcherDispatch: [String]
}

private struct WITransportNativeInspectorResolvedSymbols {
    let connectFrontend: WITransportResolvedAddress
    let disconnectFrontend: WITransportResolvedAddress
    let stringFromUTF8: WITransportResolvedAddress
    let stringImplToNSString: WITransportResolvedAddress
    let destroyStringImpl: WITransportResolvedAddress
    let backendDispatcherDispatch: WITransportResolvedAddress
}

private struct WITransportResolvedConnectDisconnectFallbackResult {
    let symbols: WITransportNativeInspectorResolvedSymbols
    let usedFallback: Bool
}

private enum WITransportNativeInspectorResolver {
    fileprivate static let webKitImagePathSuffixes = [
        // /System/Library/Frameworks/WebKit.framework/WebKit
        WITransportNativeInspectorObfuscation.deobfuscate(["it", "ork/WebK", "t.framew", "ks/WebKi", "Framewor", "Library/", "/System/"]),
        // /System/Library/Frameworks/WebKit.framework/Versions/A/WebKit
        WITransportNativeInspectorObfuscation.deobfuscate(["ebKit", "ions/A/W", "ork/Vers", "t.framew", "ks/WebKi", "Framewor", "Library/", "/System/"]),
    ]
    fileprivate static let javaScriptCoreImagePathSuffixes = [
        // /System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore
        WITransportNativeInspectorObfuscation.deobfuscate(["re", "ScriptCo", "ork/Java", "e.framew", "criptCor", "ks/JavaS", "Framewor", "Library/", "/System/"]),
        // /System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore
        WITransportNativeInspectorObfuscation.deobfuscate(["tCore", "avaScrip", "ions/A/J", "ork/Vers", "e.framew", "criptCor", "ks/JavaS", "Framewor", "Library/", "/System/"]),
    ]
    fileprivate static let webCoreImagePathSuffixes = [
        "/System/Library/PrivateFrameworks/WebCore.framework/WebCore",
        "/System/Library/PrivateFrameworks/WebCore.framework/Versions/A/WebCore",
    ]
    // __TEXT
    private static let textSegmentName = WITransportNativeInspectorObfuscation.deobfuscate(["__TEXT"])
    // dyld_shared_cache_
    private static let sharedCacheFilePrefix = WITransportNativeInspectorObfuscation.deobfuscate(["e_", "red_cach", "dyld_sha"])
    // .symbols
    private static let sharedCacheFileSuffix = WITransportNativeInspectorObfuscation.deobfuscate([".symbols"])
    // arm64e
    private static let arm64eArchitecture = WITransportNativeInspectorObfuscation.deobfuscate(["arm64e"])
    // arm64
    private static let arm64Architecture = WITransportNativeInspectorObfuscation.deobfuscate(["arm64"])
    // __ZN6WebKit26WebPageInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb
    fileprivate static let connectFrontendSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["annelEbb", "ontendCh", "ctor15Fr", "RN9Inspe", "rontendE", "connectF", "roller15", "ctorCont", "ageInspe", "it26WebP", "_ZN6WebK", "_"])
    // __ZN6WebKit26WebPageInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE
    fileprivate static let disconnectFrontendSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["ChannelE", "Frontend", "pector15", "dERN9Ins", "tFronten", "isconnec", "oller18d", "torContr", "geInspec", "t26WebPa", "ZN6WebKi", "__"])
    // [WebInspectorTransport] native inspector symbols resolved backend=%@ phase=%@
    private static let successLogFormat = WITransportNativeInspectorObfuscation.deobfuscate(["se=%@", "d=%@ pha", "d backen", " resolve", " symbols", "nspector", "native i", "nsport] ", "ectorTra", "[WebInsp"])
    // [WebInspectorTransport] native inspector symbol lookup failed backend=%@ reason=%@
    private static let failureLogFormat = WITransportNativeInspectorObfuscation.deobfuscate(["%@", " reason=", "ckend=%@", "ailed ba", "lookup f", " symbol ", "nspector", "native i", "nsport] ", "ectorTra", "[WebInsp"])
    // __ZN3WTF6String8fromUTF8ENSt3__14spanIKDuLm18446744073709551615EEE
    private static let stringFromUTF8Symbol = WITransportNativeInspectorObfuscation.deobfuscate(["51615EEE", "40737095", "m1844674", "panIKDuL", "St3__14s", "omUTF8EN", "tring8fr", "ZN3WTF6S", "__"])
    // __ZN3WTF10StringImplcvP8NSStringEv
    private static let stringImplToNSStringSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["StringEv", "plcvP8NS", "StringIm", "ZN3WTF10", "__"])
    // __ZN3WTF10StringImpl7destroyEPS0_
    private static let destroyStringImplSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["royEPS0_", "mpl7dest", "0StringI", "_ZN3WTF1", "_"])
    // __ZN9Inspector17BackendDispatcher8dispatchERKN3WTF6StringE
    private static let backendDispatcherDispatchSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["6StringE", "ERKN3WTF", "dispatch", "patcher8", "ckendDis", "ctor17Ba", "ZN9Inspe", "__"])
    // __ZN7WebCore23PageInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb
    private static let pageInspectorControllerConnectSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["bb", "15FrontendChannelE", "RN9Inspector", "15connectFrontendE", "23PageInspectorController", "7WebCore", "__ZN"])
    // __ZN7WebCore23PageInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE
    private static let pageInspectorControllerDisconnectSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["E", "15FrontendChannel", "ERN9Inspector", "18disconnectFrontend", "23PageInspectorController", "7WebCore", "__ZN"])
    // __ZN7WebCore24FrameInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb
    private static let frameInspectorControllerConnectSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["bb", "15FrontendChannelE", "RN9Inspector", "15connectFrontendE", "24FrameInspectorController", "7WebCore", "__ZN"])
    // __ZN7WebCore24FrameInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE
    private static let frameInspectorControllerDisconnectSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["E", "15FrontendChannel", "ERN9Inspector", "18disconnectFrontend", "24FrameInspectorController", "7WebCore", "__ZN"])
    #if os(iOS)
    fileprivate static let backendKind: WITransportBackendKind = .iOSNativeInspector
    private static let sharedCacheDirectoryCandidates = [
        // /System/Library/Caches/com.apple.dyld
        WITransportNativeInspectorObfuscation.deobfuscate([".dyld", "om.apple", "Caches/c", "Library/", "/System/"]),
        // /System/Cryptexes/OS/System/Library/Caches/com.apple.dyld
        WITransportNativeInspectorObfuscation.deobfuscate(["ple.dyld", "s/com.ap", "ry/Cache", "em/Libra", "/OS/Syst", "ryptexes", "System/C", "/"]),
        // /private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld
        WITransportNativeInspectorObfuscation.deobfuscate(["ld", "apple.dy", "hes/com.", "rary/Cac", "stem/Lib", "es/OS/Sy", "/Cryptex", "/preboot", "/private"]),
    ]
    #else
    fileprivate static let backendKind: WITransportBackendKind = .macOSNativeInspector
    private static let sharedCacheDirectoryCandidates = [
        // /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld
        WITransportNativeInspectorObfuscation.deobfuscate(["ary/dyld", "tem/Libr", "s/OS/Sys", "Cryptexe", "Preboot/", "Volumes/", "/System/"]),
        // /System/Library/dyld
        WITransportNativeInspectorObfuscation.deobfuscate(["dyld", "Library/", "/System/"]),
        // /System/Cryptexes/OS/System/Library/dyld
        WITransportNativeInspectorObfuscation.deobfuscate(["ary/dyld", "tem/Libr", "s/OS/Sys", "Cryptexe", "/System/"]),
    ]
    #endif

    private static let cachedResolution = resolve(
        imagePathSuffixes: webKitImagePathSuffixes,
        javaScriptCorePathSuffixes: javaScriptCoreImagePathSuffixes,
        symbols: currentSymbolNames()
    )

    static func resolveCurrentWebKitAttachSymbols() -> WITransportNativeInspectorSymbolResolution {
        cachedResolution
    }

    static func resolveForTesting(
        imagePathSuffixes: [String] = webKitImagePathSuffixes,
        connectSymbol: String = connectFrontendSymbol,
        disconnectSymbol: String = disconnectFrontendSymbol,
        alternateConnectSymbols: [String] = [],
        alternateDisconnectSymbols: [String] = [],
        stringFromUTF8Symbol: String? = nil,
        stringImplToNSStringSymbol: String? = nil,
        destroyStringImplSymbol: String? = nil,
        backendDispatcherDispatchSymbol: String? = nil
    ) -> WITransportNativeInspectorSymbolResolution {
        resolve(
            imagePathSuffixes: imagePathSuffixes,
            javaScriptCorePathSuffixes: javaScriptCoreImagePathSuffixes,
            symbols: WITransportNativeInspectorSymbolNames(
                connectFrontend: [connectSymbol] + alternateConnectSymbols,
                disconnectFrontend: [disconnectSymbol] + alternateDisconnectSymbols,
                inspectorControllerConnectTargets: [
                    pageInspectorControllerConnectSymbol,
                    frameInspectorControllerConnectSymbol,
                ],
                inspectorControllerDisconnectTargets: [
                    pageInspectorControllerDisconnectSymbol,
                    frameInspectorControllerDisconnectSymbol,
                ],
                stringFromUTF8: [stringFromUTF8Symbol ?? self.stringFromUTF8Symbol],
                stringImplToNSString: [stringImplToNSStringSymbol ?? self.stringImplToNSStringSymbol],
                destroyStringImpl: [destroyStringImplSymbol ?? self.destroyStringImplSymbol],
                backendDispatcherDispatch: [backendDispatcherDispatchSymbol ?? self.backendDispatcherDispatchSymbol]
            )
        )
    }

    private static func currentSymbolNames() -> WITransportNativeInspectorSymbolNames {
        WITransportNativeInspectorSymbolNames(
            connectFrontend: [connectFrontendSymbol],
            disconnectFrontend: [disconnectFrontendSymbol],
            inspectorControllerConnectTargets: [
                pageInspectorControllerConnectSymbol,
                frameInspectorControllerConnectSymbol,
            ],
            inspectorControllerDisconnectTargets: [
                pageInspectorControllerDisconnectSymbol,
                frameInspectorControllerDisconnectSymbol,
            ],
            stringFromUTF8: [stringFromUTF8Symbol],
            stringImplToNSString: [stringImplToNSStringSymbol],
            destroyStringImpl: [destroyStringImplSymbol],
            backendDispatcherDispatch: [backendDispatcherDispatchSymbol]
        )
    }

    private static func resolve(
        imagePathSuffixes: [String],
        javaScriptCorePathSuffixes: [String],
        symbols: WITransportNativeInspectorSymbolNames
    ) -> WITransportNativeInspectorSymbolResolution {
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

        let loadedImageResults = WITransportNativeInspectorResolvedSymbols(
            connectFrontend: resolveLoadedImageSymbol(namedAnyOf: symbols.connectFrontend, in: image, text: text),
            disconnectFrontend: resolveLoadedImageSymbol(namedAnyOf: symbols.disconnectFrontend, in: image, text: text),
            stringFromUTF8: resolveLoadedImageSymbol(namedAnyOf: symbols.stringFromUTF8, in: javaScriptCoreImage, text: javaScriptCoreText),
            stringImplToNSString: resolveLoadedImageSymbol(namedAnyOf: symbols.stringImplToNSString, in: javaScriptCoreImage, text: javaScriptCoreText),
            destroyStringImpl: resolveLoadedImageSymbol(namedAnyOf: symbols.destroyStringImpl, in: javaScriptCoreImage, text: javaScriptCoreText),
            backendDispatcherDispatch: preferredResolvedAddress(
                resolveLoadedImageSymbol(namedAnyOf: symbols.backendDispatcherDispatch, in: image, text: text),
                fallback: resolveLoadedImageSymbol(namedAnyOf: symbols.backendDispatcherDispatch, in: javaScriptCoreImage, text: javaScriptCoreText)
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
        loadedImage: WITransportLoadedWebKitImage,
        imagePathSuffixes: [String],
        loadedJavaScriptCoreImage: WITransportLoadedWebKitImage,
        javaScriptCorePathSuffixes: [String],
        loadedImageSymbols: WITransportNativeInspectorResolvedSymbols,
        symbols: WITransportNativeInspectorSymbolNames
    ) -> WITransportNativeInspectorSymbolResolution {
        guard let sharedCacheRange = unsafe WITransportDyldRuntime.sharedCacheRange() else {
            return failure(.sharedCacheUnavailable)
        }

        let cache: DyldCacheLoaded
        do {
            cache = try unsafe DyldCacheLoaded(ptr: sharedCacheRange.pointer)
        } catch {
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
        var lastResolvedSymbols: WITransportNativeInspectorResolvedSymbols?

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
                    let resolvedSymbols = WITransportNativeInspectorResolvedSymbols(
                        connectFrontend: resolveSharedCacheSymbol(
                            namedAnyOf: symbols.connectFrontend,
                            symbols: symbols64,
                            symbolRange: lowerBound ..< upperBound,
                            textVMAddress: UInt64(text.virtualMemoryAddress),
                            textRange: textRange,
                            slide: UInt64(slide)
                        ),
                        disconnectFrontend: resolveSharedCacheSymbol(
                            namedAnyOf: symbols.disconnectFrontend,
                            symbols: symbols64,
                            symbolRange: lowerBound ..< upperBound,
                            textVMAddress: UInt64(text.virtualMemoryAddress),
                            textRange: textRange,
                            slide: UInt64(slide)
                        ),
                        stringFromUTF8: resolveSharedCacheSymbol(
                            namedAnyOf: symbols.stringFromUTF8,
                            symbols: symbols64,
                            symbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound,
                            textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                            textRange: javaScriptCoreTextRange,
                            slide: UInt64(slide)
                        ),
                        stringImplToNSString: resolveSharedCacheSymbol(
                            namedAnyOf: symbols.stringImplToNSString,
                            symbols: symbols64,
                            symbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound,
                            textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                            textRange: javaScriptCoreTextRange,
                            slide: UInt64(slide)
                        ),
                        destroyStringImpl: resolveSharedCacheSymbol(
                            namedAnyOf: symbols.destroyStringImpl,
                            symbols: symbols64,
                            symbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound,
                            textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                            textRange: javaScriptCoreTextRange,
                            slide: UInt64(slide)
                        ),
                        backendDispatcherDispatch: preferredResolvedAddress(
                            resolveSharedCacheSymbol(
                                namedAnyOf: symbols.backendDispatcherDispatch,
                                symbols: symbols64,
                                symbolRange: lowerBound ..< upperBound,
                                textVMAddress: UInt64(text.virtualMemoryAddress),
                                textRange: textRange,
                                slide: UInt64(slide)
                            ),
                            fallback: resolveSharedCacheSymbol(
                                namedAnyOf: symbols.backendDispatcherDispatch,
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
            let resolvedSymbols = WITransportNativeInspectorResolvedSymbols(
                connectFrontend: resolveSharedCacheSymbol(
                    namedAnyOf: symbols.connectFrontend,
                    symbols: fileBackedSymbols.symbols,
                    symbolRange: fileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(text.virtualMemoryAddress),
                    textRange: textRange,
                    slide: UInt64(slide)
                ),
                disconnectFrontend: resolveSharedCacheSymbol(
                    namedAnyOf: symbols.disconnectFrontend,
                    symbols: fileBackedSymbols.symbols,
                    symbolRange: fileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(text.virtualMemoryAddress),
                    textRange: textRange,
                    slide: UInt64(slide)
                ),
                stringFromUTF8: resolveSharedCacheSymbol(
                    namedAnyOf: symbols.stringFromUTF8,
                    symbols: javaScriptCoreFileBackedSymbols.symbols,
                    symbolRange: javaScriptCoreFileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                    textRange: javaScriptCoreTextRange,
                    slide: UInt64(slide)
                ),
                stringImplToNSString: resolveSharedCacheSymbol(
                    namedAnyOf: symbols.stringImplToNSString,
                    symbols: javaScriptCoreFileBackedSymbols.symbols,
                    symbolRange: javaScriptCoreFileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                    textRange: javaScriptCoreTextRange,
                    slide: UInt64(slide)
                ),
                destroyStringImpl: resolveSharedCacheSymbol(
                    namedAnyOf: symbols.destroyStringImpl,
                    symbols: javaScriptCoreFileBackedSymbols.symbols,
                    symbolRange: javaScriptCoreFileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                    textRange: javaScriptCoreTextRange,
                    slide: UInt64(slide)
                ),
                backendDispatcherDispatch: preferredResolvedAddress(
                    resolveSharedCacheSymbol(
                        namedAnyOf: symbols.backendDispatcherDispatch,
                        symbols: fileBackedSymbols.symbols,
                        symbolRange: fileBackedSymbols.symbolRange,
                        textVMAddress: UInt64(text.virtualMemoryAddress),
                        textRange: textRange,
                        slide: UInt64(slide)
                    ),
                    fallback: resolveSharedCacheSymbol(
                        namedAnyOf: symbols.backendDispatcherDispatch,
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
        } catch let lookupFailure as WITransportLookupFailure {
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
        _ primary: WITransportResolvedAddress,
        fallback: WITransportResolvedAddress
    ) -> WITransportResolvedAddress {
        switch primary {
        case .missing:
            return fallback
        default:
            return primary
        }
    }

    private static func applyingLoadedImageRuntimeFallback(
        to resolvedSymbols: WITransportNativeInspectorResolvedSymbols,
        loadedImageSymbols: WITransportNativeInspectorResolvedSymbols
    ) -> WITransportNativeInspectorResolvedSymbols {
        WITransportNativeInspectorResolvedSymbols(
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
        resolvedSymbols: WITransportNativeInspectorResolvedSymbols,
        loadedImageSymbols: WITransportNativeInspectorResolvedSymbols
    ) -> Bool {
        let symbolPairs: [(WITransportResolvedAddress, WITransportResolvedAddress)] = [
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
        preferred: WITransportNativeInspectorSymbolResolution?,
        fallback: WITransportNativeInspectorSymbolResolution
    ) -> WITransportNativeInspectorSymbolResolution {
        guard let preferred else {
            return fallback
        }
        if preferred.failureReason == nil {
            return fallback.failureReason == nil ? fallback : preferred
        }
        guard fallback.failureReason != nil else {
            return fallback
        }

        let genericFailureKinds: Set<WITransportNativeInspectorSymbolFailure> = [
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
        return WITransportNativeInspectorSymbolResolution(
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
    ) -> WITransportResolvedAddress {
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
    ) -> WITransportResolvedAddress {
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
    ) -> WITransportResolvedAddress {
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
        resolver: (String) -> WITransportResolvedAddress
    ) -> WITransportResolvedAddress {
        var outsideTextResult: WITransportResolvedAddress?
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
        _ resolvedSymbols: WITransportNativeInspectorResolvedSymbols,
        image: MachOImage,
        text: SegmentCommand64,
        webCoreImage: MachOImage?,
        webCoreText: SegmentCommand64?,
        javaScriptCoreImage: MachOImage,
        javaScriptCoreText: SegmentCommand64,
        symbols: WITransportNativeInspectorSymbolNames
    ) -> WITransportResolvedConnectDisconnectFallbackResult {
        let connectMissing: Bool
        if case .missing = resolvedSymbols.connectFrontend {
            connectMissing = true
        } else {
            connectMissing = false
        }

        let disconnectMissing: Bool
        if case .missing = resolvedSymbols.disconnectFrontend {
            disconnectMissing = true
        } else {
            disconnectMissing = false
        }

        guard connectMissing || disconnectMissing else {
            return .init(
                symbols: resolvedSymbols,
                usedFallback: false
            )
        }

        let webCoreConnectTargets = unsafe resolvedCallTargetAddresses(
            symbolNames: symbols.inspectorControllerConnectTargets,
            in: webCoreImage,
            text: webCoreText
        )
        let webCoreDisconnectTargets = unsafe resolvedCallTargetAddresses(
            symbolNames: symbols.inspectorControllerDisconnectTargets,
            in: webCoreImage,
            text: webCoreText
        )
        let webKitBoundConnectTargets = unsafe boundCallTargetAddresses(
            symbolNames: symbols.inspectorControllerConnectTargets,
            in: image
        )
        let webKitBoundDisconnectTargets = unsafe boundCallTargetAddresses(
            symbolNames: symbols.inspectorControllerDisconnectTargets,
            in: image
        )

        let connectTargetAddresses = webCoreConnectTargets.union(webKitBoundConnectTargets)
        let disconnectTargetAddresses = webCoreDisconnectTargets.union(webKitBoundDisconnectTargets)

        guard let functionStarts = image.functionStarts else {
            #if DEBUG
            NSLog(
                "[WebInspectorTransport] native inspector text scan unavailable functionStarts=nil webCoreConnectTargets=%lu webCoreDisconnectTargets=%lu webKitBoundConnectTargets=%lu webKitBoundDisconnectTargets=%lu",
                webCoreConnectTargets.count,
                webCoreDisconnectTargets.count,
                webKitBoundConnectTargets.count,
                webKitBoundDisconnectTargets.count
            )
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
        NSLog(
            "[WebInspectorTransport] native inspector text scan webCoreConnectTargets=%lu webCoreDisconnectTargets=%lu webKitBoundConnectTargets=%lu webKitBoundDisconnectTargets=%lu connectTargets=%lu disconnectTargets=%lu resolvedConnect=%@ resolvedDisconnect=%@",
            webCoreConnectTargets.count,
            webCoreDisconnectTargets.count,
            webKitBoundConnectTargets.count,
            webKitBoundDisconnectTargets.count,
            connectTargetAddresses.count,
            disconnectTargetAddresses.count,
            debugResolvedAddress(resolvedConnect),
            debugResolvedAddress(resolvedDisconnect)
        )
        #endif

        let resolvedWrapperSymbols = WITransportNativeInspectorResolvedSymbols(
            connectFrontend: connectMissing ? resolvedConnect : resolvedSymbols.connectFrontend,
            disconnectFrontend: disconnectMissing ? resolvedDisconnect : resolvedSymbols.disconnectFrontend,
            stringFromUTF8: resolvedSymbols.stringFromUTF8,
            stringImplToNSString: resolvedSymbols.stringImplToNSString,
            destroyStringImpl: resolvedSymbols.destroyStringImpl,
            backendDispatcherDispatch: resolvedSymbols.backendDispatcherDispatch
        )
        let usedWrapperFallback = (connectMissing && isFound(resolvedConnect)) || (disconnectMissing && isFound(resolvedDisconnect))

        return .init(
            symbols: resolvedWrapperSymbols,
            usedFallback: usedWrapperFallback
        )
    }

    private static func resolvedFunctionAddresses(
        from resolvedSymbols: WITransportNativeInspectorResolvedSymbols
    ) -> WITransportResolvedFunctionAddresses? {
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

        return WITransportResolvedFunctionAddresses(
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
        _ = javaScriptCoreHeaderAddress
        return [webKitHeaderAddress]
    }

    private static func successResolution(
        _ functionAddresses: WITransportResolvedFunctionAddresses,
        phase: WITransportNativeInspectorResolutionPhase?,
        source: String?,
        usedConnectDisconnectFallback: Bool
    ) -> WITransportNativeInspectorSymbolResolution {
        _ = functionAddresses
        if let phase {
            NSLog(successLogFormat, backendKind.rawValue, phase.message)
        }
        return WITransportNativeInspectorSymbolResolution(
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
        _ resolvedSymbols: WITransportNativeInspectorResolvedSymbols,
        phase: WITransportNativeInspectorResolutionPhase?,
        source: String?,
        webKitHeaderAddress: UInt,
        javaScriptCoreHeaderAddress: UInt,
        usedConnectDisconnectFallback: Bool
    ) -> WITransportNativeInspectorSymbolResolution? {
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
        let expectedHeadersBySymbol: [(WITransportResolvedAddress, [UInt])] = [
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
        _ resolvedSymbols: WITransportNativeInspectorResolvedSymbols,
        phase: WITransportNativeInspectorResolutionPhase?,
        source: String?,
        webKitHeaderAddress: UInt,
        javaScriptCoreHeaderAddress: UInt,
        usedConnectDisconnectFallback: Bool
    ) -> WITransportNativeInspectorSymbolResolution? {
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
        let expectedHeadersBySymbol: [(WITransportResolvedAddress, [UInt])] = [
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

    fileprivate static func loadedWebKitImage(pathSuffixes: [String]) -> WITransportLoadedWebKitImage? {
        let imageCount = _dyld_image_count()
        for imageIndex in 0 ..< imageCount {
            guard let imageName = unsafe _dyld_get_image_name(imageIndex) else {
                continue
            }

            let path = unsafe String(cString: imageName)
            guard imagePathMatches(path, suffixes: pathSuffixes),
                  let header = unsafe _dyld_get_image_header(imageIndex) else {
                continue
            }

            return WITransportLoadedWebKitImage(
                headerAddress: UInt(bitPattern: header)
            )
        }

        return nil
    }

    private static func imagePathMatches(_ path: String?, suffixes: [String]) -> Bool {
        guard let path else {
            return false
        }
        return suffixes.contains { path.hasSuffix($0) }
    }

    private static func textSegment(in image: MachOImage) -> SegmentCommand64? {
        image.segments64.first(where: { $0.segmentName == textSegmentName })
    }

    private static func sharedCacheSymbolFileURLs() -> [URL] {
        sharedCacheSymbolFileURLs(activeSharedCachePath: unsafe WITransportDyldRuntime.sharedCacheFilePath())
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
                    entry.hasPrefix(sharedCacheFilePrefix) && entry.hasSuffix(sharedCacheFileSuffix)
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

        if activeSharedCachePath.hasSuffix(sharedCacheFileSuffix) {
            return URL(fileURLWithPath: activeSharedCachePath)
        }

        return URL(fileURLWithPath: activeSharedCachePath + sharedCacheFileSuffix)
    }

    private static func sharedCacheSortKey(for fileName: String) -> Int {
        if fileName.contains(arm64eArchitecture) {
            return 0
        }
        if fileName.contains(arm64Architecture) {
            return 1
        }
        return 2
    }

    private static func fileBackedLocalSymbols(
        mainCacheHeader: DyldCacheHeader,
        dylibOffset: UInt64
    ) throws -> WITransportFileBackedLocalSymbols {
        let symbolCacheURLs = sharedCacheSymbolFileURLs()
        guard !symbolCacheURLs.isEmpty else {
            throw WITransportLookupFailure(
                kind: .localSymbolsUnavailable,
                detail: nil
            )
        }

        var lastFailure: WITransportLookupFailure?

        for symbolCacheURL in symbolCacheURLs {
            do {
                let symbolCache = try DyldCache(
                    subcacheUrl: symbolCacheURL,
                    mainCacheHeader: mainCacheHeader
                )
                guard let localSymbolsInfo = symbolCache.localSymbolsInfo else {
                    lastFailure = WITransportLookupFailure(
                        kind: .localSymbolsUnavailable,
                        detail: nil
                    )
                    continue
                }
                guard let entry = localSymbolsInfo.entries(in: symbolCache).first(where: { UInt64($0.dylibOffset) == dylibOffset }) else {
                    lastFailure = WITransportLookupFailure(
                        kind: .localSymbolEntryMissing,
                        detail: nil
                    )
                    continue
                }
                guard let symbols = localSymbolsInfo.symbols64(in: symbolCache) else {
                    lastFailure = WITransportLookupFailure(
                        kind: .localSymbolsUnavailable,
                        detail: nil
                    )
                    continue
                }

                return WITransportFileBackedLocalSymbols(
                    symbols: symbols,
                    symbolRange: entry.nlistRange
                )
            } catch {
                lastFailure = WITransportLookupFailure(
                    kind: .localSymbolsUnavailable,
                    detail: nil
                )
            }
        }

        throw lastFailure ?? WITransportLookupFailure(
            kind: .localSymbolsUnavailable,
            detail: nil
        )
    }

    private static func resolveLoadedImageSymbol(
        named symbolName: String,
        in image: MachOImage,
        text: SegmentCommand64
    ) -> WITransportResolvedAddress {
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
    ) -> WITransportResolvedAddress {
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

        guard let address = unsafe WITransportDyldRuntime.symbolAddress(named: symbolName) else {
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
        let headerAddress = unsafe UInt(bitPattern: image.ptr)
        let dlsymDescription: String
        if let dlsymAddress {
            dlsymDescription = unsafe String(format: "0x%llx", dlsymAddress)
        } else {
            dlsymDescription = "nil"
        }
        NSLog(
            "[WebInspectorTransport] native inspector export lookup failed symbol=%@ header=0x%llx exportTrieAvailable=%@ exportTrieFound=%@ dlsym=%@ reason=%@",
            symbolName,
            UInt64(headerAddress),
            exportTrieAvailable ? "true" : "false",
            exportTrieFound ? "true" : "false",
            dlsymDescription,
            failedReason
        )
        #endif
    }

    private static func resolveSharedCacheSymbol(
        named symbolName: String,
        symbols: MachOImage.Symbols64,
        symbolRange: Range<Int>,
        textVMAddress: UInt64,
        textRange: Range<UInt64>,
        slide: UInt64
    ) -> WITransportResolvedAddress {
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
    ) -> WITransportResolvedAddress {
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
    ) -> WITransportResolvedAddress {
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
        in resolvedSymbols: WITransportNativeInspectorResolvedSymbols
    ) -> [String] {
        let symbolResults: [(String, WITransportResolvedAddress)] = [
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

    private static func isFound(_ result: WITransportResolvedAddress) -> Bool {
        if case .found = result {
            return true
        }
        return false
    }

    private static func debugResolvedAddress(_ result: WITransportResolvedAddress) -> String {
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
        guard let header = unsafe WITransportDyldRuntime.imageHeader(containingAddress: address) else {
            return false
        }
        return expectedHeaderAddresses.contains(UInt(bitPattern: header))
    }

    private static func failure(
        _ kind: WITransportNativeInspectorSymbolFailure,
        detail: String? = nil,
        phase: WITransportNativeInspectorResolutionPhase? = nil,
        source: String? = nil,
        missingFunctions: [String] = [],
        usedConnectDisconnectFallback: Bool = false
    ) -> WITransportNativeInspectorSymbolResolution {
        let reason = formattedFailureReason(
            kind: kind,
            detail: detail,
            phase: phase,
            source: source,
            missingFunctions: missingFunctions,
            usedConnectDisconnectFallback: usedConnectDisconnectFallback
        )
        NSLog(failureLogFormat, backendKind.rawValue, reason)
        return WITransportNativeInspectorSymbolResolution(
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
        kind: WITransportNativeInspectorSymbolFailure,
        detail: String?,
        phase: WITransportNativeInspectorResolutionPhase?,
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

struct WITransportAttachSymbolResolution: Sendable {
    let backendKind: WITransportBackendKind
    let connectFrontendAddress: UInt64
    let disconnectFrontendAddress: UInt64
    let stringFromUTF8Address: UInt64
    let stringImplToNSStringAddress: UInt64
    let destroyStringImplAddress: UInt64
    let backendDispatcherDispatchAddress: UInt64
    let failureReason: String?
    let failureKind: String?
    let phase: String?
    let missingFunctions: [String]
    let source: String?
    let usedConnectDisconnectFallback: Bool

    var diagnosticsSummary: String? {
        var parts = [String]()
        if let phase, !phase.isEmpty {
            parts.append("phase=\(phase)")
        }
        if let source, !source.isEmpty {
            parts.append("source=\(source)")
        }
        if let failureKind, !failureKind.isEmpty {
            parts.append("failure=\(failureKind)")
        }
        if !missingFunctions.isEmpty {
            parts.append("missing=\(missingFunctions.joined(separator: ","))")
        }
        if usedConnectDisconnectFallback {
            parts.append("fallback=text-scan")
        }
        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: " ")
    }

    var supportSnapshot: WITransportSupportSnapshot {
        if isSupported {
            .supported(
                backendKind: backendKind,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain]
            )
        } else {
            .unsupported(reason: failureReason ?? "inspector backend unavailable")
        }
    }

    var isSupported: Bool {
        connectFrontendAddress != 0
            && disconnectFrontendAddress != 0
            && stringFromUTF8Address != 0
            && stringImplToNSStringAddress != 0
            && destroyStringImplAddress != 0
            && backendDispatcherDispatchAddress != 0
            && failureReason == nil
    }
}

enum WITransportNativeInspectorSymbolResolver {
    static func currentAttachResolution() -> WITransportAttachSymbolResolution {
        makeAttachResolution(from: WITransportNativeInspectorResolver.resolveCurrentWebKitAttachSymbols())
    }

    static func resolveForTesting(
        imagePathSuffixes: [String] = WITransportNativeInspectorResolver.webKitImagePathSuffixes,
        connectSymbol: String = WITransportNativeInspectorResolver.connectFrontendSymbol,
        disconnectSymbol: String = WITransportNativeInspectorResolver.disconnectFrontendSymbol,
        alternateConnectSymbols: [String] = [],
        alternateDisconnectSymbols: [String] = [],
        stringFromUTF8Symbol: String? = nil,
        stringImplToNSStringSymbol: String? = nil,
        destroyStringImplSymbol: String? = nil,
        backendDispatcherDispatchSymbol: String? = nil
    ) -> WITransportAttachSymbolResolution {
        makeAttachResolution(
            from: WITransportNativeInspectorResolver.resolveForTesting(
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
        guard let loadedImage = WITransportNativeInspectorResolver.loadedWebKitImage(
            pathSuffixes: WITransportNativeInspectorResolver.webKitImagePathSuffixes
        ), let loadedJavaScriptCoreImage = WITransportNativeInspectorResolver.loadedWebKitImage(
            pathSuffixes: WITransportNativeInspectorResolver.javaScriptCoreImagePathSuffixes
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
        WITransportNativeInspectorResolver.resolvedAddress(
            address,
            belongsToAnyOf: expectedHeaderAddresses
        )
    }

    static func sharedCacheSymbolFileURLsForTesting(activeSharedCachePath: String?) -> [URL] {
        WITransportNativeInspectorResolver.sharedCacheSymbolFileURLs(
            activeSharedCachePath: activeSharedCachePath
        )
    }

    static func imagePathSuffixesForTesting() -> (
        webKit: [String],
        javaScriptCore: [String],
        webCore: [String]
    ) {
        (
            webKit: WITransportNativeInspectorResolver.webKitImagePathSuffixes,
            javaScriptCore: WITransportNativeInspectorResolver.javaScriptCoreImagePathSuffixes,
            webCore: WITransportNativeInspectorResolver.webCoreImagePathSuffixes
        )
    }

    static func connectSymbolsForTesting() -> [String] {
        [WITransportNativeInspectorResolver.connectFrontendSymbol]
    }

    static func disconnectSymbolsForTesting() -> [String] {
        [WITransportNativeInspectorResolver.disconnectFrontendSymbol]
    }

    @unsafe static func uniqueFunctionStartContainingCallTargetsForTesting(
        architecture: String,
        textBaseAddress: UInt64,
        textPointer: UnsafePointer<UInt8>,
        textSize: Int,
        functionStartAddresses: [UInt64],
        callTargetAddresses: Set<UInt64>
    ) -> UInt64? {
        unsafe WITransportNativeInspectorResolver.uniqueFunctionStartContainingCallTargets(
            architecture: architecture,
            textBaseAddress: textBaseAddress,
            textPointer: textPointer,
            textSize: textSize,
            functionStartAddresses: functionStartAddresses,
            callTargetAddresses: callTargetAddresses
        )
    }

    private static func makeAttachResolution(from resolution: WITransportNativeInspectorSymbolResolution) -> WITransportAttachSymbolResolution {
        WITransportAttachSymbolResolution(
            backendKind: WITransportNativeInspectorResolver.backendKind,
            connectFrontendAddress: resolution.functionAddresses.connectFrontendAddress,
            disconnectFrontendAddress: resolution.functionAddresses.disconnectFrontendAddress,
            stringFromUTF8Address: resolution.functionAddresses.stringFromUTF8Address,
            stringImplToNSStringAddress: resolution.functionAddresses.stringImplToNSStringAddress,
            destroyStringImplAddress: resolution.functionAddresses.destroyStringImplAddress,
            backendDispatcherDispatchAddress: resolution.functionAddresses.backendDispatcherDispatchAddress,
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
struct WITransportAttachSymbolResolution: Sendable {
    let backendKind: WITransportBackendKind
    let connectFrontendAddress: UInt64
    let disconnectFrontendAddress: UInt64
    let stringFromUTF8Address: UInt64
    let stringImplToNSStringAddress: UInt64
    let destroyStringImplAddress: UInt64
    let backendDispatcherDispatchAddress: UInt64
    let failureReason: String?
    let failureKind: String?
    let phase: String?
    let missingFunctions: [String]
    let source: String?
    let usedConnectDisconnectFallback: Bool

    var diagnosticsSummary: String? {
        var parts = [String]()
        if let failureKind, !failureKind.isEmpty {
            parts.append("failure=\(failureKind)")
        }
        if let source, !source.isEmpty {
            parts.append("source=\(source)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var supportSnapshot: WITransportSupportSnapshot {
        .unsupported(reason: failureReason ?? "WebInspectorTransport is only available on iOS and macOS.")
    }

    var isSupported: Bool { false }
}

enum WITransportNativeInspectorSymbolResolver {
    static func currentAttachResolution() -> WITransportAttachSymbolResolution {
        WITransportAttachSymbolResolution(
            backendKind: .unsupported,
            connectFrontendAddress: 0,
            disconnectFrontendAddress: 0,
            stringFromUTF8Address: 0,
            stringImplToNSStringAddress: 0,
            destroyStringImplAddress: 0,
            backendDispatcherDispatchAddress: 0,
            failureReason: "WebInspectorTransport is only available on iOS and macOS.",
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
    ) -> WITransportAttachSymbolResolution {
        _ = imagePathSuffixes
        _ = connectSymbol
        _ = disconnectSymbol
        _ = alternateConnectSymbols
        _ = alternateDisconnectSymbols
        _ = stringFromUTF8Symbol
        _ = stringImplToNSStringSymbol
        _ = destroyStringImplSymbol
        _ = backendDispatcherDispatchSymbol
        return currentAttachResolution()
    }
}
#endif
