import Foundation
import OSLog
import WebInspectorEngine
import WebKit

@MainActor
final class NetworkTransportDriver: WINetworkBackend, InspectorTransportCapabilityProviding {
    weak var webView: WKWebView?
    let store = NetworkStore()

    private let logger = Logger(subsystem: "WebInspectorKit", category: "NetworkTransportDriver")
    private let decoder = JSONDecoder()
    private let transportClient = NetworkTransportClient()
    private let transportSessionFactory: @MainActor () -> WITransportSession
    private let resolver = NetworkTimelineResolver()
    private let initialSupport: WIBackendSupport
    private var deferredEnvelopesByTargetIdentifier: [String: [WITransportEventEnvelope]] = [:]
    private var transportSession: WITransportSession?
    private var attachTask: Task<Void, Never>?
    private var pageEventTask: Task<Void, Never>?

    private var loggingMode: NetworkLoggingMode = .buffering

    init(
        transportSessionFactory: @escaping @MainActor () -> WITransportSession = { WITransportSession() },
        initialSupport: WIBackendSupport = WITransportSession().supportSnapshot.backendSupport
    ) {
        self.transportSessionFactory = transportSessionFactory
        self.initialSupport = initialSupport
        store.setRecording(true)
    }

    isolated deinit {
        tearDownLifecycle()
    }

    package var inspectorTransportCapabilities: Set<InspectorTransportCapability> {
        guard let supportSnapshot = transportSession?.supportSnapshot else {
            return []
        }

        var mapped: Set<InspectorTransportCapability> = []
        if supportSnapshot.capabilities.contains(.domDomain) {
            mapped.insert(.domDomain)
        }
        if supportSnapshot.capabilities.contains(.networkDomain) {
            mapped.insert(.networkDomain)
        }
        if supportSnapshot.capabilities.contains(.pageTargetRouting) {
            mapped.insert(.pageTargetRouting)
        }
        if supportSnapshot.capabilities.contains(.networkBootstrapSnapshot) {
            mapped.insert(.networkBootstrapSnapshot)
        }
        return mapped
    }

    package var inspectorTransportSupportSnapshot: WITransportSupportSnapshot? {
        transportSession?.supportSnapshot
    }

    var support: WIBackendSupport {
        transportSession?.supportSnapshot.backendSupport ?? initialSupport
    }

    package func supportsDeferredLoading(for role: NetworkBody.Role) -> Bool {
        switch role {
        case .request, .response:
            true
        }
    }

    func setMode(_ mode: NetworkLoggingMode) {
        loggingMode = mode
        store.setRecording(mode != .stopped)
        if mode == .stopped {
            resetStoreState()
        }
    }

    func attachPageWebView(_ newWebView: WKWebView?) {
        guard webView !== newWebView || transportSession == nil else {
            return
        }

        let previousWebView = webView
        detachTransportSession()
        webView = newWebView

        if previousWebView !== newWebView {
            resetStoreState()
        }

        guard let newWebView else {
            return
        }

        startTransportSessionAttachment(for: newWebView)
    }

    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?) {
        if let modeBeforeDetach {
            loggingMode = modeBeforeDetach
            store.setRecording(modeBeforeDetach != .stopped)
            if modeBeforeDetach == .stopped {
                resetStoreState()
            }
        }

        detachTransportSession()
        webView = nil
    }

    func clearNetworkLogs() {
        resetStoreState()
    }

    package func waitForAttachForTesting() async {
        await attachTask?.value
    }

    package func fetchBodyResult(
        locator: NetworkDeferredBodyLocator,
        role: NetworkBody.Role
    ) async -> WINetworkBodyFetchResult {
        guard let transportSession else {
            return .agentUnavailable
        }
        return await transportClient.fetchBodyResult(
            using: transportSession,
            locator: locator,
            role: role
        )
    }
}

extension NetworkTransportDriver {
    func prepareForNavigationReconnect() {
        resolver.clearCommittedTargetTransitions()
        deferredEnvelopesByTargetIdentifier.removeAll(keepingCapacity: true)
        detachTransportSession()
    }

    func resumeAfterNavigationReconnect(to webView: WKWebView) {
        self.webView = webView
        startTransportSessionAttachment(for: webView)
    }
}

private extension NetworkTransportDriver {
    func tearDownLifecycle() {
        detachTransportSession()
    }

    func detachTransportSession() {
        attachTask?.cancel()
        attachTask = nil
        pageEventTask?.cancel()
        pageEventTask = nil
        transportSession?.detach()
        transportSession = nil
    }

    func startTransportSessionAttachment(for webView: WKWebView) {
        detachTransportSession()
        let bootstrapContextID = UUID()
        resolver.begin(contextID: bootstrapContextID)
        let transportSession = transportSessionFactory()
        self.transportSession = transportSession

        attachTask = Task { @MainActor [weak self, weak transportSession] in
            guard let self, let transportSession else {
                return
            }

            do {
                try await transportSession.attach(to: webView)
                self.startPageEventLoop(using: transportSession)
                try await self.enableNetworkIfNeeded(for: transportSession.currentPageTargetIdentifier(), session: transportSession)
                try await self.bootstrapExistingResources(using: transportSession, contextID: bootstrapContextID)
                self.finishBootstrap(contextID: bootstrapContextID)
            } catch {
                self.finishBootstrap(contextID: bootstrapContextID)
                guard self.shouldLogAttachFailure(error, session: transportSession) else {
                    if self.transportSession === transportSession {
                        self.pageEventTask?.cancel()
                        self.pageEventTask = nil
                        self.transportSession = nil
                    }
                    return
                }
                self.logger.error("network transport attach failed: \(error.localizedDescription, privacy: .public)")
                if self.transportSession === transportSession {
                    self.pageEventTask?.cancel()
                    self.pageEventTask = nil
                    transportSession.detach()
                    self.transportSession = nil
                }
            }

            self.attachTask = nil
        }
    }

    func startPageEventLoop(using transportSession: WITransportSession) {
        pageEventTask?.cancel()
        pageEventTask = Task { @MainActor [weak self, weak transportSession] in
            guard let self, let transportSession else {
                return
            }

            while self.transportSession === transportSession,
                  let envelope = await transportSession.nextPageEvent() {
                await self.handlePageEvent(envelope, session: transportSession)
            }
            if self.transportSession === transportSession {
                self.pageEventTask = nil
            }
        }
    }

    func bootstrapExistingResources(
        using transportSession: WITransportSession,
        contextID: UUID
    ) async throws {
        let load = try await loadBootstrapResources(using: transportSession)
        guard resolver.matches(contextID: contextID) else {
            return
        }
        resolver.applyBootstrapLoad(load, into: store)
    }

    func finishBootstrap(contextID: UUID) {
        guard resolver.matches(contextID: contextID) else {
            return
        }

        resolver.finish { [weak self] envelope in
            self?.process(envelope)
        }
    }

    func shouldLogAttachFailure(_ error: Error, session: WITransportSession) -> Bool {
        if session !== self.transportSession {
            return false
        }
        if error is CancellationError {
            return false
        }
        if let transportError = error as? WITransportError,
           case .transportClosed = transportError {
            return false
        }
        return true
    }

    func handlePageEvent(_ envelope: WITransportEventEnvelope, session: WITransportSession) async {
        switch envelope.method {
        case "Target.targetCreated", "Target.didCommitProvisionalTarget":
            try? await enableNetworkIfNeeded(for: envelope.targetIdentifier, session: session)
        case "Target.targetDestroyed":
            try? await enableNetworkIfNeeded(for: session.currentPageTargetIdentifier(), session: session)
        default:
            break
        }
        handle(envelope)
    }

    func enableNetworkIfNeeded(for targetIdentifier: String?, session: WITransportSession) async throws {
        _ = try await session.sendPageData(
            method: WITransportMethod.Network.enable,
            targetIdentifier: targetIdentifier
        )
    }

    func resetStoreState() {
        store.reset()
        resolver.reset()
        deferredEnvelopesByTargetIdentifier.removeAll(keepingCapacity: true)
    }

    func handle(_ envelope: WITransportEventEnvelope) {
        if resolver.buffersPendingEnvelopes {
            resolver.buffer(envelope)
            return
        }
        process(envelope)
    }

    func process(_ envelope: WITransportEventEnvelope) {
        switch envelope.method {
        case "Target.didCommitProvisionalTarget":
            guard let params = decodeParams(NetworkWire.Transport.Event.TargetDidCommitProvisionalTarget.self, from: envelope) else {
                return
            }
            handleTargetDidCommitProvisionalTarget(params)
        case "Target.targetDestroyed":
            guard let params = decodeParams(NetworkWire.Transport.Event.TargetDestroyed.self, from: envelope) else {
                return
            }
            handleTargetDestroyed(params)
        case "Network.requestWillBeSent":
            guard let params = decodeParams(NetworkWire.Transport.Event.RequestWillBeSent.self, from: envelope) else {
                return
            }
            if shouldDeferRequestStart(params, targetIdentifier: envelope.targetIdentifier) {
                deferEnvelope(envelope, targetIdentifier: envelope.targetIdentifier)
                return
            }
            handleRequestWillBeSent(params, targetIdentifier: envelope.targetIdentifier)
        case "Network.responseReceived":
            guard let params = decodeParams(NetworkWire.Transport.Event.ResponseReceived.self, from: envelope) else {
                return
            }
            if shouldDeferContinuation(
                rawRequestID: params.requestId,
                url: params.response.url,
                requestType: params.type,
                targetIdentifier: envelope.targetIdentifier
            ) {
                deferEnvelope(envelope, targetIdentifier: envelope.targetIdentifier)
                return
            }
            handleResponseReceived(params, targetIdentifier: envelope.targetIdentifier)
        case "Network.loadingFinished":
            guard let params = decodeParams(NetworkWire.Transport.Event.LoadingFinished.self, from: envelope) else {
                return
            }
            if shouldDeferContinuation(
                rawRequestID: params.requestId,
                url: nil,
                requestType: nil,
                targetIdentifier: envelope.targetIdentifier
            ) {
                deferEnvelope(envelope, targetIdentifier: envelope.targetIdentifier)
                return
            }
            handleLoadingFinished(params, targetIdentifier: envelope.targetIdentifier)
        case "Network.loadingFailed":
            guard let params = decodeParams(NetworkWire.Transport.Event.LoadingFailed.self, from: envelope) else {
                return
            }
            if shouldDeferContinuation(
                rawRequestID: params.requestId,
                url: nil,
                requestType: nil,
                targetIdentifier: envelope.targetIdentifier
            ) {
                deferEnvelope(envelope, targetIdentifier: envelope.targetIdentifier)
                return
            }
            handleLoadingFailed(params, targetIdentifier: envelope.targetIdentifier)
        case "Network.webSocketCreated":
            guard let params = decodeParams(NetworkWire.Transport.Event.WebSocketCreated.self, from: envelope) else {
                return
            }
            handleWebSocketCreated(params, targetIdentifier: envelope.targetIdentifier)
        case "Network.webSocketWillSendHandshakeRequest":
            guard let params = decodeParams(NetworkWire.Transport.Event.WebSocketHandshakeRequest.self, from: envelope) else {
                return
            }
            handleWebSocketHandshakeRequest(params, targetIdentifier: envelope.targetIdentifier)
        case "Network.webSocketHandshakeResponseReceived":
            guard let params = decodeParams(NetworkWire.Transport.Event.WebSocketHandshakeResponseReceived.self, from: envelope) else {
                return
            }
            handleWebSocketHandshakeResponseReceived(params, targetIdentifier: envelope.targetIdentifier)
        case "Network.webSocketFrameReceived":
            guard let params = decodeParams(NetworkWire.Transport.Event.WebSocketFrame.self, from: envelope) else {
                return
            }
            handleWebSocketFrame(params, direction: .incoming, targetIdentifier: envelope.targetIdentifier)
        case "Network.webSocketFrameSent":
            guard let params = decodeParams(NetworkWire.Transport.Event.WebSocketFrame.self, from: envelope) else {
                return
            }
            handleWebSocketFrame(params, direction: .outgoing, targetIdentifier: envelope.targetIdentifier)
        case "Network.webSocketFrameError":
            guard let params = decodeParams(NetworkWire.Transport.Event.WebSocketFrameError.self, from: envelope) else {
                return
            }
            handleWebSocketFrameError(params, targetIdentifier: envelope.targetIdentifier)
        case "Network.webSocketClosed":
            guard let params = decodeParams(NetworkWire.Transport.Event.WebSocketClosed.self, from: envelope) else {
                return
            }
            handleWebSocketClosed(params, targetIdentifier: envelope.targetIdentifier)
        default:
            return
        }
    }

    func decodeParams<T: Decodable>(
        _ type: T.Type,
        from envelope: WITransportEventEnvelope
    ) -> T? {
        try? decoder.decode(T.self, from: envelope.paramsData)
    }

    func handleTargetDidCommitProvisionalTarget(_ params: NetworkWire.Transport.Event.TargetDidCommitProvisionalTarget) {
        resolver.recordCommittedTargetTransition(
            from: params.oldTargetId,
            to: params.newTargetId
        )
        replayDeferredEnvelopes(for: params.newTargetId)
    }

    func handleTargetDestroyed(_ params: NetworkWire.Transport.Event.TargetDestroyed) {
        resolver.recordCommittedTargetDestroyed(identifier: params.targetId)
        deferredEnvelopesByTargetIdentifier.removeValue(forKey: params.targetId)
    }

    func handleRequestWillBeSent(_ params: NetworkWire.Transport.Event.RequestWillBeSent, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let normalizedMethod = params.request.method.uppercased()
        let normalizedTargetIdentifier = normalizedScopeID(targetIdentifier)

        if let redirectResponse = params.redirectResponse,
           let previousRequestID = resolver.resolveEvent(
                sessionID: sessionID,
                rawRequestID: params.requestId,
                url: redirectResponse.url,
                requestType: params.type,
                targetIdentifier: normalizedTargetIdentifier,
                store: store
           ) {
            store.apply(
                .responseReceived(
                    .init(
                        requestID: previousRequestID,
                        response: .init(
                            statusCode: redirectResponse.status,
                            statusText: redirectResponse.statusText,
                            mimeType: redirectResponse.mimeType,
                            headers: NetworkHeaders(dictionary: redirectResponse.headers),
                            body: nil,
                            blockedCookies: [],
                            errorDescription: nil
                        ),
                        requestType: params.type,
                        timestamp: params.timestamp
                    )
                ),
                sessionID: sessionID,
            )
            store.apply(
                .completed(
                    .init(
                        requestID: previousRequestID,
                        response: .init(
                            statusCode: nil,
                            statusText: "",
                            mimeType: nil,
                            headers: NetworkHeaders(),
                            body: nil,
                            blockedCookies: [],
                            errorDescription: nil
                        ),
                        requestType: nil,
                        timestamp: params.timestamp,
                        encodedBodyLength: nil,
                        decodedBodyLength: nil
                    )
                ),
                sessionID: sessionID,
            )
            resolver.complete(sessionID: sessionID, rawRequestID: params.requestId)
        }

        let requestID = resolver.resolveRequestStart(
            sessionID: sessionID,
            rawRequestID: params.requestId,
            url: params.request.url,
            requestType: params.type,
            targetIdentifier: normalizedTargetIdentifier,
            store: store
        )

        store.apply(
            .requestStarted(
                .init(
                    requestID: requestID,
                    request: .init(
                        url: params.request.url,
                        method: normalizedMethod,
                        headers: NetworkHeaders(dictionary: params.request.headers),
                        body: makeRequestBody(
                            postData: params.request.postData,
                            method: params.request.method,
                            requestID: params.requestId,
                            targetIdentifier: normalizedTargetIdentifier
                        ),
                        bodyBytesSent: params.request.postData?.utf8.count,
                        type: params.type,
                        wallTime: params.walltime
                    ),
                    timestamp: params.timestamp
                )
            ),
            sessionID: sessionID,
        )
    }

    func handleResponseReceived(
        _ params: NetworkWire.Transport.Event.ResponseReceived,
        targetIdentifier: String?
    ) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let normalizedTargetIdentifier = normalizedScopeID(targetIdentifier)
        guard let requestID = resolver.resolveEvent(
            sessionID: sessionID,
            rawRequestID: params.requestId,
            url: params.response.url,
            requestType: params.type,
            targetIdentifier: normalizedTargetIdentifier,
            store: store
        ) else {
            return
        }

        store.apply(
            .responseReceived(
                .init(
                    requestID: requestID,
                    response: .init(
                        statusCode: params.response.status,
                        statusText: params.response.statusText,
                        mimeType: params.response.mimeType,
                        headers: NetworkHeaders(dictionary: params.response.headers),
                        body: nil,
                        blockedCookies: [],
                        errorDescription: nil
                    ),
                    requestType: params.type,
                    timestamp: params.timestamp
                )
            ),
            sessionID: sessionID,
        )
    }

    func handleLoadingFinished(
        _ params: NetworkWire.Transport.Event.LoadingFinished,
        targetIdentifier: String?
    ) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let normalizedTargetIdentifier = normalizedScopeID(targetIdentifier)
        guard let requestID = resolver.resolveEvent(
            sessionID: sessionID,
            rawRequestID: params.requestId,
            url: nil,
            requestType: nil,
            targetIdentifier: normalizedTargetIdentifier,
            store: store
        ) else {
            return
        }

        let responseTargetIdentifier = resolver.knownTargetIdentifiers(
            sessionID: sessionID,
            rawRequestID: params.requestId
        )?.response ?? normalizedTargetIdentifier
        let shouldIncludeResponseBodyPlaceholder = store.entry(requestID: requestID, sessionID: sessionID)?.responseBody?.hasDeferredContent != true

        resolver.complete(sessionID: sessionID, rawRequestID: params.requestId)

        store.apply(
            .completed(
                .init(
                    requestID: requestID,
                    response: .init(
                        statusCode: nil,
                        statusText: "",
                        mimeType: nil,
                        headers: NetworkHeaders(),
                        body: shouldIncludeResponseBodyPlaceholder
                            ? makeResponseBodyPlaceholder(
                                rawRequestID: params.requestId,
                                decodedBodySize: params.metrics?.responseBodyDecodedSize,
                                targetIdentifier: responseTargetIdentifier
                            )
                            : nil,
                        blockedCookies: [],
                        errorDescription: nil
                    ),
                    requestType: nil,
                    timestamp: params.timestamp,
                    encodedBodyLength: params.metrics?.responseBodyBytesReceived,
                    decodedBodyLength: params.metrics?.responseBodyDecodedSize
                )
            ),
            sessionID: sessionID,
        )
    }

    func handleLoadingFailed(_ params: NetworkWire.Transport.Event.LoadingFailed, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let normalizedTargetIdentifier = normalizedScopeID(targetIdentifier)
        guard let requestID = resolver.resolveEvent(
            sessionID: sessionID,
            rawRequestID: params.requestId,
            url: nil,
            requestType: nil,
            targetIdentifier: normalizedTargetIdentifier,
            store: store
        ) else {
            return
        }

        resolver.complete(sessionID: sessionID, rawRequestID: params.requestId)

        store.apply(
            .failed(
                .init(
                    requestID: requestID,
                    response: .init(
                        statusCode: nil,
                        statusText: "",
                        mimeType: nil,
                        headers: NetworkHeaders(),
                        body: nil,
                        blockedCookies: [],
                        errorDescription: params.errorText
                    ),
                    requestType: nil,
                    timestamp: params.timestamp
                )
            ),
            sessionID: sessionID,
        )
    }

    func handleWebSocketCreated(_ params: NetworkWire.Transport.Event.WebSocketCreated, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let requestID = resolver.resolveRequestStart(
            sessionID: sessionID,
            rawRequestID: params.requestId,
            url: params.url,
            requestType: "websocket",
            targetIdentifier: normalizedScopeID(targetIdentifier),
            store: store
        )

        store.apply(
            .webSocketOpened(
                .init(
                    requestID: requestID,
                    url: params.url,
                    timestamp: params.timestamp ?? 0,
                    wallTime: nil
                )
            ),
            sessionID: sessionID,
        )
    }

    func handleWebSocketHandshakeRequest(
        _ params: NetworkWire.Transport.Event.WebSocketHandshakeRequest,
        targetIdentifier: String?
    ) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = resolver.resolveWebSocketRequestID(
            sessionID: sessionID,
            rawRequestID: params.requestId
        ) else {
            return
        }

        store.apply(
            .webSocketHandshake(
                .init(
                    requestID: requestID,
                    requestHeaders: NetworkHeaders(dictionary: params.request.headers),
                    statusCode: nil,
                    statusText: nil
                )
            ),
            sessionID: sessionID,
        )
    }

    func handleWebSocketHandshakeResponseReceived(
        _ params: NetworkWire.Transport.Event.WebSocketHandshakeResponseReceived,
        targetIdentifier: String?
    ) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = resolver.resolveWebSocketRequestID(
            sessionID: sessionID,
            rawRequestID: params.requestId
        ) else {
            return
        }

        store.apply(
            .webSocketHandshake(
                .init(
                    requestID: requestID,
                    requestHeaders: nil,
                    statusCode: params.response.status,
                    statusText: params.response.statusText
                )
            ),
            sessionID: sessionID,
        )
    }

    func handleWebSocketFrame(
        _ params: NetworkWire.Transport.Event.WebSocketFrame,
        direction: NetworkWebSocketFrame.Direction,
        targetIdentifier: String?
    ) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = resolver.resolveWebSocketRequestID(
            sessionID: sessionID,
            rawRequestID: params.requestId
        ) else {
            return
        }

        store.apply(
            .webSocketFrameAdded(
                .init(
                    requestID: requestID,
                    frame: .init(
                        direction: direction,
                        opcode: params.response.opcode,
                        payload: params.response.payloadData,
                        payloadIsBase64: params.response.opcode == 2,
                        payloadSize: params.response.payloadLength,
                        payloadTruncated: false,
                        timestamp: params.timestamp
                    )
                )
            ),
            sessionID: sessionID,
        )
    }

    func handleWebSocketFrameError(_ params: NetworkWire.Transport.Event.WebSocketFrameError, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = resolver.resolveWebSocketRequestID(
            sessionID: sessionID,
            rawRequestID: params.requestId
        ) else {
            return
        }

        resolver.complete(sessionID: sessionID, rawRequestID: params.requestId)

        store.apply(
            .webSocketClosed(
                .init(
                    requestID: requestID,
                    timestamp: params.timestamp,
                    statusCode: nil,
                    statusText: nil,
                    closeCode: nil,
                    closeReason: nil,
                    closeWasClean: nil,
                    errorDescription: params.errorMessage,
                    failed: true
                )
            ),
            sessionID: sessionID,
        )
    }

    func handleWebSocketClosed(_ params: NetworkWire.Transport.Event.WebSocketClosed, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = resolver.resolveWebSocketRequestID(
            sessionID: sessionID,
            rawRequestID: params.requestId
        ) else {
            return
        }

        resolver.complete(sessionID: sessionID, rawRequestID: params.requestId)

        store.apply(
            .webSocketClosed(
                .init(
                    requestID: requestID,
                    timestamp: params.timestamp,
                    statusCode: nil,
                    statusText: nil,
                    closeCode: nil,
                    closeReason: nil,
                    closeWasClean: nil,
                    errorDescription: nil,
                    failed: false
                )
            ),
            sessionID: sessionID,
        )
    }

    func makeResponseBodyPlaceholder(
        rawRequestID: String,
        decodedBodySize: Int?,
        targetIdentifier: String?
    ) -> NetworkBody {
        NetworkBody(
            kind: .text,
            preview: nil,
            full: nil,
            size: decodedBodySize,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            deferredLocator: .networkRequest(id: rawRequestID, targetIdentifier: targetIdentifier),
            formEntries: [],
            fetchState: .inline,
            role: .response
        )
    }

    func makeRequestBody(
        postData: String?,
        method: String,
        requestID: String,
        targetIdentifier: String?
    ) -> NetworkBody? {
        if let postData, !postData.isEmpty {
            return NetworkBody(
                kind: .text,
                preview: postData,
                full: postData,
                size: postData.utf8.count,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                formEntries: [],
                fetchState: .full,
                role: .request
            )
        }

        guard requestMethodMayCarryBody(method) else {
            return nil
        }

        return NetworkBody(
            kind: .text,
            preview: nil,
            full: nil,
            size: nil,
            isBase64Encoded: false,
            isTruncated: true,
            summary: nil,
            deferredLocator: .networkRequest(id: requestID, targetIdentifier: targetIdentifier),
            formEntries: [],
            fetchState: .inline,
            role: .request
        )
    }

    func requestMethodMayCarryBody(_ method: String) -> Bool {
        switch method.uppercased() {
        case "GET", "HEAD":
            false
        default:
            true
        }
    }

    func loadBootstrapResources(
        using transportSession: WITransportSession
    ) async throws -> NetworkBootstrapLoad {
        try await transportClient.loadBootstrapResources(
            using: transportSession,
            allocateRequestID: { [resolver] in
                resolver.allocateCanonicalRequestID()
            },
            defaultSessionID: { [weak self] in
                self?.sessionIdentifier(for: $0) ?? "page"
            },
            normalizeScopeID: { [weak self] in
                self?.normalizedScopeID($0)
            },
            logFailure: { [weak self] message in
                self?.logger.debug("\(message, privacy: .public)")
            }
        )
    }

    func sessionIdentifier(for targetIdentifier: String?) -> String {
        targetIdentifier ?? "page"
    }

    func normalizedScopeID(_ scopeID: String?) -> String? {
        guard let scopeID, !scopeID.isEmpty else {
            return nil
        }
        return scopeID
    }

    func shouldDeferRequestStart(
        _ params: NetworkWire.Transport.Event.RequestWillBeSent,
        targetIdentifier: String?
    ) -> Bool {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        return resolver.hasPendingUncommittedTargetCandidate(
            sessionID: sessionID,
            rawRequestID: params.requestId,
            url: params.request.url,
            requestType: params.type,
            targetIdentifier: normalizedScopeID(targetIdentifier),
            allowLiveBindings: false
        )
    }

    func shouldDeferContinuation(
        rawRequestID: String,
        url: String?,
        requestType: String?,
        targetIdentifier: String?
    ) -> Bool {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        return resolver.hasPendingUncommittedTargetCandidate(
            sessionID: sessionID,
            rawRequestID: rawRequestID,
            url: url,
            requestType: requestType,
            targetIdentifier: normalizedScopeID(targetIdentifier),
            allowLiveBindings: true
        )
    }

    func deferEnvelope(_ envelope: WITransportEventEnvelope, targetIdentifier: String?) {
        guard let targetIdentifier = normalizedScopeID(targetIdentifier) else {
            return
        }
        deferredEnvelopesByTargetIdentifier[targetIdentifier, default: []].append(envelope)
    }

    func replayDeferredEnvelopes(for targetIdentifier: String) {
        guard let deferred = deferredEnvelopesByTargetIdentifier.removeValue(forKey: targetIdentifier) else {
            return
        }

        for envelope in deferred {
            process(envelope)
        }
    }
}
