import Foundation

#if os(iOS) || os(macOS)
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
    ) -> NativeInspectorSymbolResolution {
        return resolveCurrent()
    }
}
#endif
