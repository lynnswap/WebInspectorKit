import Foundation
import WebKit
import WebInspectorNativeBridge

/// The native attachment's actual variation boundary: asynchronous explicit
/// detach versus synchronous deinitialization backstop. Both production and
/// tests use the same `NativeAttachment` lifecycle implementation.
package protocol NativeAttachmentBackend: ConnectionBackend {
    @MainActor func detachSynchronously()
}

@MainActor
package final class NativeInspectorBackend: NativeAttachmentBackend {
    private weak var webView: WKWebView?
    private let resolvedSymbols: NativeInspectorResolvedSymbols
    private nonisolated let messageHandler: @Sendable (String) -> Void
    private nonisolated let fatalFailureHandler: @Sendable (String) -> Void
    private var bridge: NativeInspectorBridge?

    package init(
        webView: WKWebView,
        resolvedSymbols: NativeInspectorResolvedSymbols,
        messageHandler: @escaping @Sendable (String) -> Void,
        fatalFailureHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.webView = webView
        self.resolvedSymbols = resolvedSymbols
        self.messageHandler = messageHandler
        self.fatalFailureHandler = fatalFailureHandler
    }

    package func attach() throws {
        guard let webView else {
            throw NativeInspectablePageError.missingWebView
        }
        let bridge = NativeInspectorBridge(webView: webView)
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
                throw ConnectionError.closed
            }
            try bridge.sendJSONString(message)
        }
    }

    package nonisolated func detach() async {
        await MainActor.run {
            detachSynchronously()
        }
    }

    package func detachSynchronously() {
        bridge?.messageHandler = nil
        bridge?.fatalFailureHandler = nil
        bridge?.detach()
        bridge = nil
    }
}
