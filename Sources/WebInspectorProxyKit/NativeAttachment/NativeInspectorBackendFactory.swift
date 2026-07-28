import WebKit
import WebInspectorNativeBridge

package enum NativeInspectorBackendFactory {
    @MainActor
    package static func make(
        webView: WKWebView,
        resolvedSymbols: NativeInspectorResolvedSymbols,
        messageHandler: @escaping @Sendable (String) -> Void,
        fatalFailureHandler: @escaping @Sendable (String) -> Void = { _ in },
        webContentProcessTerminationHandler: @escaping @Sendable () -> Void = {}
    ) -> NativeInspectorBackend {
        NativeInspectorBackend(
            webView: webView,
            resolvedSymbols: resolvedSymbols,
            messageHandler: messageHandler,
            fatalFailureHandler: fatalFailureHandler,
            webContentProcessTerminationHandler: webContentProcessTerminationHandler
        )
    }

    package static func resolvedSymbols() throws -> NativeInspectorResolvedSymbols {
        try NativeInspectorResolvedSymbols.resolveCurrent()
    }

    @MainActor
    package static func resolvedSymbolsDetached() async throws -> NativeInspectorResolvedSymbols {
        try await NativeInspectorResolvedSymbols.resolveCurrentDetached()
    }
}
