import Foundation
import WebKit
@unsafe @preconcurrency import WebInspectorTransportObjCShim

@MainActor
public final class WITransportSession {
    public enum State: String, Sendable {
        case detached
        case attaching
        case attached
    }

    public private(set) var state: State = .detached
    public private(set) var supportSnapshot: WITransportSupportSnapshot

    private let configuration: WITransportConfiguration
    private weak var webView: WKWebView?
    private var bridge: WITransportBridge?
    private var router: WITransportMessageRouter?

    public init(configuration: WITransportConfiguration = .init()) {
        self.configuration = configuration
        self.supportSnapshot = WITransportWebKitLocalSymbolResolver.currentAttachResolution().supportSnapshot
    }

    deinit {
        bridge?.detach()
    }

    public var root: WITransportCommandChannel {
        makeChannel(scope: .root)
    }

    public var page: WITransportCommandChannel {
        makeChannel(scope: .page)
    }

    public func attach(to webView: WKWebView) async throws {
        guard state == .detached else {
            throw WITransportError.alreadyAttached
        }

        let resolution = WITransportWebKitLocalSymbolResolver.currentAttachResolution()
        supportSnapshot = resolution.supportSnapshot
        guard resolution.supportSnapshot.isSupported else {
            throw WITransportError.unsupported(resolution.failureReason ?? "connect/disconnect symbol missing")
        }

        state = .attaching
        self.webView = webView

        let bridge = WITransportBridge(webView: webView)
        let bridgeReference = BridgeReference(bridge)
        let router = WITransportMessageRouter(configuration: configuration)

        self.bridge = bridge
        self.router = router

        bridge.rootMessageHandler = { [router] message in
            Task {
                await router.handleIncomingRootMessage(message)
            }
        }
        bridge.pageMessageHandler = { [router] message, targetIdentifier in
            Task {
                await router.handleIncomingPageMessage(message, targetIdentifier: targetIdentifier)
            }
        }
        bridge.fatalFailureHandler = { [logHandler = configuration.logHandler] message in
            logHandler?("[WebInspectorTransport] transport fatal failure: \(message)")
        }

        do {
            try bridge.attach(
                withConnectFrontendAddress: resolution.connectFrontendAddress,
                disconnectFrontendAddress: resolution.disconnectFrontendAddress
            )
            await router.connect(
                rootDispatcher: { [bridgeReference] message in
                    try await MainActor.run {
                        guard let bridge = bridgeReference.bridge else {
                            throw WITransportError.transportClosed
                        }
                        try bridge.sendRootJSONString(message)
                    }
                },
                pageDispatcher: { [bridgeReference] message, targetIdentifier, outerIdentifier in
                    try await MainActor.run {
                        guard let bridge = bridgeReference.bridge else {
                            throw WITransportError.transportClosed
                        }
                        try bridge.sendPageJSONString(
                            message,
                            targetIdentifier: targetIdentifier,
                            outerIdentifier: NSNumber(value: outerIdentifier)
                        )
                    }
                }
            )

            try await router.waitForPageTarget(timeout: configuration.responseTimeout)
            state = .attached
            log("attached")
        } catch {
            await router.disconnect()
            bridge.detach()
            self.bridge = nil
            self.router = nil
            self.webView = nil
            state = .detached

            let reason = (error as? WITransportError)?.errorDescription ?? error.localizedDescription
            if case .unsupported = (error as? WITransportError) {
                throw error
            }
            if let error = error as? WITransportError {
                throw error
            }
            throw WITransportError.attachFailed(reason)
        }
    }

    public func detach() {
        guard state != .detached else {
            return
        }

        bridge?.detach()
        if let router {
            Task {
                await router.disconnect()
            }
        }
        bridge = nil
        router = nil
        webView = nil
        state = .detached
        log("detached")
    }
}

private extension WITransportSession {
    func makeChannel(scope: WITransportTargetScope) -> WITransportCommandChannel {
        let sessionReference = SessionReference(self)
        return WITransportCommandChannel(
            scope: scope,
            sender: { [sessionReference] scope, method, parametersData in
                guard let session = await MainActor.run(body: { sessionReference.session }) else {
                    throw WITransportError.transportClosed
                }
                return try await session.send(scope: scope, method: method, parametersData: parametersData)
            },
            subscriber: { [sessionReference] scope, methods, bufferingLimit in
                guard let session = await MainActor.run(body: { sessionReference.session }) else {
                    return AsyncStream { continuation in
                        continuation.finish()
                    }
                }
                return await session.eventStream(scope: scope, methods: methods, bufferingLimit: bufferingLimit)
            }
        )
    }

    func send(scope: WITransportTargetScope, method: String, parametersData: Data?) async throws -> Data {
        guard let router else {
            throw WITransportError.notAttached
        }
        return try await router.send(scope: scope, method: method, parametersData: parametersData)
    }

    func eventStream(
        scope: WITransportTargetScope,
        methods: Set<String>?,
        bufferingLimit: Int?
    ) async -> AsyncStream<WITransportEventEnvelope> {
        guard let router else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return await router.events(scope: scope, methods: methods, bufferingLimit: bufferingLimit)
    }

    func log(_ message: String) {
        configuration.logHandler?("[WebInspectorTransport] \(message)")
    }
}

private final class BridgeReference: @unchecked Sendable {
    weak var bridge: WITransportBridge?

    init(_ bridge: WITransportBridge) {
        self.bridge = bridge
    }
}

private final class SessionReference: @unchecked Sendable {
    weak var session: WITransportSession?

    init(_ session: WITransportSession) {
        self.session = session
    }
}
