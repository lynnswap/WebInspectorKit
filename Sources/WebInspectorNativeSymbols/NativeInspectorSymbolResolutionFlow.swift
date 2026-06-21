#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

extension NativeInspectorSymbolResolverCore {
    static func resolve(
        imagePathSuffixes: [String],
        javaScriptCorePathSuffixes: [String],
        webCorePathSuffixes: [String] = webCoreImagePathSuffixes,
        allowSharedCacheFallback: Bool = true,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorSymbolLookupResult {
        guard let loadedImage = loadedWebKitImage(pathSuffixes: imagePathSuffixes) else {
            return failure(.inspectorImageMissing)
        }
        guard let loadedJavaScriptCoreImage = loadedWebKitImage(pathSuffixes: javaScriptCorePathSuffixes) else {
            return failure(.supportImageMissing)
        }
        let loadedWebCoreImage = loadedWebKitImage(pathSuffixes: webCorePathSuffixes)

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
            connectFrontend: resolveLoadedImageSymbol(matching: symbols.connectFrontend, in: image, text: text),
            disconnectFrontend: resolveLoadedImageSymbol(matching: symbols.disconnectFrontend, in: image, text: text),
            stringFromUTF8: resolveLoadedImageSymbol(matching: symbols.stringFromUTF8, in: javaScriptCoreImage, text: javaScriptCoreText),
            stringImplToNSString: resolveLoadedImageSymbol(matching: symbols.stringImplToNSString, in: javaScriptCoreImage, text: javaScriptCoreText),
            destroyStringImpl: resolveLoadedImageSymbol(matching: symbols.destroyStringImpl, in: javaScriptCoreImage, text: javaScriptCoreText),
            backendDispatcherDispatch: preferredResolvedAddress(
                resolveLoadedImageSymbol(matching: symbols.backendDispatcherDispatch, in: image, text: text),
                fallback: resolveLoadedImageSymbol(matching: symbols.backendDispatcherDispatch, in: javaScriptCoreImage, text: javaScriptCoreText)
            )
        )
        let loadedImageResolution = successfulResolutionIfComplete(
            loadedImageResults,
            phase: .loadedImage,
            source: "loaded-image",
            webKitHeaderAddress: loadedImage.headerAddress,
            javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
            usedConnectDisconnectFallback: false
        )
            ?? finalizeResolution(
                loadedImageResults,
                phase: .loadedImage,
                source: "loaded-image",
                webKitHeaderAddress: loadedImage.headerAddress,
                javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
                usedConnectDisconnectFallback: false,
                shouldLogFailure: false
            )
            ?? failure(.runtimeFunctionSymbolMissing, shouldLog: false)

        if loadedImageResolution.failureReason == nil {
            return loadedImageResolution
        }

        guard allowSharedCacheFallback else {
            return unsafe resolveLoadedImageTextScanFallback(
                loadedImageResults,
                image: image,
                text: text,
                webCoreImage: webCoreImage,
                webCoreText: webCoreText,
                javaScriptCoreImage: javaScriptCoreImage,
                javaScriptCoreText: javaScriptCoreText,
                loadedImage: loadedImage,
                loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
                symbols: symbols
            )
        }

        #if DEBUG
        logResolutionAttemptIncomplete(
            loadedImageResolution,
            nextAttempt: "shared-cache"
        )
        #endif

        let sharedCacheResolution = unsafe resolveUsingSharedCache(
            loadedImage: loadedImage,
            imagePathSuffixes: imagePathSuffixes,
            loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
            javaScriptCorePathSuffixes: javaScriptCorePathSuffixes,
            loadedWebCoreImage: loadedWebCoreImage,
            webCorePathSuffixes: webCorePathSuffixes,
            loadedImageSymbols: loadedImageResults,
            symbols: symbols
        )
        if sharedCacheResolution.failureReason == nil {
            return sharedCacheResolution
        }
        let loadedImageTextScanResolution = unsafe resolveLoadedImageTextScanFallback(
            loadedImageResults,
            image: image,
            text: text,
            webCoreImage: webCoreImage,
            webCoreText: webCoreText,
            javaScriptCoreImage: javaScriptCoreImage,
            javaScriptCoreText: javaScriptCoreText,
            loadedImage: loadedImage,
            loadedJavaScriptCoreImage: loadedJavaScriptCoreImage,
            symbols: symbols
        )
        let mergedLookupResult = mergedResolution(
            preferred: sharedCacheResolution,
            fallback: loadedImageTextScanResolution
        )
        return mergedLookupResult
    }

    @unsafe private static func resolveLoadedImageTextScanFallback(
        _ resolvedSymbols: NativeInspectorResolvedSymbolSet,
        image: MachOImage,
        text: SegmentCommand64,
        webCoreImage: MachOImage?,
        webCoreText: SegmentCommand64?,
        javaScriptCoreImage: MachOImage,
        javaScriptCoreText: SegmentCommand64,
        loadedImage: LoadedNativeInspectorImage,
        loadedJavaScriptCoreImage: LoadedNativeInspectorImage,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorSymbolLookupResult {
        let fallbackResults = unsafe resolveConnectDisconnectFallbackIfNeeded(
            resolvedSymbols,
            image: image,
            text: text,
            webCoreImage: webCoreImage,
            webCoreText: webCoreText,
            javaScriptCoreImage: javaScriptCoreImage,
            javaScriptCoreText: javaScriptCoreText,
            symbols: symbols
        )
        let source = fallbackResults.usedFallback ? "loaded-image+text-scan" : "loaded-image"
        return successfulResolutionIfComplete(
            fallbackResults.symbols,
            phase: .loadedImage,
            source: source,
            webKitHeaderAddress: loadedImage.headerAddress,
            javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
            usedConnectDisconnectFallback: fallbackResults.usedFallback
        )
            ?? finalizeResolution(
                fallbackResults.symbols,
                phase: .loadedImage,
                source: source,
                webKitHeaderAddress: loadedImage.headerAddress,
                javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
                usedConnectDisconnectFallback: fallbackResults.usedFallback,
                shouldLogFailure: false
            )
            ?? failure(
                .runtimeFunctionSymbolMissing,
                phase: .loadedImage,
                source: source,
                usedConnectDisconnectFallback: fallbackResults.usedFallback,
                shouldLog: false
            )
    }

    static func preferredResolvedAddress(
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

    static func applyingLoadedImageRuntimeFallback(
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

    static func usesLoadedImageRuntimeFallback(
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

    static func sharedCacheSourceDescription(
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

    static func mergedResolution(
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
}
#endif
