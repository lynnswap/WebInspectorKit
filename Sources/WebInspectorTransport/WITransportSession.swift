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
    private let routerClock: any Clock<Duration>
    package var onStateTransitionForTesting: (@MainActor (State) -> Void)?
    private weak var webView: WKWebView?
    private var originalInspectability: Bool?
    private var backend: (any WITransportPlatformBackend)?
    private var router: WITransportMessageRouter?

    public convenience init(configuration: WITransportConfiguration = .init()) {
        self.init(configuration: configuration, backendFactory: WITransportPlatformBackendFactory.makeDefaultBackend)
    }

    init(
        configuration: WITransportConfiguration = .init(),
        backendFactory: @escaping @MainActor (WITransportConfiguration) -> any WITransportPlatformBackend,
        routerClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.configuration = configuration
        self.backendFactory = backendFactory
        self.routerClock = routerClock
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

        let originalInspectability = prepareInspectability(for: webView)
        self.originalInspectability = originalInspectability

        let backend = backendFactory(configuration)
        supportSnapshot = backend.supportSnapshot
        guard backend.supportSnapshot.isSupported else {
            restoreInspectabilityIfNeeded(on: webView, originalValue: originalInspectability)
            self.originalInspectability = nil
            throw WITransportError.unsupported(backend.supportSnapshot.failureReason ?? "inspector backend unavailable")
        }

        transition(to: .attaching)
        self.webView = webView

        let router = WITransportMessageRouter(
            configuration: configuration,
            clock: routerClock
        )

        self.backend = backend
        self.router = router
        let inboundMessageGroup = DispatchGroup()

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
                    handleRootMessage: { [router] message, parsedMessage in
                        let parsedPayload = parsedMessage.map(WITransportPayload.object)
                        inboundMessageGroup.enter()
                        Task {
                            await router.handleIncomingRootMessage(
                                message,
                                parsedPayload: parsedPayload
                            )
                            inboundMessageGroup.leave()
                        }
                    },
                    handlePageMessage: { [router] message, parsedMessage, targetIdentifier in
                        let parsedPayload = parsedMessage.map(WITransportPayload.object)
                        inboundMessageGroup.enter()
                        Task {
                            await router.handleIncomingPageMessage(
                                message,
                                parsedPayload: parsedPayload,
                                targetIdentifier: targetIdentifier
                            )
                            inboundMessageGroup.leave()
                        }
                    },
                    handleFatalFailure: { [sessionReference = SessionReference(self)] message in
                        Task { @MainActor in
                            sessionReference.session?.handleBackendFatalFailure(message)
                        }
                    },
                    waitForPendingMessagesForTesting: {
                        inboundMessageGroup.wait()
                    }
                )
            )
            supportSnapshot = backend.supportSnapshot

            try await router.waitForPageTarget(timeout: configuration.responseTimeout)
            guard state == .attaching, self.backend != nil, self.router != nil else {
                throw WITransportError.transportClosed
            }
            transition(to: .attached)
            log("attached")
        } catch {
            await router.disconnect()
            backend.detach()
            self.backend = nil
            self.router = nil
            self.webView = nil
            transition(to: .detached)
            restoreInspectabilityIfNeeded(on: webView, originalValue: originalInspectability)
            self.originalInspectability = nil

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
        restoreInspectabilityIfNeeded()
        backend = nil
        router = nil
        webView = nil
        transition(to: .detached)
        log("detached")
    }
}

package extension WITransportSession {
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

    func pageTargetChangeStream(
        bufferingLimit: Int? = nil
    ) async -> AsyncStream<WITransportPageTargetChange> {
        guard let router else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return await router.pageTargetChanges(bufferingLimit: bufferingLimit)
    }

    func pageTargetLifecycleStream(
        bufferingLimit: Int? = nil
    ) async -> AsyncStream<WITransportPageTargetLifecycleEvent> {
        guard let router else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
        return await router.pageTargetLifecycles(bufferingLimit: bufferingLimit)
    }

    func currentPageTargetIdentifier() async -> String? {
        guard let router else {
            return nil
        }
        return await router.currentPageTargetIdentifierSnapshot()
    }

    func pageTargetIdentifiers() async -> [String] {
        guard let router else {
            return []
        }
        return await router.pageTargetIdentifiersSnapshot()
    }

    func sendPageCapturingCurrentTarget<C: WITransportPageCommand>(
        _ command: sending C
    ) async throws -> (targetIdentifier: String, response: C.Response) {
        let parametersPayload = try encodeTransportParameters(command.parameters, emptyType: C.Parameters.self)

        guard let router, let backend else {
            throw WITransportError.notAttached
        }

        if let compatibilityResponse = backend.compatibilityResponse(scope: .page, method: C.method) {
            guard let targetIdentifier = await router.currentPageTargetIdentifierSnapshot() else {
                throw WITransportError.pageTargetUnavailable
            }
            let response = try decodeTransportResponse(C.Response.self, from: compatibilityResponse)
            return (targetIdentifier, response)
        }

        let result = try await router.sendPageCommandCapturingCurrentTarget(
            method: C.method,
            parametersPayload: parametersPayload
        )
        let response = try decodeTransportResponse(C.Response.self, from: result.payload)
        return (result.targetIdentifier, response)
    }

    func sendPage<C: WITransportPageCommand>(
        _ command: sending C,
        targetIdentifier: String
    ) async throws -> C.Response {
        let parametersPayload = try encodeTransportParameters(command.parameters, emptyType: C.Parameters.self)
        let payload = try await send(
            scope: .page,
            method: C.method,
            parametersPayload: parametersPayload,
            targetIdentifierOverride: targetIdentifier
        )
        return try decodeTransportResponse(C.Response.self, from: payload)
    }
}

private extension WITransportSession {
    func makeChannel(scope: WITransportTargetScope) -> WITransportCommandChannel {
        let sessionReference = SessionReference(self)
        return WITransportCommandChannel(
            scope: scope,
            sender: { [sessionReference] scope, method, parametersPayload in
                guard let session = await MainActor.run(body: { sessionReference.session }) else {
                    throw WITransportError.transportClosed
                }
                return try await session.send(
                    scope: scope,
                    method: method,
                    parametersPayload: parametersPayload,
                    targetIdentifierOverride: nil
                )
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

    func send(scope: WITransportTargetScope, method: String, parametersData: Data?) async throws -> WITransportPayload {
        try await send(
            scope: scope,
            method: method,
            parametersPayload: parametersData.map(WITransportPayload.data),
            targetIdentifierOverride: nil
        )
    }

    func send(
        scope: WITransportTargetScope,
        method: String,
        parametersData: Data?,
        targetIdentifierOverride: String?
    ) async throws -> WITransportPayload {
        try await send(
            scope: scope,
            method: method,
            parametersPayload: parametersData.map(WITransportPayload.data),
            targetIdentifierOverride: targetIdentifierOverride
        )
    }

    func send(
        scope: WITransportTargetScope,
        method: String,
        parametersPayload: WITransportPayload?,
        targetIdentifierOverride: String?
    ) async throws -> WITransportPayload {
        guard let router, let backend else {
            throw WITransportError.notAttached
        }

        if let compatibilityResponse = backend.compatibilityResponse(scope: scope, method: method) {
            return compatibilityResponse
        }

        return try await router.send(
            scope: scope,
            method: method,
            parametersPayload: parametersPayload,
            targetIdentifierOverride: targetIdentifierOverride
        )
    }

    func log(_ message: String) {
        configuration.logHandler?("[WebInspectorTransport] \(message)")
    }

    func prepareInspectability(for webView: WKWebView) -> Bool? {
        guard #available(iOS 16.4, macOS 13.3, *) else {
            return nil
        }

        let originalInspectability = webView.isInspectable
        webView.isInspectable = true
        return originalInspectability
    }

    func restoreInspectabilityIfNeeded() {
        guard let webView else {
            originalInspectability = nil
            return
        }
        restoreInspectabilityIfNeeded(on: webView, originalValue: originalInspectability)
    }

    func restoreInspectabilityIfNeeded(on webView: WKWebView, originalValue: Bool?) {
        guard #available(iOS 16.4, macOS 13.3, *), let originalValue else {
            return
        }

        webView.isInspectable = originalValue
    }

    func handleBackendFatalFailure(_ message: String) {
        log("transport fatal failure: \(message)")
        guard state != .detached else {
            return
        }

        let router = self.router
        backend?.detach()
        restoreInspectabilityIfNeeded()
        backend = nil
        self.router = nil
        webView = nil
        transition(to: .detached)
        originalInspectability = nil

        if let router {
            Task {
                await router.disconnect()
            }
        }
    }

    func encodeTransportParameters<Parameters: Encodable>(
        _ parameters: Parameters,
        emptyType: Parameters.Type
    ) throws -> WITransportPayload? {
        if emptyType == WIEmptyTransportParameters.self {
            return nil
        }

        if let fastParameters = parameters as? any WITransportObjectEncodable {
            let object = fastParameters.wiTransportObject()
            if transportIsEmptyJSONObject(object) {
                return nil
            }
            return .object(object)
        }

        do {
            let data = try JSONEncoder().encode(parameters)
            if data == Data("{}".utf8) {
                return nil
            }
            return .data(data)
        } catch {
            throw WITransportError.invalidCommandEncoding(error.localizedDescription)
        }
    }

    func decodeTransportResponse<Response: Decodable>(
        _ type: Response.Type,
        from payload: WITransportPayload
    ) throws -> Response {
        do {
            return try payload.decode(Response.self)
        } catch {
            throw WITransportError.invalidResponse(error.localizedDescription)
        }
    }

    func transition(to newState: State) {
        state = newState
        onStateTransitionForTesting?(newState)
    }
}

private final class SessionReference: @unchecked Sendable {
    weak var session: WITransportSession?

    init(_ session: WITransportSession) {
        self.session = session
    }
}
