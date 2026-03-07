import Foundation
import WebKit

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
    private let backendFactory: @MainActor (WITransportConfiguration) -> any WITransportPlatformBackend
    private weak var webView: WKWebView?
    private var backend: (any WITransportPlatformBackend)?
    private var router: WITransportMessageRouter?

    public convenience init(configuration: WITransportConfiguration = .init()) {
        self.init(configuration: configuration, backendFactory: WITransportPlatformBackendFactory.makeDefaultBackend)
    }

    init(
        configuration: WITransportConfiguration = .init(),
        backendFactory: @escaping @MainActor (WITransportConfiguration) -> any WITransportPlatformBackend
    ) {
        self.configuration = configuration
        self.backendFactory = backendFactory
        self.supportSnapshot = backendFactory(configuration).supportSnapshot
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

        let backend = backendFactory(configuration)
        supportSnapshot = backend.supportSnapshot
        guard backend.supportSnapshot.isSupported else {
            throw WITransportError.unsupported(backend.supportSnapshot.failureReason ?? "inspector backend unavailable")
        }

        state = .attaching
        self.webView = webView

        let router = WITransportMessageRouter(configuration: configuration)

        self.backend = backend
        self.router = router

        do {
            await router.connect(
                rootDispatcher: { [sessionReference = SessionReference(self)] message in
                    try await MainActor.run {
                        guard let session = sessionReference.session,
                              let backend = session.backend else {
                            throw WITransportError.transportClosed
                        }
                        try backend.sendRootMessage(message)
                    }
                },
                pageDispatcher: { [sessionReference = SessionReference(self)] message, targetIdentifier, outerIdentifier in
                    try await MainActor.run {
                        guard let session = sessionReference.session,
                              let backend = session.backend else {
                            throw WITransportError.transportClosed
                        }
                        try backend.sendPageMessage(message, targetIdentifier: targetIdentifier, outerIdentifier: outerIdentifier)
                    }
                }
            )
            try await backend.attach(
                to: webView,
                messageHandlers: WITransportBackendMessageHandlers(
                    handleRootMessage: { [router] message in
                        Task {
                            await router.handleIncomingRootMessage(message)
                        }
                    },
                    handlePageMessage: { [router] message, targetIdentifier in
                        Task {
                            await router.handleIncomingPageMessage(message, targetIdentifier: targetIdentifier)
                        }
                    },
                    handleFatalFailure: { [sessionReference = SessionReference(self)] message in
                        Task { @MainActor in
                            sessionReference.session?.handleBackendFatalFailure(message)
                        }
                    }
                )
            )
            supportSnapshot = backend.supportSnapshot

            try await router.waitForPageTarget(timeout: configuration.responseTimeout)
            guard state == .attaching, self.backend != nil, self.router != nil else {
                throw WITransportError.transportClosed
            }
            state = .attached
            log("attached")
        } catch {
            await router.disconnect()
            backend.detach()
            self.backend = nil
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

        backend?.detach()
        if let router {
            Task {
                await router.disconnect()
            }
        }
        backend = nil
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
        guard let router, let backend else {
            throw WITransportError.notAttached
        }

        if let compatibilityResponse = backend.compatibilityResponse(scope: scope, method: method) {
            return compatibilityResponse
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

    func handleBackendFatalFailure(_ message: String) {
        log("transport fatal failure: \(message)")
        guard state != .detached else {
            return
        }

        let router = self.router
        backend?.detach()
        backend = nil
        self.router = nil
        webView = nil
        state = .detached

        if let router {
            Task {
                await router.disconnect()
            }
        }
    }
}

private final class SessionReference: @unchecked Sendable {
    weak var session: WITransportSession?

    init(_ session: WITransportSession) {
        self.session = session
    }
}
