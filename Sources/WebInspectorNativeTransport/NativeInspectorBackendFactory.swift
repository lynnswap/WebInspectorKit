import WebKit
import WebInspectorNativeBridge
import WebInspectorNativeSymbols
import WebInspectorTransport

package enum NativeInspectorBackendFactory {
    @MainActor
    package static func make(
        webView: WKWebView,
        resolvedSymbols: WebInspectorNativeResolvedSymbols,
        messageHandler: @escaping @Sendable (String) -> Void,
        fatalFailureHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) -> NativeInspectorBackend {
        NativeInspectorBackend(
            webView: webView,
            resolvedSymbols: resolvedSymbols,
            messageHandler: messageHandler,
            fatalFailureHandler: fatalFailureHandler
        )
    }

    package static func resolvedSymbols() throws -> WebInspectorNativeResolvedSymbols {
        let resolution = NativeInspectorSymbolResolver.resolveCurrent()
        return try resolvedSymbols(from: resolution)
    }

    @MainActor
    package static func resolvedSymbolsDetached() async throws -> WebInspectorNativeResolvedSymbols {
        let resolution = await NativeInspectorSymbolResolver.resolveCurrentDetached()
        return try resolvedSymbols(from: resolution)
    }

    private static func resolvedSymbols(
        from resolution: NativeInspectorSymbolResolution
    ) throws -> WebInspectorNativeResolvedSymbols {
        guard resolution.isSupported else {
            throw NativeInspectorBackendFactoryError.missingSymbols(resolution.missingFunctions)
        }

        return WebInspectorNativeResolvedSymbols(
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
