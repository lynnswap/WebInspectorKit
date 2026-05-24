import Foundation
import WebKit
@unsafe @preconcurrency import WebInspectorNativeBridge
import WebInspectorCore

@MainActor
package final class NativeInspectorBackend: TransportBackend {
    private let webView: WKWebView
    private let resolvedSymbols: WebInspectorNativeResolvedSymbols
    private nonisolated let messageHandler: @Sendable (String) -> Void
    private nonisolated let fatalFailureHandler: @Sendable (String) -> Void
    private var bridge: WebInspectorNativeBridge?

    package init(
        webView: WKWebView,
        resolvedSymbols: WebInspectorNativeResolvedSymbols,
        messageHandler: @escaping @Sendable (String) -> Void,
        fatalFailureHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.webView = webView
        self.resolvedSymbols = resolvedSymbols
        self.messageHandler = messageHandler
        self.fatalFailureHandler = fatalFailureHandler
    }

    package func attach() throws {
        let bridge = WebInspectorNativeBridge(webView: webView)
        bridge.messageHandler = { [messageHandler] message in
            messageHandler(message)
        }
        bridge.fatalFailureHandler = { [fatalFailureHandler] message in
            fatalFailureHandler(message)
        }
        try bridge.attach(with: resolvedSymbols)
        self.bridge = bridge
    }

    package nonisolated func sendJSONString(_ message: String) async throws {
        try await MainActor.run {
            guard let bridge else {
                throw TransportError.transportClosed
            }
            try bridge.sendJSONString(message)
        }
    }

    package nonisolated func detach() async {
        await MainActor.run {
            bridge?.detach()
            bridge = nil
        }
    }
}
