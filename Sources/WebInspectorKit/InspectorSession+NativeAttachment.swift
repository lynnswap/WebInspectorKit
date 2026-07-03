import WebKit
import WebInspectorCore
import WebInspectorDataKit
import WebInspectorNativeTransport
import WebInspectorProxyKit

package extension InspectorSession {
    @MainActor
    func attach(to webView: WKWebView) async throws -> WebInspectorContext {
        let attachRequestGeneration = beginAttachmentRequest()
        let resolvedSymbols = try await NativeInspectorBackendFactory.resolvedSymbolsDetached()
        try ensureCurrentAttachmentRequest(attachRequestGeneration)
        try await detachForAttachmentRequest(attachRequestGeneration)

        let connection = try await NativeInspectorConnectionFactory.attach(
            to: webView,
            resolvedSymbols: resolvedSymbols,
            makeTransportSession: { backend in
                makeTransportSession(backend: backend)
            },
            fatalFailureHandler: { [weak self] message in
                Task { @MainActor in
                    self?.recordAttachmentError(InspectorSession.Error(message))
                }
            }
        )
        do {
            let proxy = try await WebInspectorProxy(transport: connection.transport)
            let container = WebInspectorContainer(proxy: proxy)
            let context = container.mainContext
            try await connectAttachment(
                transport: connection.transport,
                receiver: connection.receiver,
                pageReloadAction: connection.reloadPage,
                pageReloadAvailability: connection.canReloadPage,
                connectionCleanup: connection.restoreInspectabilityIfNeeded,
                attachRequestGeneration: attachRequestGeneration
            )
            return context
        } catch {
            await connection.close()
            throw error
        }
    }
}
