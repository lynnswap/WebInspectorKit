import Foundation
import WebKit
@unsafe @preconcurrency import WebInspectorTransportObjCShim

@MainActor
protocol WITransportPlatformBackend: AnyObject {
    var supportSnapshot: WITransportSupportSnapshot { get }

    func attach(to webView: WKWebView, messageSink: any WITransportBackendMessageSink) async throws
    func detach()
    func sendRootMessage(_ message: String) throws
    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws
    func compatibilityResponse(scope: WITransportTargetScope, method: String) -> Data?
}

extension WITransportPlatformBackend {
    func compatibilityResponse(scope: WITransportTargetScope, method: String) -> Data? {
        _ = scope
        _ = method
        return nil
    }
}

package enum WITransportInboundMessage: Sendable {
    case root(String)
    case page(message: String, targetIdentifier: String)
}

protocol WITransportBackendMessageSink: AnyObject, Sendable {
    func didReceiveRootMessage(_ message: String)
    func didReceivePageMessage(_ message: String, targetIdentifier: String)
    func didReceiveFatalFailure(_ message: String)
    func waitForPendingMessagesForTesting() async
}

@MainActor
protocol WITransportMessageEndpoint: AnyObject {
    var supportSnapshot: WITransportSupportSnapshot { get }

    func attach(to webView: WKWebView, messageSink: any WITransportBackendMessageSink) throws
    func detach()
    func sendRootMessage(_ message: String) throws
    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws
}

enum WITransportPlatformBackendFactory {
    @MainActor
    static func makeDefaultBackend(configuration: WITransportConfiguration) -> any WITransportPlatformBackend {
        #if os(iOS)
        return WITransportIOSPlatformBackend(configuration: configuration)
        #elseif os(macOS)
        return WITransportMacNativeInspectorPlatformBackend(configuration: configuration)
        #else
        return WITransportUnsupportedPlatformBackend(
            configuration: configuration,
            reason: "WebInspectorTransport is only available on iOS and macOS."
        )
        #endif
    }
}

@MainActor
private final class WITransportUnsupportedPlatformBackend: WITransportPlatformBackend {
    let supportSnapshot: WITransportSupportSnapshot

    init(configuration: WITransportConfiguration, reason: String) {
        _ = configuration
        supportSnapshot = .unsupported(reason: reason)
    }

    func attach(to webView: WKWebView, messageSink: any WITransportBackendMessageSink) async throws {
        _ = webView
        _ = messageSink
        throw WITransportError.unsupported(supportSnapshot.failureReason ?? "WebInspectorTransport is unsupported.")
    }

    func detach() {
    }

    func sendRootMessage(_ message: String) throws {
        _ = message
        throw WITransportError.transportClosed
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        _ = message
        _ = targetIdentifier
        _ = outerIdentifier
        throw WITransportError.transportClosed
    }
}

@MainActor
private final class WITransportIOSPlatformBackend: WITransportPlatformBackend {
    private let endpoint: WITransportNativeInspectorMessageEndpoint

    init(configuration: WITransportConfiguration) {
        endpoint = WITransportNativeInspectorMessageEndpoint(
            configuration: configuration,
            resolution: WITransportNativeInspectorSymbolResolver.currentAttachResolution()
        )
    }

    var supportSnapshot: WITransportSupportSnapshot {
        endpoint.supportSnapshot
    }

    func attach(to webView: WKWebView, messageSink: any WITransportBackendMessageSink) async throws {
        try endpoint.attach(to: webView, messageSink: messageSink)
    }

    func detach() {
        endpoint.detach()
    }

    func sendRootMessage(_ message: String) throws {
        try endpoint.sendRootMessage(message)
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        try endpoint.sendPageMessage(message, targetIdentifier: targetIdentifier, outerIdentifier: outerIdentifier)
    }

    func compatibilityResponse(scope: WITransportTargetScope, method: String) -> Data? {
        WITransportCompatibilityResponse.pageCompatibilityResponse(
            scope: scope,
            method: method,
            allowsCSSEnableCompatibilityResponse: true
        )
    }
}

@MainActor
final class WITransportMacNativeInspectorPlatformBackend: WITransportPlatformBackend {
    private let endpoint: WITransportNativeInspectorMessageEndpoint

    init(configuration: WITransportConfiguration) {
        endpoint = WITransportNativeInspectorMessageEndpoint(
            configuration: configuration,
            resolution: WITransportNativeInspectorSymbolResolver.currentAttachResolution()
        )
    }

    init(endpoint: WITransportNativeInspectorMessageEndpoint) {
        self.endpoint = endpoint
    }

    var supportSnapshot: WITransportSupportSnapshot {
        endpoint.supportSnapshot
    }

    func attach(to webView: WKWebView, messageSink: any WITransportBackendMessageSink) async throws {
        try endpoint.attach(to: webView, messageSink: messageSink)
    }

    func detach() {
        endpoint.detach()
    }

    func sendRootMessage(_ message: String) throws {
        try endpoint.sendRootMessage(message)
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        try endpoint.sendPageMessage(message, targetIdentifier: targetIdentifier, outerIdentifier: outerIdentifier)
    }

    func compatibilityResponse(scope: WITransportTargetScope, method: String) -> Data? {
        WITransportCompatibilityResponse.pageCompatibilityResponse(
            scope: scope,
            method: method,
            allowsCSSEnableCompatibilityResponse: true
        )
    }
}

private enum WITransportCompatibilityResponse {
    static func pageCompatibilityResponse(
        scope: WITransportTargetScope,
        method: String,
        allowsCSSEnableCompatibilityResponse: Bool
    ) -> Data? {
        guard scope == .page else {
            return nil
        }
        if method == WITransportMethod.DOM.enable {
            return Data("{}".utf8)
        }
        if allowsCSSEnableCompatibilityResponse && method == "CSS.enable" {
            return Data("{}".utf8)
        }
        return nil
    }
}

@MainActor
final class WITransportNativeInspectorMessageEndpoint: WITransportMessageEndpoint {
    private let configuration: WITransportConfiguration
    private let resolution: WITransportAttachSymbolResolution
    private var bridge: WITransportBridge?

    init(configuration: WITransportConfiguration, resolution: WITransportAttachSymbolResolution) {
        self.configuration = configuration
        self.resolution = resolution
    }

    var supportSnapshot: WITransportSupportSnapshot {
        resolution.supportSnapshot
    }

    func attach(to webView: WKWebView, messageSink: any WITransportBackendMessageSink) throws {
        let bridge = WITransportBridge(webView: webView)
        bridge.rootMessageHandler = { message in
            messageSink.didReceiveRootMessage(message)
        }
        bridge.pageMessageHandler = { message, targetIdentifier in
            messageSink.didReceivePageMessage(message, targetIdentifier: targetIdentifier)
        }
        bridge.fatalFailureHandler = messageSink.didReceiveFatalFailure

        do {
            try bridge.attach(
                withConnectFrontendAddress: resolution.connectFrontendAddress,
                disconnectFrontendAddress: resolution.disconnectFrontendAddress
            )
        } catch {
            let reason = (error as? WITransportError)?.errorDescription ?? error.localizedDescription
            configuration.logHandler?("[WebInspectorTransport] attach failed: \(reason)")
            throw error
        }

        self.bridge = bridge
    }

    func detach() {
        bridge?.detach()
        bridge = nil
    }

    func sendRootMessage(_ message: String) throws {
        guard let bridge else {
            throw WITransportError.transportClosed
        }
        try bridge.sendRootJSONString(message)
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        guard let bridge else {
            throw WITransportError.transportClosed
        }
        try bridge.sendPageJSONString(
            message,
            targetIdentifier: targetIdentifier,
            outerIdentifier: NSNumber(value: outerIdentifier)
        )
    }
}
