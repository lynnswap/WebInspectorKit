import WebKit
@unsafe @preconcurrency import V2_WebInspectorNativeBridge

package enum NativeInspectorBackendFactory {
    @MainActor
    package static func make(
        webView: WKWebView,
        messageHandler: @escaping @Sendable (String) -> Void,
        fatalFailureHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> NativeInspectorBackend {
        try NativeInspectorBackend(
            webView: webView,
            resolvedSymbols: resolvedSymbols(),
            messageHandler: messageHandler,
            fatalFailureHandler: fatalFailureHandler
        )
    }

    package static func resolvedSymbols() throws -> V2WINativeResolvedSymbols {
        let resolution = V2_TransportNativeInspectorSymbolResolver.currentAttachResolution()
        guard resolution.isSupported else {
            throw NativeInspectorBackendFactoryError.missingSymbols(resolution.missingFunctions)
        }

        return V2WINativeResolvedSymbols(
            connectFrontendAddress: resolution.connectFrontendAddress,
            disconnectFrontendAddress: resolution.disconnectFrontendAddress,
            stringFromUTF8Address: resolution.stringFromUTF8Address,
            stringImplToNSStringAddress: resolution.stringImplToNSStringAddress,
            destroyStringImplAddress: resolution.destroyStringImplAddress,
            backendDispatcherDispatchAddress: resolution.backendDispatcherDispatchAddress
        )
    }
}

package enum NativeInspectorBackendFactoryError: Error, Equatable, Sendable {
    case missingSymbols([String])
}
