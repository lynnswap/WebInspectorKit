#if os(iOS) || os(macOS)
import Foundation
import MachO
import MachOKit

extension NativeInspectorSymbolResolverCore {
    static func resolve(
        imagePathSuffixes: [String],
        javaScriptCorePathSuffixes: [String],
        allowSharedCacheFallback: Bool = true,
        symbols: NativeInspectorSymbols
    ) -> NativeInspectorSymbolLookupResult {
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

        let loadedWebKitResults = resolveLoadedImageSymbols(
            matching: [
                NativeInspectorSymbolMatchTarget(role: .connectFrontend, symbol: symbols.connectFrontend),
                NativeInspectorSymbolMatchTarget(role: .disconnectFrontend, symbol: symbols.disconnectFrontend),
                NativeInspectorSymbolMatchTarget(role: .debuggableVTable, symbol: symbols.debuggableVTable),
                NativeInspectorSymbolMatchTarget(role: .derefStringImpl, symbol: symbols.derefStringImpl),
                NativeInspectorSymbolMatchTarget(role: .dispatchMessageFromRemote, symbol: symbols.dispatchMessageFromRemote),
            ],
            in: image,
            text: text
        )
        let loadedJavaScriptCoreResults = resolveLoadedImageSymbols(
            matching: [
                NativeInspectorSymbolMatchTarget(role: .stringFromUTF8, symbol: symbols.stringFromUTF8),
                NativeInspectorSymbolMatchTarget(role: .stringImplToNSString, symbol: symbols.stringImplToNSString),
                NativeInspectorSymbolMatchTarget(role: .derefStringImpl, symbol: symbols.derefStringImpl),
            ],
            in: javaScriptCoreImage,
            text: javaScriptCoreText
        )
        let loadedImageResults = NativeInspectorResolvedSymbolSet(
            connectFrontend: loadedWebKitResults[.connectFrontend] ?? .missing,
            disconnectFrontend: loadedWebKitResults[.disconnectFrontend] ?? .missing,
            stringFromUTF8: loadedJavaScriptCoreResults[.stringFromUTF8] ?? .missing,
            stringImplToNSString: loadedJavaScriptCoreResults[.stringImplToNSString] ?? .missing,
            derefStringImpl: preferredResolvedAddress(
                loadedWebKitResults[.derefStringImpl] ?? .missing,
                fallback: loadedJavaScriptCoreResults[.derefStringImpl] ?? .missing
            ),
            dispatchMessageFromRemote: loadedWebKitResults[.dispatchMessageFromRemote] ?? .missing,
            debuggableVTable: loadedWebKitResults[.debuggableVTable] ?? .missing
        )
        let loadedImageResolution = successfulResolutionIfComplete(
            loadedImageResults,
            phase: .loadedImage,
            source: "loaded-image",
            webKitHeaderAddress: loadedImage.headerAddress,
            javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
        )
            ?? finalizeResolution(
                loadedImageResults,
                phase: .loadedImage,
                source: "loaded-image",
                webKitHeaderAddress: loadedImage.headerAddress,
                javaScriptCoreHeaderAddress: loadedJavaScriptCoreImage.headerAddress,
                shouldLogFailure: false
            )
            ?? failure(.runtimeFunctionSymbolMissing, shouldLog: false)

        if loadedImageResolution.failureReason == nil {
            return loadedImageResolution
        }

        guard allowSharedCacheFallback else { return loadedImageResolution }

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
            loadedImageSymbols: loadedImageResults,
            symbols: symbols
        )
        if sharedCacheResolution.failureReason == nil {
            return sharedCacheResolution
        }
        return mergedResolution(preferred: sharedCacheResolution, fallback: loadedImageResolution)
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
            derefStringImpl: preferredResolvedAddress(
                resolvedSymbols.derefStringImpl,
                fallback: loadedImageSymbols.derefStringImpl
            ),
            dispatchMessageFromRemote: preferredResolvedAddress(
                resolvedSymbols.dispatchMessageFromRemote,
                fallback: loadedImageSymbols.dispatchMessageFromRemote
            ),
            debuggableVTable: preferredResolvedAddress(resolvedSymbols.debuggableVTable, fallback: loadedImageSymbols.debuggableVTable)
        )
    }

    static func usesLoadedImageRuntimeFallback(
        resolvedSymbols: NativeInspectorResolvedSymbolSet,
        loadedImageSymbols: NativeInspectorResolvedSymbolSet
    ) -> Bool {
        let symbolPairs: [(ResolvedNativeInspectorAddress, ResolvedNativeInspectorAddress)] = [
            (resolvedSymbols.stringFromUTF8, loadedImageSymbols.stringFromUTF8),
            (resolvedSymbols.stringImplToNSString, loadedImageSymbols.stringImplToNSString),
            (resolvedSymbols.derefStringImpl, loadedImageSymbols.derefStringImpl),
            (resolvedSymbols.dispatchMessageFromRemote, loadedImageSymbols.dispatchMessageFromRemote),
            (resolvedSymbols.debuggableVTable, loadedImageSymbols.debuggableVTable),
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
        usedRuntimeFallback: Bool
    ) -> String {
        var parts = [base]
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
        )
    }
}
#endif
