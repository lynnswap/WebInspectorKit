#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

extension NativeInspectorSymbolResolverCore {
    static func resolveUsingSharedCache(
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
}
#endif
