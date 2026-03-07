import Foundation
import WebKit
@unsafe @preconcurrency import WebInspectorTransportObjCShim

@MainActor
protocol WITransportPlatformBackend: AnyObject {
    var supportSnapshot: WITransportSupportSnapshot { get }

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) throws
    func detach()
    func sendRootMessage(_ message: String) throws
    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws
}

struct WITransportBackendMessageHandlers: Sendable {
    let handleRootMessage: @Sendable (String) -> Void
    let handlePageMessage: @Sendable (String, String) -> Void
    let handleFatalFailure: @Sendable (String) -> Void
}

enum WITransportPlatformBackendFactory {
    @MainActor
    static func makeDefaultBackend(configuration: WITransportConfiguration) -> any WITransportPlatformBackend {
        #if os(iOS)
        return WITransportIOSPlatformBackend(configuration: configuration)
        #elseif os(macOS)
        return WITransportMacPlatformBackend(configuration: configuration)
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
        self.supportSnapshot = WITransportSupportSnapshot(
            availability: .unsupported,
            backendKind: .unsupported,
            failureReason: reason
        )
    }

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) throws {
        throw WITransportError.unsupported(supportSnapshot.failureReason ?? "WebInspectorTransport is unsupported.")
    }

    func detach() {
    }

    func sendRootMessage(_ message: String) throws {
        throw WITransportError.transportClosed
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        throw WITransportError.transportClosed
    }
}

@MainActor
private final class WITransportIOSPlatformBackend: WITransportPlatformBackend {
    private let impl: WITransportNativeInspectorPlatformBackend

    init(configuration: WITransportConfiguration) {
        impl = WITransportNativeInspectorPlatformBackend(
            configuration: configuration,
            resolution: WITransportNativeInspectorSymbolResolver.currentAttachResolution()
        )
    }

    var supportSnapshot: WITransportSupportSnapshot {
        impl.supportSnapshot
    }

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) throws {
        try impl.attach(to: webView, messageHandlers: messageHandlers)
    }

    func detach() {
        impl.detach()
    }

    func sendRootMessage(_ message: String) throws {
        try impl.sendRootMessage(message)
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        try impl.sendPageMessage(message, targetIdentifier: targetIdentifier, outerIdentifier: outerIdentifier)
    }
}

@MainActor
private final class WITransportMacPlatformBackend: WITransportPlatformBackend {
    private let impl: WITransportNativeInspectorPlatformBackend

    init(configuration: WITransportConfiguration) {
        impl = WITransportNativeInspectorPlatformBackend(
            configuration: configuration,
            resolution: WITransportNativeInspectorSymbolResolver.currentAttachResolution()
        )
    }

    var supportSnapshot: WITransportSupportSnapshot {
        impl.supportSnapshot
    }

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) throws {
        try impl.attach(to: webView, messageHandlers: messageHandlers)
    }

    func detach() {
        impl.detach()
    }

    func sendRootMessage(_ message: String) throws {
        try impl.sendRootMessage(message)
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        try impl.sendPageMessage(message, targetIdentifier: targetIdentifier, outerIdentifier: outerIdentifier)
    }
}

@MainActor
private final class WITransportNativeInspectorPlatformBackend: WITransportPlatformBackend {
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

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) throws {
        let bridge = WITransportBridge(webView: webView)
        bridge.rootMessageHandler = messageHandlers.handleRootMessage
        bridge.pageMessageHandler = messageHandlers.handlePageMessage
        bridge.fatalFailureHandler = messageHandlers.handleFatalFailure

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
