import Foundation
import WebKit
@unsafe @preconcurrency import WebInspectorTransportObjCShim

@MainActor
protocol WITransportPlatformBackend: AnyObject {
    var supportSnapshot: WITransportSupportSnapshot { get }

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) async throws
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

struct WITransportBackendMessageHandlers {
    let handleRootMessage: (String) -> Void
    let handlePageMessage: (String, String) -> Void
    let handleFatalFailure: (String) -> Void
}

@MainActor
protocol WITransportMessageEndpoint: AnyObject {
    var supportSnapshot: WITransportSupportSnapshot { get }

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) throws
    func detach()
    func sendRootMessage(_ message: String) throws
    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws
}

@MainActor
protocol WITransportFrontendHost: AnyObject {
    var supportSnapshot: WITransportSupportSnapshot { get }

    func attach(
        to webView: WKWebView,
        backendMessageHandler: @escaping (String) -> Void,
        fatalFailureHandler: @escaping (String) -> Void
    ) async throws
    func mirrorBackendMessage(_ message: String)
    func detach()
}

enum WITransportPlatformBackendFactory {
    @MainActor
    static func makeDefaultBackend(configuration: WITransportConfiguration) -> any WITransportPlatformBackend {
        #if os(iOS)
        return WITransportIOSPlatformBackend(configuration: configuration)
        #elseif os(macOS)
        return WITransportMacDefaultBackendSelector.selectDefaultBackend(
            remoteBackend: WITransportMacRemoteInspectorPlatformBackend(configuration: configuration),
            nativeBackend: WITransportMacNativeInspectorPlatformBackend(configuration: configuration)
        )
        #else
        return WITransportUnsupportedPlatformBackend(
            configuration: configuration,
            reason: "WebInspectorTransport is only available on iOS and macOS."
        )
        #endif
    }
}

enum WITransportMacDefaultBackendSelector {
    @MainActor
    static func selectDefaultBackend(
        remoteBackend: any WITransportPlatformBackend,
        nativeBackend: any WITransportPlatformBackend
    ) -> any WITransportPlatformBackend {
        if remoteBackend.supportSnapshot.isSupported {
            return remoteBackend
        }
        return nativeBackend
    }
}

@MainActor
private final class WITransportUnsupportedPlatformBackend: WITransportPlatformBackend {
    let supportSnapshot: WITransportSupportSnapshot

    init(configuration: WITransportConfiguration, reason: String) {
        _ = configuration
        supportSnapshot = WITransportSupportSnapshot(
            availability: .unsupported,
            backendKind: .unsupported,
            failureReason: reason
        )
    }

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) async throws {
        _ = webView
        _ = messageHandlers
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

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) async throws {
        try endpoint.attach(to: webView, messageHandlers: messageHandlers)
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
        WITransportCompatibilityResponse.domEnableIfNeeded(scope: scope, method: method)
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

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) async throws {
        try endpoint.attach(to: webView, messageHandlers: messageHandlers)
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
        WITransportCompatibilityResponse.domEnableIfNeeded(scope: scope, method: method)
    }
}

@MainActor
final class WITransportMacRemoteInspectorPlatformBackend: WITransportPlatformBackend {
    private let configuration: WITransportConfiguration
    private let transportEndpoint: any WITransportMessageEndpoint
    private let frontendHost: any WITransportFrontendHost
    private let composedSupportSnapshot: WITransportSupportSnapshot
    private var attachState: AttachState = .detached
    private var operatingMode: OperatingMode = .frontendHosted

    private enum AttachState {
        case detached
        case attaching
        case attached
    }

    private enum OperatingMode {
        case frontendHosted
        case transportOnly
    }

    #if os(macOS)
    convenience init(configuration: WITransportConfiguration) {
        self.init(
            configuration: configuration,
            transportEndpoint: WITransportNativeInspectorMessageEndpoint(
                configuration: configuration,
                resolution: WITransportNativeInspectorSymbolResolver.currentAttachResolution()
            ),
            frontendHost: WITransportRemoteInspectorFrontendHost(configuration: configuration)
        )
    }
    #endif

    init(
        configuration: WITransportConfiguration,
        transportEndpoint: any WITransportMessageEndpoint,
        frontendHost: any WITransportFrontendHost
    ) {
        self.configuration = configuration
        self.transportEndpoint = transportEndpoint
        self.frontendHost = frontendHost
        composedSupportSnapshot = WITransportMacRemoteInspectorPlatformBackend.makeSupportSnapshot(
            transportEndpointSnapshot: transportEndpoint.supportSnapshot,
            frontendHostSnapshot: frontendHost.supportSnapshot
        )
    }

    var supportSnapshot: WITransportSupportSnapshot {
        switch operatingMode {
        case .frontendHosted:
            composedSupportSnapshot
        case .transportOnly:
            transportEndpoint.supportSnapshot
        }
    }

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) async throws {
        guard composedSupportSnapshot.isSupported || transportEndpoint.supportSnapshot.isSupported else {
            throw WITransportError.unsupported(
                composedSupportSnapshot.failureReason
                    ?? transportEndpoint.supportSnapshot.failureReason
                    ?? "The macOS remote inspector backend is unavailable."
            )
        }
        guard attachState == .detached else {
            throw WITransportError.alreadyAttached
        }

        attachState = .attaching
        operatingMode = .frontendHosted

        let canHostRemoteFrontend = composedSupportSnapshot.capabilities.contains(.remoteFrontendHosting)

        let transportHandlers = WITransportBackendMessageHandlers(
            handleRootMessage: { [frontendHost] message in
                frontendHost.mirrorBackendMessage(message)
                messageHandlers.handleRootMessage(message)
            },
            handlePageMessage: messageHandlers.handlePageMessage,
            handleFatalFailure: { [frontendHost] message in
                frontendHost.detach()
                messageHandlers.handleFatalFailure(message)
            }
        )

        let frontendCommandForwarder = WITransportBufferedRootMessageForwarder(
            logHandler: configuration.logHandler,
            fatalFailureHandler: { [transportEndpoint] message in
                transportEndpoint.detach()
                messageHandlers.handleFatalFailure(message)
            },
            sendMessage: { [transportEndpoint] message in
                try transportEndpoint.sendRootMessage(message)
            }
        )

        do {
            guard canHostRemoteFrontend else {
                try attachTransportOnly(to: webView, messageHandlers: messageHandlers)
                configuration.logHandler?("[WebInspectorTransport] remote frontend host unavailable; attaching in transport-only mode")
                return
            }

            guard isHostedInWindow(webView) else {
                try attachTransportOnly(to: webView, messageHandlers: messageHandlers)
                return
            }

            do {
                try await frontendHost.attach(
                    to: webView,
                    backendMessageHandler: { message in
                        frontendCommandForwarder.handle(message)
                    },
                    fatalFailureHandler: { [transportEndpoint] message in
                        transportEndpoint.detach()
                        messageHandlers.handleFatalFailure(message)
                    }
                )
            } catch {
                frontendHost.detach()
                do {
                    try attachTransportOnly(to: webView, messageHandlers: messageHandlers)
                    configuration.logHandler?("[WebInspectorTransport] remote frontend host attach failed; continuing with transport-only mode")
                    return
                } catch let fallbackError as WITransportError {
                    let hostReason = (error as? WITransportError)?.errorDescription ?? error.localizedDescription
                    let fallbackReason = fallbackError.errorDescription ?? String(describing: fallbackError)
                    throw WITransportError.attachFailed(
                        "Remote frontend host attach failed (\(hostReason)); transport-only fallback failed (\(fallbackReason))"
                    )
                }
            }

            try transportEndpoint.attach(to: webView, messageHandlers: transportHandlers)
            frontendCommandForwarder.activate()
            attachState = .attached
        } catch let error as WITransportError {
            attachState = .detached
            frontendHost.detach()
            transportEndpoint.detach()
            operatingMode = .frontendHosted
            throw error
        } catch {
            attachState = .detached
            frontendHost.detach()
            transportEndpoint.detach()
            operatingMode = .frontendHosted
            throw WITransportError.attachFailed(error.localizedDescription)
        }
    }

    func detach() {
        attachState = .detached
        operatingMode = .frontendHosted
        frontendHost.detach()
        transportEndpoint.detach()
    }

    func sendRootMessage(_ message: String) throws {
        try transportEndpoint.sendRootMessage(message)
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        try transportEndpoint.sendPageMessage(message, targetIdentifier: targetIdentifier, outerIdentifier: outerIdentifier)
    }

    func compatibilityResponse(scope: WITransportTargetScope, method: String) -> Data? {
        WITransportCompatibilityResponse.domEnableIfNeeded(scope: scope, method: method)
    }

    private func attachTransportOnly(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) throws {
        try transportEndpoint.attach(to: webView, messageHandlers: messageHandlers)
        operatingMode = .transportOnly
        attachState = .attached
    }

    private func isHostedInWindow(_ webView: WKWebView) -> Bool {
        #if os(macOS)
        unsafe webView.window != nil
        #else
        webView.window != nil
        #endif
    }
}

private enum WITransportCompatibilityResponse {
    static func domEnableIfNeeded(scope: WITransportTargetScope, method: String) -> Data? {
        guard scope == .page else {
            return nil
        }
        if method == WITransportCommands.DOM.Enable.method {
            return Data("{}".utf8)
        }
        if method == "CSS.enable" {
            return Data("{}".utf8)
        }
        return nil
    }
}

@MainActor
private final class WITransportBufferedRootMessageForwarder {
    private let logHandler: WITransportLogHandler?
    private let fatalFailureHandler: (String) -> Void
    private let sendMessage: (String) throws -> Void
    private var bufferedMessages: [String] = []
    private var isTransportReady = false

    init(
        logHandler: WITransportLogHandler?,
        fatalFailureHandler: @escaping (String) -> Void,
        sendMessage: @escaping (String) throws -> Void
    ) {
        self.logHandler = logHandler
        self.fatalFailureHandler = fatalFailureHandler
        self.sendMessage = sendMessage
    }

    func handle(_ message: String) {
        guard isTransportReady else {
            bufferedMessages.append(message)
            return
        }

        forward(message)
    }

    func activate() {
        guard !isTransportReady else {
            return
        }

        isTransportReady = true
        let pendingMessages = bufferedMessages
        bufferedMessages.removeAll(keepingCapacity: false)
        for message in pendingMessages {
            forward(message)
        }
    }

    private func forward(_ message: String) {
        do {
            try sendMessage(message)
        } catch {
            let reason = (error as? WITransportError)?.errorDescription ?? error.localizedDescription
            logHandler?("[WebInspectorTransport] remote frontend host backend dispatch failed: \(reason)")
            fatalFailureHandler(reason)
        }
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

private extension WITransportMacRemoteInspectorPlatformBackend {
    static func makeSupportSnapshot(
        transportEndpointSnapshot: WITransportSupportSnapshot,
        frontendHostSnapshot: WITransportSupportSnapshot
    ) -> WITransportSupportSnapshot {
        let isSupported = transportEndpointSnapshot.isSupported
        let failureReason: String?
        let capabilities: Set<WITransportCapability>

        if transportEndpointSnapshot.isSupported {
            failureReason = frontendHostSnapshot.isSupported
                ? nil
                : frontendHostSnapshot.failureReason
            capabilities = frontendHostSnapshot.isSupported
                ? transportEndpointSnapshot.capabilities
                    .union(frontendHostSnapshot.capabilities)
                : transportEndpointSnapshot.capabilities
        } else {
            failureReason = transportEndpointSnapshot.failureReason
                ?? frontendHostSnapshot.failureReason
            capabilities = []
        }

        return WITransportSupportSnapshot(
            availability: isSupported ? .supported : .unsupported,
            backendKind: .macOSRemoteInspector,
            capabilities: capabilities,
            failureReason: failureReason
        )
    }
}

#if os(macOS)
@MainActor
final class WITransportRemoteInspectorFrontendHost: WITransportFrontendHost {
    private let configuration: WITransportConfiguration
    private var host: NSObject?
    private var fatalFailureHandler: ((String) -> Void)?

    init(configuration: WITransportConfiguration) {
        self.configuration = configuration
    }

    var supportSnapshot: WITransportSupportSnapshot {
        let failureReason = WITransportRemoteInspectorHostAvailabilityFailureReason()
        let isSupported = failureReason == nil
        return WITransportSupportSnapshot(
            availability: isSupported ? .supported : .unsupported,
            backendKind: .macOSRemoteInspector,
            capabilities: isSupported ? [.remoteFrontendHosting] : [],
            failureReason: failureReason
        )
    }

    func attach(
        to webView: WKWebView,
        backendMessageHandler: @escaping (String) -> Void,
        fatalFailureHandler: @escaping (String) -> Void
    ) async throws {
        let snapshot = supportSnapshot
        guard snapshot.isSupported else {
            throw WITransportError.unsupported(snapshot.failureReason ?? "The remote inspector frontend host is unavailable.")
        }

        guard let host = WITransportCreateRemoteInspectorHost(webView) else {
            throw WITransportError.attachFailed("Failed to create the remote inspector frontend host.")
        }

        WITransportRemoteInspectorHostSetBackendMessageHandler(host) { (message: String) in
            backendMessageHandler(message)
        }
        WITransportRemoteInspectorHostSetFatalFailureHandler(host) { [logHandler = configuration.logHandler] (message: String) in
            logHandler?("[WebInspectorTransport] remote frontend host fatal failure: \(message)")
            fatalFailureHandler(message)
        }

        var error: NSError?
        guard unsafe WITransportRemoteInspectorHostAttach(host, &error) else {
            WITransportRemoteInspectorHostDetach(host)
            throw WITransportError.attachFailed(error?.localizedDescription ?? "Failed to attach the remote inspector frontend host.")
        }

        self.host = host
        self.fatalFailureHandler = fatalFailureHandler

        do {
            try await settleHiddenWindowState(for: host)
        } catch {
            detach()
            throw error
        }

    }

    func mirrorBackendMessage(_ message: String) {
        guard let host else {
            return
        }

        var error: NSError?
        guard unsafe WITransportRemoteInspectorHostSendMessageToFrontend(host, message, &error) else {
            let reason = error?.localizedDescription ?? "Failed to mirror a backend message into the remote inspector frontend host."
            configuration.logHandler?("[WebInspectorTransport] remote frontend host mirror failed: \(reason)")
            fatalFailureHandler?(reason)
            return
        }
    }

    func detach() {
        if let host {
            WITransportRemoteInspectorHostDetach(host)
        }
        host = nil
        fatalFailureHandler = nil
    }

    private func settleHiddenWindowState(for host: NSObject) async throws {
        for _ in 0..<8 {
            WITransportRemoteInspectorHostPerformVisibilityMaintenance(host)
            if !WITransportRemoteInspectorHostIsWindowVisible(host)
                && !WITransportRemoteInspectorHostIsWindowKey(host)
                && !WITransportRemoteInspectorHostIsWindowMain(host) {
                try await Task.sleep(for: .milliseconds(50))
                continue
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        WITransportRemoteInspectorHostPerformVisibilityMaintenance(host)
        guard !WITransportRemoteInspectorHostIsWindowVisible(host)
                && !WITransportRemoteInspectorHostIsWindowKey(host)
                && !WITransportRemoteInspectorHostIsWindowMain(host) else {
            throw WITransportError.attachFailed("The remote inspector window could not be kept hidden.")
        }
    }
}
#endif
