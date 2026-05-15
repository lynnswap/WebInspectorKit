#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

extension NativeInspectorSymbolResolverCore {
    static func resolve(
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
        let mergedLookupResult = mergedResolution(
            preferred: loadedImageResolution,
            fallback: sharedCacheResolution
        )
        #if DEBUG
        unsafe debugLogSimilarAttachSymbolsIfNeeded(
            for: mergedLookupResult,
            loadedWebKitImage: image,
            loadedWebKitText: text,
            loadedWebKitHeaderAddress: loadedImage.headerAddress,
            loadedWebCoreImage: webCoreImage,
            loadedWebCoreText: webCoreText,
            loadedWebCoreHeaderAddress: loadedWebCoreImage?.headerAddress,
            imagePathSuffixes: imagePathSuffixes
        )
        #endif
        return mergedLookupResult
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
