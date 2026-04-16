#if os(iOS) || os(macOS)
import Darwin
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
            return WITransportNativeInspectorObfuscation.deobfuscate(["e", "availabl", "cache un", "runtime "])
        case .localSymbolsUnavailable:
            return WITransportNativeInspectorObfuscation.deobfuscate(["ailable", "kup unav", "mbol loo", "local sy"])
        case .inspectorImageMissing:
            return WITransportNativeInspectorObfuscation.deobfuscate(["ble", "unavaila", "r image ", "inspecto"])
        case .supportImageMissing:
            return WITransportNativeInspectorObfuscation.deobfuscate(["e", "availabl", "image un", "support "])
        case .localSymbolEntryMissing:
            return WITransportNativeInspectorObfuscation.deobfuscate(["ilable", "ry unava", "mbol ent", "local sy"])
        case .connectDisconnectSymbolMissing:
            return WITransportNativeInspectorObfuscation.deobfuscate(["ilable", "nt unava", "ntry poi", "attach e"])
        case .runtimeFunctionSymbolMissing:
            return WITransportNativeInspectorObfuscation.deobfuscate(["le", "navailab", "helper u", "runtime "])
        case .resolvedAddressOutsideText:
            return WITransportNativeInspectorObfuscation.deobfuscate([" invalid", " address", "resolved"])
        case .resolvedAddressImageMismatch:
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
            return WITransportNativeInspectorObfuscation.deobfuscate(["mage", "loaded-i"])
        case .sharedCache:
            return WITransportNativeInspectorObfuscation.deobfuscate(["ache", "shared-c"])
        case .sharedCacheFile:
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
    let targetAgentDidCreateFrontendAndBackendAddress: UInt64
    let frontendAttachmentStrategy: WITransportFrontendAttachmentStrategy

    static let zero = WITransportResolvedFunctionAddresses(
        connectFrontendAddress: 0,
        disconnectFrontendAddress: 0,
        stringFromUTF8Address: 0,
        stringImplToNSStringAddress: 0,
        destroyStringImplAddress: 0,
        backendDispatcherDispatchAddress: 0,
        targetAgentDidCreateFrontendAndBackendAddress: 0,
        frontendAttachmentStrategy: .controller
    )
}

private enum WITransportFrontendAttachmentStrategy: UInt8, Sendable {
    case controller = 0
    case frontendRouter = 1
}

private struct WITransportNativeInspectorSymbolResolution: Sendable {
    let functionAddresses: WITransportResolvedFunctionAddresses
    let failureReason: String?
}

private struct WITransportNativeInspectorSymbolNames {
    let connectFrontend: String
    let disconnectFrontend: String
    let stringFromUTF8: String
    let stringImplToNSString: String
    let destroyStringImpl: String
    let backendDispatcherDispatch: String
}

private struct WITransportNativeInspectorResolvedSymbols {
    let connectFrontend: WITransportResolvedAddress
    let disconnectFrontend: WITransportResolvedAddress
    let stringFromUTF8: WITransportResolvedAddress
    let stringImplToNSString: WITransportResolvedAddress
    let destroyStringImpl: WITransportResolvedAddress
    let backendDispatcherDispatch: WITransportResolvedAddress
    let targetAgentDidCreateFrontendAndBackend: WITransportResolvedAddress
}

private enum WITransportNativeInspectorResolver {
    fileprivate static let webKitImagePathSuffixes = [
        WITransportNativeInspectorObfuscation.deobfuscate(["it", "ork/WebK", "t.framew", "ks/WebKi", "Framewor", "Library/", "/System/"]),
        WITransportNativeInspectorObfuscation.deobfuscate(["ebKit", "ions/A/W", "ork/Vers", "t.framew", "ks/WebKi", "Framewor", "Library/", "/System/"]),
    ]
    fileprivate static let javaScriptCoreImagePathSuffixes = [
        WITransportNativeInspectorObfuscation.deobfuscate(["re", "ScriptCo", "ork/Java", "e.framew", "criptCor", "ks/JavaS", "Framewor", "Library/", "/System/"]),
        WITransportNativeInspectorObfuscation.deobfuscate(["tCore", "avaScrip", "ions/A/J", "ork/Vers", "e.framew", "criptCor", "ks/JavaS", "Framewor", "Library/", "/System/"]),
    ]
    private static let textSegmentName = WITransportNativeInspectorObfuscation.deobfuscate(["__TEXT"])
    private static let sharedCacheFilePrefix = WITransportNativeInspectorObfuscation.deobfuscate(["e_", "red_cach", "dyld_sha"])
    private static let sharedCacheFileSuffix = WITransportNativeInspectorObfuscation.deobfuscate([".symbols"])
    private static let arm64eArchitecture = WITransportNativeInspectorObfuscation.deobfuscate(["arm64e"])
    private static let arm64Architecture = WITransportNativeInspectorObfuscation.deobfuscate(["arm64"])
    #if os(iOS)
    fileprivate static let connectFrontendSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["nnelE", "ntendCha", "NS_15Fro", "ontendER", "onnectFr", "outer15c", "rontendR", "ector14F", "_ZN9Insp"])
    fileprivate static let disconnectFrontendSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["ChannelE", "Frontend", "dERNS_15", "tFronten", "isconnec", "outer18d", "rontendR", "ector14F", "_ZN9Insp"])
    private static let frontendAttachmentStrategy: WITransportFrontendAttachmentStrategy = .frontendRouter
    #else
    fileprivate static let connectFrontendSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["annelEbb", "ontendCh", "ctor15Fr", "RN9Inspe", "rontendE", "connectF", "roller15", "ctorCont", "ageInspe", "it26WebP", "_ZN6WebK", "_"])
    fileprivate static let disconnectFrontendSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["ChannelE", "Frontend", "pector15", "dERN9Ins", "tFronten", "isconnec", "oller18d", "torContr", "geInspec", "t26WebPa", "ZN6WebKi", "__"])
    private static let frontendAttachmentStrategy: WITransportFrontendAttachmentStrategy = .controller
    #endif
    private static let successLogFormat = WITransportNativeInspectorObfuscation.deobfuscate(["se=%@", "d=%@ pha", "d backen", " resolve", " symbols", "nspector", "native i", "nsport] ", "ectorTra", "[WebInsp"])
    private static let failureLogFormat = WITransportNativeInspectorObfuscation.deobfuscate(["%@", " reason=", "ckend=%@", "ailed ba", "lookup f", " symbol ", "nspector", "native i", "nsport] ", "ectorTra", "[WebInsp"])
    private static let stringFromUTF8Symbol = WITransportNativeInspectorObfuscation.deobfuscate(["51615EEE", "40737095", "m1844674", "panIKDuL", "St3__14s", "omUTF8EN", "tring8fr", "ZN3WTF6S", "__"])
    private static let stringImplToNSStringSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["StringEv", "plcvP8NS", "StringIm", "ZN3WTF10", "__"])
    private static let destroyStringImplSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["royEPS0_", "mpl7dest", "0StringI", "_ZN3WTF1", "_"])
    private static let backendDispatcherDispatchSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["6StringE", "ERKN3WTF", "dispatch", "patcher8", "ckendDis", "ctor17Ba", "ZN9Inspe", "__"])
    private static let targetAgentDidCreateFrontendAndBackendSymbol = WITransportNativeInspectorObfuscation.deobfuscate(["Ev", "dBackend", "ontendAn", "CreateFr", "ent27did", "TargetAg", "nspector", "ector20I", "_ZN9Insp"])

    #if os(iOS)
    fileprivate static let backendKind: WITransportBackendKind = .iOSNativeInspector
    private static let sharedCacheDirectoryCandidates = [
        WITransportNativeInspectorObfuscation.deobfuscate([".dyld", "om.apple", "Caches/c", "Library/", "/System/"]),
        WITransportNativeInspectorObfuscation.deobfuscate(["ple.dyld", "s/com.ap", "ry/Cache", "em/Libra", "/OS/Syst", "ryptexes", "System/C", "/"]),
        WITransportNativeInspectorObfuscation.deobfuscate(["ld", "apple.dy", "hes/com.", "rary/Cac", "stem/Lib", "es/OS/Sy", "/Cryptex", "/preboot", "/private"]),
    ]
    #else
    fileprivate static let backendKind: WITransportBackendKind = .macOSNativeInspector
    private static let sharedCacheDirectoryCandidates = [
        WITransportNativeInspectorObfuscation.deobfuscate(["ary/dyld", "tem/Libr", "s/OS/Sys", "Cryptexe", "Preboot/", "Volumes/", "/System/"]),
        WITransportNativeInspectorObfuscation.deobfuscate(["dyld", "Library/", "/System/"]),
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
        stringFromUTF8Symbol: String? = nil,
        stringImplToNSStringSymbol: String? = nil,
        destroyStringImplSymbol: String? = nil,
        backendDispatcherDispatchSymbol: String? = nil
    ) -> WITransportNativeInspectorSymbolResolution {
        resolve(
            imagePathSuffixes: imagePathSuffixes,
            javaScriptCorePathSuffixes: javaScriptCoreImagePathSuffixes,
            symbols: WITransportNativeInspectorSymbolNames(
                connectFrontend: connectSymbol,
                disconnectFrontend: disconnectSymbol,
                stringFromUTF8: stringFromUTF8Symbol ?? self.stringFromUTF8Symbol,
                stringImplToNSString: stringImplToNSStringSymbol ?? self.stringImplToNSStringSymbol,
                destroyStringImpl: destroyStringImplSymbol ?? self.destroyStringImplSymbol,
                backendDispatcherDispatch: backendDispatcherDispatchSymbol ?? self.backendDispatcherDispatchSymbol
            )
        )
    }

    private static func currentSymbolNames() -> WITransportNativeInspectorSymbolNames {
        WITransportNativeInspectorSymbolNames(
            connectFrontend: connectFrontendSymbol,
            disconnectFrontend: disconnectFrontendSymbol,
            stringFromUTF8: stringFromUTF8Symbol,
            stringImplToNSString: stringImplToNSStringSymbol,
            destroyStringImpl: destroyStringImplSymbol,
            backendDispatcherDispatch: backendDispatcherDispatchSymbol
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

        let image = unsafe MachOImage(ptr: loadedImage.header)
        guard image.is64Bit, let text = textSegment(in: image) else {
            return failure(.inspectorImageMissing)
        }
        let javaScriptCoreImage = unsafe MachOImage(ptr: loadedJavaScriptCoreImage.header)
        guard javaScriptCoreImage.is64Bit, let javaScriptCoreText = textSegment(in: javaScriptCoreImage) else {
            return failure(.supportImageMissing)
        }

        let loadedImageResults = WITransportNativeInspectorResolvedSymbols(
            connectFrontend: preferredResolvedAddress(
                resolveLoadedImageSymbol(
                    named: symbols.connectFrontend,
                    in: preferredConnectDisconnectLoadedImage(
                        webKitImage: image,
                        javaScriptCoreImage: javaScriptCoreImage
                    ),
                    text: preferredConnectDisconnectTextSegment(
                        webKitText: text,
                        javaScriptCoreText: javaScriptCoreText
                    )
                ),
                fallback: resolveLoadedImageSymbol(
                    named: symbols.connectFrontend,
                    in: fallbackConnectDisconnectLoadedImage(
                        webKitImage: image,
                        javaScriptCoreImage: javaScriptCoreImage
                    ),
                    text: fallbackConnectDisconnectTextSegment(
                        webKitText: text,
                        javaScriptCoreText: javaScriptCoreText
                    )
                )
            ),
            disconnectFrontend: preferredResolvedAddress(
                resolveLoadedImageSymbol(
                    named: symbols.disconnectFrontend,
                    in: preferredConnectDisconnectLoadedImage(
                        webKitImage: image,
                        javaScriptCoreImage: javaScriptCoreImage
                    ),
                    text: preferredConnectDisconnectTextSegment(
                        webKitText: text,
                        javaScriptCoreText: javaScriptCoreText
                    )
                ),
                fallback: resolveLoadedImageSymbol(
                    named: symbols.disconnectFrontend,
                    in: fallbackConnectDisconnectLoadedImage(
                        webKitImage: image,
                        javaScriptCoreImage: javaScriptCoreImage
                    ),
                    text: fallbackConnectDisconnectTextSegment(
                        webKitText: text,
                        javaScriptCoreText: javaScriptCoreText
                    )
                )
            ),
            stringFromUTF8: resolveLoadedImageSymbol(named: symbols.stringFromUTF8, in: javaScriptCoreImage, text: javaScriptCoreText),
            stringImplToNSString: resolveLoadedImageSymbol(named: symbols.stringImplToNSString, in: javaScriptCoreImage, text: javaScriptCoreText),
            destroyStringImpl: resolveLoadedImageSymbol(named: symbols.destroyStringImpl, in: javaScriptCoreImage, text: javaScriptCoreText),
            backendDispatcherDispatch: preferredResolvedAddress(
                resolveLoadedImageSymbol(named: symbols.backendDispatcherDispatch, in: image, text: text),
                fallback: resolveLoadedImageSymbol(named: symbols.backendDispatcherDispatch, in: javaScriptCoreImage, text: javaScriptCoreText)
            ),
            targetAgentDidCreateFrontendAndBackend: resolveLoadedImageSymbol(
                named: targetAgentDidCreateFrontendAndBackendSymbol,
                in: javaScriptCoreImage,
                text: javaScriptCoreText
            )
        )
        if let resolution = finalizeResolution(
            loadedImageResults,
            phase: .loadedImage,
            webKitHeaderAddress: loadedImage.headerAddress,
            javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress
        ) {
            return resolution
        }

        return resolveUsingSharedCache(
            loadedImage: loadedImage,
            imagePathSuffixes: imagePathSuffixes,
            loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
            javaScriptCorePathSuffixes: javaScriptCorePathSuffixes,
            symbols: symbols
        )
    }

    private static func resolveUsingSharedCache(
        loadedImage: WITransportLoadedWebKitImage,
        imagePathSuffixes: [String],
        loadedJavaScriptCoreImage: WITransportLoadedWebKitImage,
        javaScriptCorePathSuffixes: [String],
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
        guard webKitImage.is64Bit, let text = textSegment(in: webKitImage) else {
            return failure(.inspectorImageMissing)
        }
        guard javaScriptCoreImage.is64Bit, let javaScriptCoreText = textSegment(in: javaScriptCoreImage) else {
            return failure(.supportImageMissing)
        }
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
                        connectFrontend: preferredResolvedAddress(
                            resolveSharedCacheSymbol(
                                named: symbols.connectFrontend,
                                symbols: symbols64,
                                symbolRange: preferredConnectDisconnectSymbolRange(
                                    webKitSymbolRange: lowerBound ..< upperBound,
                                    javaScriptCoreSymbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound
                                ),
                                textVMAddress: preferredConnectDisconnectTextVMAddress(
                                    webKitTextVMAddress: UInt64(text.virtualMemoryAddress),
                                    javaScriptCoreTextVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress)
                                ),
                                textRange: preferredConnectDisconnectTextRange(
                                    webKitTextRange: textRange,
                                    javaScriptCoreTextRange: javaScriptCoreTextRange
                                ),
                                slide: UInt64(slide)
                            ),
                            fallback: resolveSharedCacheSymbol(
                                named: symbols.connectFrontend,
                                symbols: symbols64,
                                symbolRange: fallbackConnectDisconnectSymbolRange(
                                    webKitSymbolRange: lowerBound ..< upperBound,
                                    javaScriptCoreSymbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound
                                ),
                                textVMAddress: fallbackConnectDisconnectTextVMAddress(
                                    webKitTextVMAddress: UInt64(text.virtualMemoryAddress),
                                    javaScriptCoreTextVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress)
                                ),
                                textRange: fallbackConnectDisconnectTextRange(
                                    webKitTextRange: textRange,
                                    javaScriptCoreTextRange: javaScriptCoreTextRange
                                ),
                                slide: UInt64(slide)
                            )
                        ),
                        disconnectFrontend: preferredResolvedAddress(
                            resolveSharedCacheSymbol(
                                named: symbols.disconnectFrontend,
                                symbols: symbols64,
                                symbolRange: preferredConnectDisconnectSymbolRange(
                                    webKitSymbolRange: lowerBound ..< upperBound,
                                    javaScriptCoreSymbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound
                                ),
                                textVMAddress: preferredConnectDisconnectTextVMAddress(
                                    webKitTextVMAddress: UInt64(text.virtualMemoryAddress),
                                    javaScriptCoreTextVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress)
                                ),
                                textRange: preferredConnectDisconnectTextRange(
                                    webKitTextRange: textRange,
                                    javaScriptCoreTextRange: javaScriptCoreTextRange
                                ),
                                slide: UInt64(slide)
                            ),
                            fallback: resolveSharedCacheSymbol(
                                named: symbols.disconnectFrontend,
                                symbols: symbols64,
                                symbolRange: fallbackConnectDisconnectSymbolRange(
                                    webKitSymbolRange: lowerBound ..< upperBound,
                                    javaScriptCoreSymbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound
                                ),
                                textVMAddress: fallbackConnectDisconnectTextVMAddress(
                                    webKitTextVMAddress: UInt64(text.virtualMemoryAddress),
                                    javaScriptCoreTextVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress)
                                ),
                                textRange: fallbackConnectDisconnectTextRange(
                                    webKitTextRange: textRange,
                                    javaScriptCoreTextRange: javaScriptCoreTextRange
                                ),
                                slide: UInt64(slide)
                            )
                        ),
                        stringFromUTF8: resolveSharedCacheSymbol(
                            named: symbols.stringFromUTF8,
                            symbols: symbols64,
                            symbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound,
                            textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                            textRange: javaScriptCoreTextRange,
                            slide: UInt64(slide)
                        ),
                        stringImplToNSString: resolveSharedCacheSymbol(
                            named: symbols.stringImplToNSString,
                            symbols: symbols64,
                            symbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound,
                            textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                            textRange: javaScriptCoreTextRange,
                            slide: UInt64(slide)
                        ),
                        destroyStringImpl: resolveSharedCacheSymbol(
                            named: symbols.destroyStringImpl,
                            symbols: symbols64,
                            symbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound,
                            textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                            textRange: javaScriptCoreTextRange,
                            slide: UInt64(slide)
                        ),
                        backendDispatcherDispatch: preferredResolvedAddress(
                            resolveSharedCacheSymbol(
                                named: symbols.backendDispatcherDispatch,
                                symbols: symbols64,
                                symbolRange: lowerBound ..< upperBound,
                                textVMAddress: UInt64(text.virtualMemoryAddress),
                                textRange: textRange,
                                slide: UInt64(slide)
                            ),
                            fallback: resolveSharedCacheSymbol(
                                named: symbols.backendDispatcherDispatch,
                                symbols: symbols64,
                                symbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound,
                                textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                                textRange: javaScriptCoreTextRange,
                                slide: UInt64(slide)
                            )
                        ),
                        targetAgentDidCreateFrontendAndBackend: resolveSharedCacheSymbol(
                            named: targetAgentDidCreateFrontendAndBackendSymbol,
                            symbols: symbols64,
                            symbolRange: javaScriptCoreLowerBound ..< javaScriptCoreUpperBound,
                            textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                            textRange: javaScriptCoreTextRange,
                            slide: UInt64(slide)
                        )
                    )
                    lastResolvedSymbols = resolvedSymbols
                    if resolvedFunctionAddresses(from: resolvedSymbols) != nil {
                        return finalizeResolution(
                            resolvedSymbols,
                            phase: .sharedCache,
                            webKitHeaderAddress: loadedImage.headerAddress,
                            javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress
                        ) ?? failure(.runtimeFunctionSymbolMissing)
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
                connectFrontend: preferredResolvedAddress(
                    resolveSharedCacheSymbol(
                        named: symbols.connectFrontend,
                        symbols: preferredConnectDisconnectFileBackedSymbols(
                            webKitSymbols: fileBackedSymbols.symbols,
                            javaScriptCoreSymbols: javaScriptCoreFileBackedSymbols.symbols
                        ),
                        symbolRange: preferredConnectDisconnectFileBackedSymbolRange(
                            webKitSymbolRange: fileBackedSymbols.symbolRange,
                            javaScriptCoreSymbolRange: javaScriptCoreFileBackedSymbols.symbolRange
                        ),
                        textVMAddress: preferredConnectDisconnectTextVMAddress(
                            webKitTextVMAddress: UInt64(text.virtualMemoryAddress),
                            javaScriptCoreTextVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress)
                        ),
                        textRange: preferredConnectDisconnectTextRange(
                            webKitTextRange: textRange,
                            javaScriptCoreTextRange: javaScriptCoreTextRange
                        ),
                        slide: UInt64(slide)
                    ),
                    fallback: resolveSharedCacheSymbol(
                        named: symbols.connectFrontend,
                        symbols: fallbackConnectDisconnectFileBackedSymbols(
                            webKitSymbols: fileBackedSymbols.symbols,
                            javaScriptCoreSymbols: javaScriptCoreFileBackedSymbols.symbols
                        ),
                        symbolRange: fallbackConnectDisconnectFileBackedSymbolRange(
                            webKitSymbolRange: fileBackedSymbols.symbolRange,
                            javaScriptCoreSymbolRange: javaScriptCoreFileBackedSymbols.symbolRange
                        ),
                        textVMAddress: fallbackConnectDisconnectTextVMAddress(
                            webKitTextVMAddress: UInt64(text.virtualMemoryAddress),
                            javaScriptCoreTextVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress)
                        ),
                        textRange: fallbackConnectDisconnectTextRange(
                            webKitTextRange: textRange,
                            javaScriptCoreTextRange: javaScriptCoreTextRange
                        ),
                        slide: UInt64(slide)
                    )
                ),
                disconnectFrontend: preferredResolvedAddress(
                    resolveSharedCacheSymbol(
                        named: symbols.disconnectFrontend,
                        symbols: preferredConnectDisconnectFileBackedSymbols(
                            webKitSymbols: fileBackedSymbols.symbols,
                            javaScriptCoreSymbols: javaScriptCoreFileBackedSymbols.symbols
                        ),
                        symbolRange: preferredConnectDisconnectFileBackedSymbolRange(
                            webKitSymbolRange: fileBackedSymbols.symbolRange,
                            javaScriptCoreSymbolRange: javaScriptCoreFileBackedSymbols.symbolRange
                        ),
                        textVMAddress: preferredConnectDisconnectTextVMAddress(
                            webKitTextVMAddress: UInt64(text.virtualMemoryAddress),
                            javaScriptCoreTextVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress)
                        ),
                        textRange: preferredConnectDisconnectTextRange(
                            webKitTextRange: textRange,
                            javaScriptCoreTextRange: javaScriptCoreTextRange
                        ),
                        slide: UInt64(slide)
                    ),
                    fallback: resolveSharedCacheSymbol(
                        named: symbols.disconnectFrontend,
                        symbols: fallbackConnectDisconnectFileBackedSymbols(
                            webKitSymbols: fileBackedSymbols.symbols,
                            javaScriptCoreSymbols: javaScriptCoreFileBackedSymbols.symbols
                        ),
                        symbolRange: fallbackConnectDisconnectFileBackedSymbolRange(
                            webKitSymbolRange: fileBackedSymbols.symbolRange,
                            javaScriptCoreSymbolRange: javaScriptCoreFileBackedSymbols.symbolRange
                        ),
                        textVMAddress: fallbackConnectDisconnectTextVMAddress(
                            webKitTextVMAddress: UInt64(text.virtualMemoryAddress),
                            javaScriptCoreTextVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress)
                        ),
                        textRange: fallbackConnectDisconnectTextRange(
                            webKitTextRange: textRange,
                            javaScriptCoreTextRange: javaScriptCoreTextRange
                        ),
                        slide: UInt64(slide)
                    )
                ),
                stringFromUTF8: resolveSharedCacheSymbol(
                    named: symbols.stringFromUTF8,
                    symbols: javaScriptCoreFileBackedSymbols.symbols,
                    symbolRange: javaScriptCoreFileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                    textRange: javaScriptCoreTextRange,
                    slide: UInt64(slide)
                ),
                stringImplToNSString: resolveSharedCacheSymbol(
                    named: symbols.stringImplToNSString,
                    symbols: javaScriptCoreFileBackedSymbols.symbols,
                    symbolRange: javaScriptCoreFileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                    textRange: javaScriptCoreTextRange,
                    slide: UInt64(slide)
                ),
                destroyStringImpl: resolveSharedCacheSymbol(
                    named: symbols.destroyStringImpl,
                    symbols: javaScriptCoreFileBackedSymbols.symbols,
                    symbolRange: javaScriptCoreFileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                    textRange: javaScriptCoreTextRange,
                    slide: UInt64(slide)
                ),
                backendDispatcherDispatch: preferredResolvedAddress(
                    resolveSharedCacheSymbol(
                        named: symbols.backendDispatcherDispatch,
                        symbols: fileBackedSymbols.symbols,
                        symbolRange: fileBackedSymbols.symbolRange,
                        textVMAddress: UInt64(text.virtualMemoryAddress),
                        textRange: textRange,
                        slide: UInt64(slide)
                    ),
                    fallback: resolveSharedCacheSymbol(
                        named: symbols.backendDispatcherDispatch,
                        symbols: javaScriptCoreFileBackedSymbols.symbols,
                        symbolRange: javaScriptCoreFileBackedSymbols.symbolRange,
                        textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                        textRange: javaScriptCoreTextRange,
                        slide: UInt64(slide)
                    )
                ),
                targetAgentDidCreateFrontendAndBackend: resolveSharedCacheSymbol(
                    named: targetAgentDidCreateFrontendAndBackendSymbol,
                    symbols: javaScriptCoreFileBackedSymbols.symbols,
                    symbolRange: javaScriptCoreFileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(javaScriptCoreText.virtualMemoryAddress),
                    textRange: javaScriptCoreTextRange,
                    slide: UInt64(slide)
                )
            )
            lastResolvedSymbols = resolvedSymbols
            if resolvedFunctionAddresses(from: resolvedSymbols) != nil {
                return finalizeResolution(
                    resolvedSymbols,
                    phase: .sharedCacheFile,
                    webKitHeaderAddress: loadedImage.headerAddress,
                    javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress
                ) ?? failure(.runtimeFunctionSymbolMissing)
            }
        } catch let lookupFailure as WITransportLookupFailure {
            if let lastResolvedSymbols {
                return finalizeResolution(
                    lastResolvedSymbols,
                    phase: nil,
                    webKitHeaderAddress: loadedImage.headerAddress,
                    javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress
                )
                    ?? failure(lookupFailure.kind, detail: lookupFailure.detail)
            }
            return failure(lookupFailure.kind, detail: lookupFailure.detail)
        } catch {
            if let lastResolvedSymbols {
                return finalizeResolution(
                    lastResolvedSymbols,
                    phase: nil,
                    webKitHeaderAddress: loadedImage.headerAddress,
                    javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress
                )
                    ?? failure(.localSymbolsUnavailable)
            }
            return failure(.localSymbolsUnavailable)
        }

        if let lastResolvedSymbols {
            return finalizeResolution(
                lastResolvedSymbols,
                phase: nil,
                webKitHeaderAddress: loadedImage.headerAddress,
                javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress
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

    private static func preferredConnectDisconnectLoadedImage(
        webKitImage: MachOImage,
        javaScriptCoreImage: MachOImage
    ) -> MachOImage {
        switch frontendAttachmentStrategy {
        case .controller:
            return webKitImage
        case .frontendRouter:
            return javaScriptCoreImage
        }
    }

    private static func fallbackConnectDisconnectLoadedImage(
        webKitImage: MachOImage,
        javaScriptCoreImage: MachOImage
    ) -> MachOImage {
        switch frontendAttachmentStrategy {
        case .controller:
            return javaScriptCoreImage
        case .frontendRouter:
            return webKitImage
        }
    }

    private static func preferredConnectDisconnectTextSegment(
        webKitText: SegmentCommand64,
        javaScriptCoreText: SegmentCommand64
    ) -> SegmentCommand64 {
        switch frontendAttachmentStrategy {
        case .controller:
            return webKitText
        case .frontendRouter:
            return javaScriptCoreText
        }
    }

    private static func fallbackConnectDisconnectTextSegment(
        webKitText: SegmentCommand64,
        javaScriptCoreText: SegmentCommand64
    ) -> SegmentCommand64 {
        switch frontendAttachmentStrategy {
        case .controller:
            return javaScriptCoreText
        case .frontendRouter:
            return webKitText
        }
    }

    private static func preferredConnectDisconnectSymbolRange(
        webKitSymbolRange: Range<Int>,
        javaScriptCoreSymbolRange: Range<Int>
    ) -> Range<Int> {
        switch frontendAttachmentStrategy {
        case .controller:
            return webKitSymbolRange
        case .frontendRouter:
            return javaScriptCoreSymbolRange
        }
    }

    private static func fallbackConnectDisconnectSymbolRange(
        webKitSymbolRange: Range<Int>,
        javaScriptCoreSymbolRange: Range<Int>
    ) -> Range<Int> {
        switch frontendAttachmentStrategy {
        case .controller:
            return javaScriptCoreSymbolRange
        case .frontendRouter:
            return webKitSymbolRange
        }
    }

    private static func preferredConnectDisconnectTextVMAddress(
        webKitTextVMAddress: UInt64,
        javaScriptCoreTextVMAddress: UInt64
    ) -> UInt64 {
        switch frontendAttachmentStrategy {
        case .controller:
            return webKitTextVMAddress
        case .frontendRouter:
            return javaScriptCoreTextVMAddress
        }
    }

    private static func fallbackConnectDisconnectTextVMAddress(
        webKitTextVMAddress: UInt64,
        javaScriptCoreTextVMAddress: UInt64
    ) -> UInt64 {
        switch frontendAttachmentStrategy {
        case .controller:
            return javaScriptCoreTextVMAddress
        case .frontendRouter:
            return webKitTextVMAddress
        }
    }

    private static func preferredConnectDisconnectTextRange(
        webKitTextRange: Range<UInt64>,
        javaScriptCoreTextRange: Range<UInt64>
    ) -> Range<UInt64> {
        switch frontendAttachmentStrategy {
        case .controller:
            return webKitTextRange
        case .frontendRouter:
            return javaScriptCoreTextRange
        }
    }

    private static func fallbackConnectDisconnectTextRange(
        webKitTextRange: Range<UInt64>,
        javaScriptCoreTextRange: Range<UInt64>
    ) -> Range<UInt64> {
        switch frontendAttachmentStrategy {
        case .controller:
            return javaScriptCoreTextRange
        case .frontendRouter:
            return webKitTextRange
        }
    }

    private static func preferredConnectDisconnectFileBackedSymbols(
        webKitSymbols: MachOFile.Symbols64,
        javaScriptCoreSymbols: MachOFile.Symbols64
    ) -> MachOFile.Symbols64 {
        switch frontendAttachmentStrategy {
        case .controller:
            return webKitSymbols
        case .frontendRouter:
            return javaScriptCoreSymbols
        }
    }

    private static func fallbackConnectDisconnectFileBackedSymbols(
        webKitSymbols: MachOFile.Symbols64,
        javaScriptCoreSymbols: MachOFile.Symbols64
    ) -> MachOFile.Symbols64 {
        switch frontendAttachmentStrategy {
        case .controller:
            return javaScriptCoreSymbols
        case .frontendRouter:
            return webKitSymbols
        }
    }

    private static func preferredConnectDisconnectFileBackedSymbolRange(
        webKitSymbolRange: Range<Int>,
        javaScriptCoreSymbolRange: Range<Int>
    ) -> Range<Int> {
        preferredConnectDisconnectSymbolRange(
            webKitSymbolRange: webKitSymbolRange,
            javaScriptCoreSymbolRange: javaScriptCoreSymbolRange
        )
    }

    private static func fallbackConnectDisconnectFileBackedSymbolRange(
        webKitSymbolRange: Range<Int>,
        javaScriptCoreSymbolRange: Range<Int>
    ) -> Range<Int> {
        fallbackConnectDisconnectSymbolRange(
            webKitSymbolRange: webKitSymbolRange,
            javaScriptCoreSymbolRange: javaScriptCoreSymbolRange
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

        let targetAgentDidCreateFrontendAndBackendAddress: UInt64
        switch frontendAttachmentStrategy {
        case .controller:
            targetAgentDidCreateFrontendAndBackendAddress = 0
        case .frontendRouter:
            guard case let .found(address) = resolvedSymbols.targetAgentDidCreateFrontendAndBackend else {
                return nil
            }
            targetAgentDidCreateFrontendAndBackendAddress = address
        }

        return WITransportResolvedFunctionAddresses(
            connectFrontendAddress: connectAddress,
            disconnectFrontendAddress: disconnectAddress,
            stringFromUTF8Address: stringFromUTF8Address,
            stringImplToNSStringAddress: stringImplToNSStringAddress,
            destroyStringImplAddress: destroyStringImplAddress,
            backendDispatcherDispatchAddress: backendDispatcherDispatchAddress,
            targetAgentDidCreateFrontendAndBackendAddress: targetAgentDidCreateFrontendAndBackendAddress,
            frontendAttachmentStrategy: frontendAttachmentStrategy
        )
    }

    private static func successResolution(
        _ functionAddresses: WITransportResolvedFunctionAddresses,
        phase: WITransportNativeInspectorResolutionPhase?
    ) -> WITransportNativeInspectorSymbolResolution {
        _ = functionAddresses
        if let phase {
            NSLog(successLogFormat, backendKind.rawValue, phase.message)
        }
        return WITransportNativeInspectorSymbolResolution(
            functionAddresses: functionAddresses,
            failureReason: nil
        )
    }

    private static func finalizeResolution(
        _ resolvedSymbols: WITransportNativeInspectorResolvedSymbols,
        phase: WITransportNativeInspectorResolutionPhase?,
        webKitHeaderAddress: UInt,
        javaScriptCoreHeaderAddress: UInt
    ) -> WITransportNativeInspectorSymbolResolution? {
        let requiredRuntimeResults: [WITransportResolvedAddress]
        let expectedHeadersByRuntimeSymbol: [(WITransportResolvedAddress, [UInt])]
        switch frontendAttachmentStrategy {
        case .controller:
            requiredRuntimeResults = [
                resolvedSymbols.stringFromUTF8,
                resolvedSymbols.stringImplToNSString,
                resolvedSymbols.destroyStringImpl,
                resolvedSymbols.backendDispatcherDispatch,
            ]
            expectedHeadersByRuntimeSymbol = [
                (resolvedSymbols.stringFromUTF8, [javaScriptCoreHeaderAddress]),
                (resolvedSymbols.stringImplToNSString, [javaScriptCoreHeaderAddress]),
                (resolvedSymbols.destroyStringImpl, [javaScriptCoreHeaderAddress]),
                (resolvedSymbols.backendDispatcherDispatch, [webKitHeaderAddress, javaScriptCoreHeaderAddress]),
            ]
        case .frontendRouter:
            requiredRuntimeResults = [
                resolvedSymbols.stringFromUTF8,
                resolvedSymbols.stringImplToNSString,
                resolvedSymbols.destroyStringImpl,
                resolvedSymbols.backendDispatcherDispatch,
                resolvedSymbols.targetAgentDidCreateFrontendAndBackend,
            ]
            expectedHeadersByRuntimeSymbol = [
                (resolvedSymbols.stringFromUTF8, [javaScriptCoreHeaderAddress]),
                (resolvedSymbols.stringImplToNSString, [javaScriptCoreHeaderAddress]),
                (resolvedSymbols.destroyStringImpl, [javaScriptCoreHeaderAddress]),
                (resolvedSymbols.backendDispatcherDispatch, [webKitHeaderAddress, javaScriptCoreHeaderAddress]),
                (resolvedSymbols.targetAgentDidCreateFrontendAndBackend, [javaScriptCoreHeaderAddress]),
            ]
        }

        let allResults = [
            resolvedSymbols.connectFrontend,
            resolvedSymbols.disconnectFrontend,
        ] + requiredRuntimeResults

        for result in allResults {
            if case .outsideText = result {
                return failure(.resolvedAddressOutsideText)
            }
        }

        let connectDisconnectExpectedHeaders: [UInt]
        switch frontendAttachmentStrategy {
        case .controller:
            connectDisconnectExpectedHeaders = [webKitHeaderAddress]
        case .frontendRouter:
            connectDisconnectExpectedHeaders = [javaScriptCoreHeaderAddress]
        }

        let expectedHeadersBySymbol: [(WITransportResolvedAddress, [UInt])] = [
            (resolvedSymbols.connectFrontend, connectDisconnectExpectedHeaders),
            (resolvedSymbols.disconnectFrontend, connectDisconnectExpectedHeaders),
        ] + expectedHeadersByRuntimeSymbol
        for (result, expectedHeaders) in expectedHeadersBySymbol {
            guard case let .found(address) = result else {
                continue
            }
            guard resolvedAddress(address, belongsToAnyOf: expectedHeaders) else {
                return failure(.resolvedAddressImageMismatch)
            }
        }

        let missingConnectDisconnectCount = [
            resolvedSymbols.connectFrontend,
            resolvedSymbols.disconnectFrontend,
        ].reduce(into: 0) { count, result in
            if case .missing = result {
                count += 1
            }
        }
        if missingConnectDisconnectCount > 0 {
            return failure(.connectDisconnectSymbolMissing)
        }

        let missingRuntimeFunctionCount = requiredRuntimeResults.reduce(into: 0) { count, result in
            if case .missing = result {
                count += 1
            }
        }
        if missingRuntimeFunctionCount > 0 {
            return failure(.runtimeFunctionSymbolMissing)
        }

        guard let functionAddresses = resolvedFunctionAddresses(from: resolvedSymbols) else {
            return failure(.runtimeFunctionSymbolMissing)
        }
        return successResolution(functionAddresses, phase: phase)
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
            return resolveDynamicSymbol(named: symbolName, in: image, text: text)
        }
        guard symbol.offset >= 0 else {
            return resolveDynamicSymbol(named: symbolName, in: image, text: text)
        }

        let offset = UInt64(symbol.offset)
        let address = unsafe UInt64(UInt(bitPattern: image.ptr)) + offset
        guard offset < UInt64(text.virtualMemorySize) else {
            return .outsideText(address)
        }

        return .found(address)
    }

    private static func resolveDynamicSymbol(
        named symbolName: String,
        in image: MachOImage,
        text: SegmentCommand64
    ) -> WITransportResolvedAddress {
        guard let symbolPointer = unsafe symbolName.withCString({ rawName in
            unsafe dlsym(UnsafeMutableRawPointer(bitPattern: -2), rawName)
        }) else {
            return .missing
        }

        let address = UInt64(UInt(bitPattern: symbolPointer))
        let expectedHeaderAddress = unsafe UInt(bitPattern: image.ptr)
        guard resolvedAddress(address, belongsToAnyOf: [expectedHeaderAddress]) else {
            return .missing
        }

        let textStart = UInt64(expectedHeaderAddress)
        let textRange = textStart ..< textStart + UInt64(text.virtualMemorySize)
        guard textRange.contains(address) else {
            return .outsideText(address)
        }

        return .found(address)
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
        detail: String? = nil
    ) -> WITransportNativeInspectorSymbolResolution {
        let reason: String
        if let detail, !detail.isEmpty {
            reason = "\(kind.message): \(detail)"
        } else {
            reason = kind.message
        }
        NSLog(failureLogFormat, backendKind.rawValue, reason)
        return WITransportNativeInspectorSymbolResolution(
            functionAddresses: .zero,
            failureReason: reason
        )
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
    let targetAgentDidCreateFrontendAndBackendAddress: UInt64
    let frontendAttachmentStrategy: UInt8
    let failureReason: String?

    var supportSnapshot: WITransportSupportSnapshot {
        if isSupported {
            .supported(
                backendKind: backendKind,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .consoleDomain, .networkBootstrapSnapshot]
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

    private static func makeAttachResolution(from resolution: WITransportNativeInspectorSymbolResolution) -> WITransportAttachSymbolResolution {
        WITransportAttachSymbolResolution(
            backendKind: WITransportNativeInspectorResolver.backendKind,
            connectFrontendAddress: resolution.functionAddresses.connectFrontendAddress,
            disconnectFrontendAddress: resolution.functionAddresses.disconnectFrontendAddress,
            stringFromUTF8Address: resolution.functionAddresses.stringFromUTF8Address,
            stringImplToNSStringAddress: resolution.functionAddresses.stringImplToNSStringAddress,
            destroyStringImplAddress: resolution.functionAddresses.destroyStringImplAddress,
            backendDispatcherDispatchAddress: resolution.functionAddresses.backendDispatcherDispatchAddress,
            targetAgentDidCreateFrontendAndBackendAddress: resolution.functionAddresses.targetAgentDidCreateFrontendAndBackendAddress,
            frontendAttachmentStrategy: resolution.functionAddresses.frontendAttachmentStrategy.rawValue,
            failureReason: resolution.failureReason
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
    let targetAgentDidCreateFrontendAndBackendAddress: UInt64
    let frontendAttachmentStrategy: UInt8
    let failureReason: String?

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
            targetAgentDidCreateFrontendAndBackendAddress: 0,
            frontendAttachmentStrategy: WITransportFrontendAttachmentStrategy.controller.rawValue,
            failureReason: "WebInspectorTransport is only available on iOS and macOS."
        )
    }

    static func resolveForTesting(
        imagePathSuffixes: [String] = [],
        connectSymbol: String = "",
        disconnectSymbol: String = "",
        stringFromUTF8Symbol: String? = nil,
        stringImplToNSStringSymbol: String? = nil,
        destroyStringImplSymbol: String? = nil,
        backendDispatcherDispatchSymbol: String? = nil
    ) -> WITransportAttachSymbolResolution {
        _ = imagePathSuffixes
        _ = connectSymbol
        _ = disconnectSymbol
        _ = stringFromUTF8Symbol
        _ = stringImplToNSStringSymbol
        _ = destroyStringImplSymbol
        _ = backendDispatcherDispatchSymbol
        return currentAttachResolution()
    }
}
#endif
