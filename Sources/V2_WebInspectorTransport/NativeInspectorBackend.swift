import Foundation
import WebKit
@unsafe @preconcurrency import WebInspectorTransportObjCShim
import V2_WebInspectorCore

@MainActor
package final class NativeInspectorBackend: TransportBackend {
    private let webView: WKWebView
    private let resolvedFunctions: WITransportResolvedFunctions
    private nonisolated let rootMessageHandler: @Sendable (String) -> Void
    private nonisolated let fatalFailureHandler: @Sendable (String) -> Void
    private var bridge: WITransportBridge?

    package init(
        webView: WKWebView,
        resolvedFunctions: WITransportResolvedFunctions,
        rootMessageHandler: @escaping @Sendable (String) -> Void,
        fatalFailureHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.webView = webView
        self.resolvedFunctions = resolvedFunctions
        self.rootMessageHandler = rootMessageHandler
        self.fatalFailureHandler = fatalFailureHandler
    }

    package func attach() throws {
        let bridge = WITransportBridge(webView: webView)
        bridge.rootMessageHandler = { [rootMessageHandler] message in
            rootMessageHandler(message)
        }
        bridge.fatalFailureHandler = { [fatalFailureHandler] message in
            fatalFailureHandler(message)
        }
        try bridge.attach(with: resolvedFunctions)
        self.bridge = bridge
    }

    package nonisolated func sendRootJSONString(_ message: String) async throws {
        try await MainActor.run {
            guard let bridge else {
                throw TransportError.transportClosed
            }
            try bridge.sendRootJSONString(message)
        }
    }

    package nonisolated func sendTargetJSONString(
        _ message: String,
        targetIdentifier: ProtocolTargetIdentifier,
        outerIdentifier: UInt64
    ) async throws {
        try await MainActor.run {
            guard let bridge else {
                throw TransportError.transportClosed
            }
            try bridge.sendPageJSONString(
                message,
                targetIdentifier: targetIdentifier.rawValue,
                outerIdentifier: NSNumber(value: outerIdentifier)
            )
        }
    }

    package nonisolated func detach() async {
        await MainActor.run {
            bridge?.detach()
            bridge = nil
        }
    }
}
