#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

private enum WITransportNativeInspectorSymbolFailure: String {
    case sharedCacheUnavailable = "shared cache unavailable"
    case localSymbolsUnavailable = "local symbols unavailable"
    case webKitImageMissing = "WebKit image missing"
    case javaScriptCoreImageMissing = "JavaScriptCore image missing"
    case webKitLocalSymbolEntryMissing = "WebKit local symbol entry missing"
    case connectDisconnectSymbolMissing = "connect/disconnect symbol missing"
    case runtimeFunctionSymbolMissing = "runtime function symbol missing"
    case resolvedAddressOutsideWebKitText = "resolved address outside WebKit text"
    case resolvedAddressImageMismatch = "resolved address outside expected image"
}

private struct WITransportLoadedWebKitImage {
    let path: String
    let headerAddress: UInt

    var header: UnsafePointer<mach_header> {
        unsafe UnsafePointer<mach_header>(bitPattern: headerAddress)!
    }
}

private struct WITransportFileBackedLocalSymbols {
    let cachePath: String
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
}

private enum WITransportNativeInspectorResolver {
    private static let webKitImagePathSuffixes = [
        "/System/Library/Frameworks/WebKit.framework/WebKit",
        "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit",
    ]
    private static let javaScriptCoreImagePathSuffixes = [
        "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
        "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore",
    ]
    private static let textSegmentName = "__TEXT"
    private static let sharedCacheFilePrefix = "dyld_shared_cache_"
    private static let connectFrontendSymbol = "__ZN6WebKit26WebPageInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb"
    private static let disconnectFrontendSymbol = "__ZN6WebKit26WebPageInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE"
    private static let symbolObfuscationKey: UInt8 = 0x5A
    private static let stringFromUTF8Bytes: [UInt8] = [
        0x05, 0x05, 0x00, 0x14, 0x69, 0x0D, 0x0E, 0x1C, 0x6C, 0x09, 0x2E, 0x28,
        0x33, 0x34, 0x3D, 0x62, 0x3C, 0x28, 0x35, 0x37, 0x0F, 0x0E, 0x1C, 0x62,
        0x1F, 0x14, 0x09, 0x2E, 0x69, 0x05, 0x05, 0x6B, 0x6E, 0x29, 0x2A, 0x3B,
        0x34, 0x13, 0x11, 0x1E, 0x2F, 0x16, 0x37, 0x6B, 0x62, 0x6E, 0x6E, 0x6C,
        0x6D, 0x6E, 0x6E, 0x6A, 0x6D, 0x69, 0x6D, 0x6A, 0x63, 0x6F, 0x6F, 0x6B,
        0x6C, 0x6B, 0x6F, 0x1F, 0x1F, 0x1F,
    ]
    private static let stringImplToNSStringBytes: [UInt8] = [
        0x05, 0x05, 0x00, 0x14, 0x69, 0x0D, 0x0E, 0x1C, 0x6B, 0x6A, 0x09, 0x2E,
        0x28, 0x33, 0x34, 0x3D, 0x13, 0x37, 0x2A, 0x36, 0x39, 0x2C, 0x0A, 0x62,
        0x14, 0x09, 0x09, 0x2E, 0x28, 0x33, 0x34, 0x3D, 0x1F, 0x2C,
    ]
    private static let destroyStringImplBytes: [UInt8] = [
        0x05, 0x05, 0x00, 0x14, 0x69, 0x0D, 0x0E, 0x1C, 0x6B, 0x6A, 0x09, 0x2E,
        0x28, 0x33, 0x34, 0x3D, 0x13, 0x37, 0x2A, 0x36, 0x6D, 0x3E, 0x3F, 0x29,
        0x2E, 0x28, 0x35, 0x23, 0x1F, 0x0A, 0x09, 0x6A, 0x05,
    ]
    private static let backendDispatcherDispatchBytes: [UInt8] = [
        0x05, 0x05, 0x00, 0x14, 0x63, 0x13, 0x34, 0x29, 0x2A, 0x3F, 0x39, 0x2E,
        0x35, 0x28, 0x6B, 0x6D, 0x18, 0x3B, 0x39, 0x31, 0x3F, 0x34, 0x3E, 0x1E,
        0x33, 0x29, 0x2A, 0x3B, 0x2E, 0x39, 0x32, 0x3F, 0x28, 0x62, 0x3E, 0x33,
        0x29, 0x2A, 0x3B, 0x2E, 0x39, 0x32, 0x1F, 0x08, 0x11, 0x14, 0x69, 0x0D,
        0x0E, 0x1C, 0x6C, 0x09, 0x2E, 0x28, 0x33, 0x34, 0x3D, 0x1F,
    ]

    #if os(iOS)
    fileprivate static let backendKind: WITransportBackendKind = .iOSNativeInspector
    private static let sharedCacheDirectoryCandidates = [
        "/System/Library/Caches/com.apple.dyld",
        "/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
        "/private/preboot/Cryptexes/OS/System/Library/Caches/com.apple.dyld",
    ]
    #else
    fileprivate static let backendKind: WITransportBackendKind = .macOSNativeInspector
    private static let sharedCacheDirectoryCandidates = [
        "/System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld",
        "/System/Library/dyld",
        "/System/Cryptexes/OS/System/Library/dyld",
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
                stringFromUTF8: stringFromUTF8Symbol ?? decodeSymbolName(stringFromUTF8Bytes),
                stringImplToNSString: stringImplToNSStringSymbol ?? decodeSymbolName(stringImplToNSStringBytes),
                destroyStringImpl: destroyStringImplSymbol ?? decodeSymbolName(destroyStringImplBytes),
                backendDispatcherDispatch: backendDispatcherDispatchSymbol ?? decodeSymbolName(backendDispatcherDispatchBytes)
            )
        )
    }

    private static func currentSymbolNames() -> WITransportNativeInspectorSymbolNames {
        WITransportNativeInspectorSymbolNames(
            connectFrontend: connectFrontendSymbol,
            disconnectFrontend: disconnectFrontendSymbol,
            stringFromUTF8: decodeSymbolName(stringFromUTF8Bytes),
            stringImplToNSString: decodeSymbolName(stringImplToNSStringBytes),
            destroyStringImpl: decodeSymbolName(destroyStringImplBytes),
            backendDispatcherDispatch: decodeSymbolName(backendDispatcherDispatchBytes)
        )
    }

    private static func decodeSymbolName(_ encodedBytes: [UInt8]) -> String {
        String(decoding: encodedBytes.map { $0 ^ symbolObfuscationKey }, as: UTF8.self)
    }

    private static func resolve(
        imagePathSuffixes: [String],
        javaScriptCorePathSuffixes: [String],
        symbols: WITransportNativeInspectorSymbolNames
    ) -> WITransportNativeInspectorSymbolResolution {
        guard let loadedImage = loadedWebKitImage(pathSuffixes: imagePathSuffixes) else {
            return failure(.webKitImageMissing)
        }
        guard let loadedJavaScriptCoreImage = loadedWebKitImage(pathSuffixes: javaScriptCorePathSuffixes) else {
            return failure(.javaScriptCoreImageMissing)
        }

        let image = unsafe MachOImage(ptr: loadedImage.header)
        guard image.is64Bit, let text = textSegment(in: image) else {
            return failure(.webKitImageMissing, detail: "Missing a 64-bit __TEXT segment.")
        }
        let javaScriptCoreImage = unsafe MachOImage(ptr: loadedJavaScriptCoreImage.header)
        guard javaScriptCoreImage.is64Bit, let javaScriptCoreText = textSegment(in: javaScriptCoreImage) else {
            return failure(.javaScriptCoreImageMissing, detail: "Missing a 64-bit __TEXT segment.")
        }

        let loadedImageResults = WITransportNativeInspectorResolvedSymbols(
            connectFrontend: resolveLoadedImageSymbol(named: symbols.connectFrontend, in: image, text: text),
            disconnectFrontend: resolveLoadedImageSymbol(named: symbols.disconnectFrontend, in: image, text: text),
            stringFromUTF8: resolveLoadedImageSymbol(named: symbols.stringFromUTF8, in: javaScriptCoreImage, text: javaScriptCoreText),
            stringImplToNSString: resolveLoadedImageSymbol(named: symbols.stringImplToNSString, in: javaScriptCoreImage, text: javaScriptCoreText),
            destroyStringImpl: resolveLoadedImageSymbol(named: symbols.destroyStringImpl, in: javaScriptCoreImage, text: javaScriptCoreText),
            backendDispatcherDispatch: preferredResolvedAddress(
                resolveLoadedImageSymbol(named: symbols.backendDispatcherDispatch, in: image, text: text),
                fallback: resolveLoadedImageSymbol(named: symbols.backendDispatcherDispatch, in: javaScriptCoreImage, text: javaScriptCoreText)
            )
        )
        if let resolution = finalizeResolution(
            loadedImageResults,
            successLog: "resolved symbol via MachOKit loaded image symbol table",
            imagePath: loadedImage.path,
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
            return failure(.sharedCacheUnavailable, detail: error.localizedDescription)
        }

        guard let webKitImage = cache.machOImages().first(where: { imagePathMatches($0.path, suffixes: imagePathSuffixes) }) else {
            return failure(.webKitImageMissing)
        }
        guard let javaScriptCoreImage = cache.machOImages().first(where: { imagePathMatches($0.path, suffixes: javaScriptCorePathSuffixes) }) else {
            return failure(.javaScriptCoreImageMissing)
        }
        guard webKitImage.is64Bit, let text = textSegment(in: webKitImage) else {
            return failure(.webKitImageMissing, detail: "Missing a 64-bit __TEXT segment.")
        }
        guard javaScriptCoreImage.is64Bit, let javaScriptCoreText = textSegment(in: javaScriptCoreImage) else {
            return failure(.javaScriptCoreImageMissing, detail: "Missing a 64-bit __TEXT segment.")
        }
        guard let slide = cache.slide, slide >= 0 else {
            return failure(.sharedCacheUnavailable, detail: "The dyld cache slide was unavailable.")
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
                            named: symbols.connectFrontend,
                            symbols: symbols64,
                            symbolRange: lowerBound ..< upperBound,
                            textVMAddress: UInt64(text.virtualMemoryAddress),
                            textRange: textRange,
                            slide: UInt64(slide)
                        ),
                        disconnectFrontend: resolveSharedCacheSymbol(
                            named: symbols.disconnectFrontend,
                            symbols: symbols64,
                            symbolRange: lowerBound ..< upperBound,
                            textVMAddress: UInt64(text.virtualMemoryAddress),
                            textRange: textRange,
                            slide: UInt64(slide)
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
                        )
                    )
                    lastResolvedSymbols = resolvedSymbols
                    if resolvedFunctionAddresses(from: resolvedSymbols) != nil {
                        return finalizeResolution(
                            resolvedSymbols,
                            successLog: "resolved symbol via dyld local symbols",
                            imagePath: loadedImage.path,
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
                connectFrontend: resolveSharedCacheSymbol(
                    named: symbols.connectFrontend,
                    symbols: fileBackedSymbols.symbols,
                    symbolRange: fileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(text.virtualMemoryAddress),
                    textRange: textRange,
                    slide: UInt64(slide)
                ),
                disconnectFrontend: resolveSharedCacheSymbol(
                    named: symbols.disconnectFrontend,
                    symbols: fileBackedSymbols.symbols,
                    symbolRange: fileBackedSymbols.symbolRange,
                    textVMAddress: UInt64(text.virtualMemoryAddress),
                    textRange: textRange,
                    slide: UInt64(slide)
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
                )
            )
            lastResolvedSymbols = resolvedSymbols
            if resolvedFunctionAddresses(from: resolvedSymbols) != nil {
                return finalizeResolution(
                    resolvedSymbols,
                    successLog: "resolved symbol via dyld local symbols (file-backed)",
                    imagePath: "\(loadedImage.path) cache=\(fileBackedSymbols.cachePath),\(javaScriptCoreFileBackedSymbols.cachePath)",
                    webKitHeaderAddress: loadedImage.headerAddress,
                    javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress
                ) ?? failure(.runtimeFunctionSymbolMissing)
            }
        } catch let lookupFailure as WITransportLookupFailure {
            if let lastResolvedSymbols {
                return finalizeResolution(
                    lastResolvedSymbols,
                    successLog: "",
                    imagePath: loadedImage.path,
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
                    successLog: "",
                    imagePath: loadedImage.path,
                    webKitHeaderAddress: loadedImage.headerAddress,
                    javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress
                )
                    ?? failure(.localSymbolsUnavailable, detail: error.localizedDescription)
            }
            return failure(.localSymbolsUnavailable, detail: error.localizedDescription)
        }

        if let lastResolvedSymbols {
            return finalizeResolution(
                lastResolvedSymbols,
                successLog: "",
                imagePath: loadedImage.path,
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

    private static func successResolution(
        _ functionAddresses: WITransportResolvedFunctionAddresses,
        successLog: String,
        imagePath: String
    ) -> WITransportNativeInspectorSymbolResolution {
        NSLog(
            "[WebInspectorTransport] %@ image=%@ backend=%@ connect=0x%llx disconnect=0x%llx from_utf8=0x%llx to_nsstring=0x%llx destroy=0x%llx dispatch=0x%llx",
            successLog,
            imagePath,
            backendKind.rawValue,
            functionAddresses.connectFrontendAddress,
            functionAddresses.disconnectFrontendAddress,
            functionAddresses.stringFromUTF8Address,
            functionAddresses.stringImplToNSStringAddress,
            functionAddresses.destroyStringImplAddress,
            functionAddresses.backendDispatcherDispatchAddress
        )
        return WITransportNativeInspectorSymbolResolution(
            functionAddresses: functionAddresses,
            failureReason: nil
        )
    }

    private static func finalizeResolution(
        _ resolvedSymbols: WITransportNativeInspectorResolvedSymbols,
        successLog: String,
        imagePath: String,
        webKitHeaderAddress: UInt,
        javaScriptCoreHeaderAddress: UInt
    ) -> WITransportNativeInspectorSymbolResolution? {
        let allResults: [(String, WITransportResolvedAddress)] = [
            ("connectFrontend", resolvedSymbols.connectFrontend),
            ("disconnectFrontend", resolvedSymbols.disconnectFrontend),
            ("stringFromUTF8", resolvedSymbols.stringFromUTF8),
            ("stringImplToNSString", resolvedSymbols.stringImplToNSString),
            ("destroyStringImpl", resolvedSymbols.destroyStringImpl),
            ("backendDispatcherDispatch", resolvedSymbols.backendDispatcherDispatch),
        ]

        for (label, result) in allResults {
            if case let .outsideText(address) = result {
                return failure(
                    .resolvedAddressOutsideWebKitText,
                    detail: unsafe String(format: "%@ resolved address 0x%llx.", label, address)
                )
            }
        }

        let expectedHeadersBySymbol: [(String, WITransportResolvedAddress, [UInt])] = [
            ("connectFrontend", resolvedSymbols.connectFrontend, [webKitHeaderAddress]),
            ("disconnectFrontend", resolvedSymbols.disconnectFrontend, [webKitHeaderAddress]),
            ("stringFromUTF8", resolvedSymbols.stringFromUTF8, [javaScriptCoreHeaderAddress]),
            ("stringImplToNSString", resolvedSymbols.stringImplToNSString, [javaScriptCoreHeaderAddress]),
            ("destroyStringImpl", resolvedSymbols.destroyStringImpl, [javaScriptCoreHeaderAddress]),
            ("backendDispatcherDispatch", resolvedSymbols.backendDispatcherDispatch, [webKitHeaderAddress, javaScriptCoreHeaderAddress]),
        ]
        for (label, result, expectedHeaders) in expectedHeadersBySymbol {
            guard case let .found(address) = result else {
                continue
            }
            guard resolvedAddress(address, belongsToAnyOf: expectedHeaders) else {
                return failure(
                    .resolvedAddressImageMismatch,
                    detail: "\(label) resolved into an unexpected image header."
                )
            }
        }

        let missingConnectDisconnect = [
            ("connectFrontend", resolvedSymbols.connectFrontend),
            ("disconnectFrontend", resolvedSymbols.disconnectFrontend),
        ].compactMap { label, result in
            if case .missing = result {
                return label
            }
            return nil
        }
        if !missingConnectDisconnect.isEmpty {
            return failure(
                .connectDisconnectSymbolMissing,
                detail: missingConnectDisconnect.joined(separator: ", ")
            )
        }

        let missingRuntimeFunctions = [
            ("stringFromUTF8", resolvedSymbols.stringFromUTF8),
            ("stringImplToNSString", resolvedSymbols.stringImplToNSString),
            ("destroyStringImpl", resolvedSymbols.destroyStringImpl),
            ("backendDispatcherDispatch", resolvedSymbols.backendDispatcherDispatch),
        ].compactMap { label, result in
            if case .missing = result {
                return label
            }
            return nil
        }
        if !missingRuntimeFunctions.isEmpty {
            return failure(
                .runtimeFunctionSymbolMissing,
                detail: missingRuntimeFunctions.joined(separator: ", ")
            )
        }

        guard let functionAddresses = resolvedFunctionAddresses(from: resolvedSymbols) else {
            return failure(.runtimeFunctionSymbolMissing)
        }
        return successResolution(functionAddresses, successLog: successLog, imagePath: imagePath)
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
                path: path,
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

        return URL(fileURLWithPath: "\(activeSharedCachePath).symbols")
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
    ) throws -> WITransportFileBackedLocalSymbols {
        let symbolCacheURLs = sharedCacheSymbolFileURLs()
        guard !symbolCacheURLs.isEmpty else {
            throw WITransportLookupFailure(
                kind: .localSymbolsUnavailable,
                detail: "No readable dyld_shared_cache_*.symbols file was found in \(sharedCacheDirectoryCandidates.joined(separator: ", "))."
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
                        detail: "MachOKit could not read local symbols info from \(symbolCacheURL.path)."
                    )
                    continue
                }
                guard let entry = localSymbolsInfo.entries(in: symbolCache).first(where: { UInt64($0.dylibOffset) == dylibOffset }) else {
                    lastFailure = WITransportLookupFailure(
                        kind: .webKitLocalSymbolEntryMissing,
                        detail: "MachOKit could not find the WebKit dylibOffset 0x\(String(dylibOffset, radix: 16)) in \(symbolCacheURL.path)."
                    )
                    continue
                }
                guard let symbols = localSymbolsInfo.symbols64(in: symbolCache) else {
                    lastFailure = WITransportLookupFailure(
                        kind: .localSymbolsUnavailable,
                        detail: "MachOKit could not materialize 64-bit local symbols from \(symbolCacheURL.path)."
                    )
                    continue
                }

                return WITransportFileBackedLocalSymbols(
                    cachePath: symbolCacheURL.path,
                    symbols: symbols,
                    symbolRange: entry.nlistRange
                )
            } catch {
                lastFailure = WITransportLookupFailure(
                    kind: .localSymbolsUnavailable,
                    detail: "\(symbolCacheURL.path): \(error.localizedDescription)"
                )
            }
        }

        throw lastFailure ?? WITransportLookupFailure(
            kind: .localSymbolsUnavailable,
            detail: "No dyld shared cache .symbols candidate yielded WebKit local symbols."
        )
    }

    private static func resolveLoadedImageSymbol(
        named symbolName: String,
        in image: MachOImage,
        text: SegmentCommand64
    ) -> WITransportResolvedAddress {
        guard let symbol = image.symbol(named: symbolName, mangled: true, inSection: 0, isGlobalOnly: false) else {
            return .missing
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
            reason = "\(kind.rawValue): \(detail)"
        } else {
            reason = kind.rawValue
        }
        NSLog("[WebInspectorTransport] local symbol resolution failed backend=%@ reason=%@", backendKind.rawValue, reason)
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
    let failureReason: String?

    var supportSnapshot: WITransportSupportSnapshot {
        if isSupported {
            .supported(
                backendKind: backendKind,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot]
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
        imagePathSuffixes: [String] = [
            "/System/Library/Frameworks/WebKit.framework/WebKit",
            "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit",
        ],
        connectSymbol: String = "__ZN6WebKit26WebPageInspectorController15connectFrontendERN9Inspector15FrontendChannelEbb",
        disconnectSymbol: String = "__ZN6WebKit26WebPageInspectorController18disconnectFrontendERN9Inspector15FrontendChannelE",
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
            pathSuffixes: [
                "/System/Library/Frameworks/WebKit.framework/WebKit",
                "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit",
            ]
        ), let loadedJavaScriptCoreImage = WITransportNativeInspectorResolver.loadedWebKitImage(
            pathSuffixes: [
                "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore",
                "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/JavaScriptCore",
            ]
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
