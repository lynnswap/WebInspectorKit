import Foundation

#if os(iOS) || os(macOS)
enum NativeInspectorSymbolResolver {
    static func resolveCurrent() -> NativeInspectorSymbolResolution {
        makeAttachResolution(from: NativeInspectorSymbolResolverCore.resolveCurrentWebKitAttachSymbols())
    }

    static func resolveCurrentDetached() async -> NativeInspectorSymbolResolution {
        await Task.detached(priority: .userInitiated) {
            resolveCurrent()
        }.value
    }

    static func resolveForTesting(
        imagePathSuffixes: [String] = NativeInspectorSymbolResolverCore.webKitImagePathSuffixes,
        javaScriptCorePathSuffixes: [String] = NativeInspectorSymbolResolverCore.javaScriptCoreImagePathSuffixes,
        webCorePathSuffixes: [String] = NativeInspectorSymbolResolverCore.webCoreImagePathSuffixes,
        allowSharedCacheFallback: Bool = true,
        symbols: NativeInspectorSymbols = NativeInspectorSymbolResolverCore.currentSymbolQueries()
    ) -> NativeInspectorSymbolResolution {
        makeAttachResolution(
            from: NativeInspectorSymbolResolverCore.resolveForTesting(
                imagePathSuffixes: imagePathSuffixes,
                javaScriptCorePathSuffixes: javaScriptCorePathSuffixes,
                webCorePathSuffixes: webCorePathSuffixes,
                allowSharedCacheFallback: allowSharedCacheFallback,
                symbols: symbols
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
enum NativeInspectorSymbolResolver {
    static func resolveCurrent() -> NativeInspectorSymbolResolution {
        NativeInspectorSymbolResolution(
            addresses: .zero,
            failureReason: "Native inspector transport is only available on iOS and macOS.",
            failureKind: "unsupported",
            phase: nil,
            missingFunctions: [],
            source: nil,
            usedConnectDisconnectFallback: false
        )
    }

    static func resolveCurrentDetached() async -> NativeInspectorSymbolResolution {
        resolveCurrent()
    }

    static func resolveForTesting(
        imagePathSuffixes: [String] = [],
        javaScriptCorePathSuffixes: [String] = [],
        webCorePathSuffixes: [String] = [],
        allowSharedCacheFallback: Bool = true
    ) -> NativeInspectorSymbolResolution {
        return resolveCurrent()
    }
}
#endif
