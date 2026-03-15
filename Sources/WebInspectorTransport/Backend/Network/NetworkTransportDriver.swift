import Foundation
import OSLog
import WebInspectorCore
import WebKit

@MainActor
final class NetworkTransportDriver: WINetworkBackend, InspectorTransportCapabilityProviding {
    weak var webView: WKWebView?
    let store = NetworkStore()

    private let logger = Logger(subsystem: "WebInspectorKit", category: "NetworkTransportDriver")
    private let eventTranslator = NetworkEventTranslator()
    private let transportClient = NetworkTransportClient()
    private let ingressCoordinator: NetworkIngressCoordinator
    private let resolver = NetworkTimelineResolver()
    private let initialSupport: WIBackendSupport

    private var loggingMode: NetworkLoggingMode = .buffering

    init(
        registry: WISharedTransportRegistry = .shared,
        initialSupport: WIBackendSupport = WITransportSession().supportSnapshot.backendSupport
    ) {
        self.ingressCoordinator = NetworkIngressCoordinator(registry: registry)
        self.initialSupport = initialSupport
        store.setRecording(true)
    }

    isolated deinit {
        tearDownLifecycle()
    }

    package var inspectorTransportCapabilities: Set<InspectorTransportCapability> {
        ingressCoordinator.inspectorTransportCapabilities
    }

    package var inspectorTransportSupportSnapshot: WITransportSupportSnapshot? {
        ingressCoordinator.supportSnapshot
    }

    var support: WIBackendSupport {
        ingressCoordinator.supportSnapshot?.backendSupport ?? initialSupport
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
        guard webView !== newWebView || ingressCoordinator.currentLease == nil else {
            return
        }

        let previousWebView = webView
        ingressCoordinator.detach()
        webView = newWebView

        if previousWebView !== newWebView {
            resetStoreState()
        }

        guard let newWebView else {
            return
        }

        startIngressAttachment(for: newWebView)
    }

    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?) {
        if let modeBeforeDetach {
            loggingMode = modeBeforeDetach
            store.setRecording(modeBeforeDetach != .stopped)
            if modeBeforeDetach == .stopped {
                resetStoreState()
            }
        }

        ingressCoordinator.detach()
        webView = nil
    }

    func clearNetworkLogs() {
        resetStoreState()
    }

    package func waitForAttachForTesting() async {
        await ingressCoordinator.waitForAttachForTesting()
    }

    package func fetchBodyResult(
        locator: NetworkDeferredBodyLocator,
        role: NetworkBody.Role
    ) async -> WINetworkBodyFetchResult {
        guard let lease = ingressCoordinator.currentLease else {
            return .agentUnavailable
        }
        return await transportClient.fetchBodyResult(
            using: lease,
            locator: locator,
            role: role
        )
    }
}

extension NetworkTransportDriver {
    func prepareForNavigationReconnect() {
        ingressCoordinator.prepareForNavigationReconnect()
    }

    func resumeAfterNavigationReconnect() {
        guard let webView else {
            return
        }
        let bootstrapContextID = UUID()
        resolver.begin(contextID: bootstrapContextID)
        ingressCoordinator.resumeAfterNavigationReconnect(
            to: webView,
            onEnvelope: { [weak self] envelope in
                self?.handle(envelope)
            },
            onAttachWork: { [weak self] lease in
                guard let self else {
                    return
                }
                try await self.bootstrapExistingResources(using: lease, contextID: bootstrapContextID)
                self.finishBootstrap(contextID: bootstrapContextID)
            },
            onFailure: { [weak self] error, lease in
                guard let self else {
                    return
                }
                self.finishBootstrap(contextID: bootstrapContextID)
                guard self.shouldLogAttachFailure(error, lease: lease) else {
                    return
                }
                self.logger.error("network transport attach failed: \(error.localizedDescription, privacy: .public)")
            }
        )
    }
}

private extension NetworkTransportDriver {
    func tearDownLifecycle() {
        ingressCoordinator.detach()
    }

    func startIngressAttachment(for webView: WKWebView) {
        let bootstrapContextID = UUID()
        resolver.begin(contextID: bootstrapContextID)
        ingressCoordinator.attach(
            to: webView,
            onEnvelope: { [weak self] envelope in
                self?.handle(envelope)
            },
            onAttachWork: { [weak self] lease in
                guard let self else {
                    return
                }
                try await self.bootstrapExistingResources(using: lease, contextID: bootstrapContextID)
                self.finishBootstrap(contextID: bootstrapContextID)
            },
            onFailure: { [weak self] error, lease in
                guard let self else {
                    return
                }
                self.finishBootstrap(contextID: bootstrapContextID)
                guard self.shouldLogAttachFailure(error, lease: lease) else {
                    return
                }
                self.logger.error("network transport attach failed: \(error.localizedDescription, privacy: .public)")
            }
        )
    }

    func bootstrapExistingResources(
        using lease: WISharedTransportRegistry.Lease,
        contextID: UUID
    ) async throws {
        let load = try await loadBootstrapResources(using: lease)
        guard resolver.matches(contextID: contextID) else {
            return
        }
        resolver.applyBootstrapLoad(load, into: store)
    }

    func finishBootstrap(contextID: UUID) {
        guard resolver.matches(contextID: contextID) else {
            return
        }

        resolver.finish { [weak self] event in
            self?.replay(event)
        }
    }

    func shouldLogAttachFailure(_ error: Error, lease: WISharedTransportRegistry.Lease) -> Bool {
        if lease !== self.ingressCoordinator.currentLease {
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

    func resetStoreState() {
        store.reset()
        resolver.reset()
    }

    func handle(_ envelope: WITransportEventEnvelope) {
        guard let event = eventTranslator.translate(envelope) else {
            return
        }
        if resolver.buffersPendingEvents {
            resolver.buffer(event)
            return
        }
        replay(event)
    }

    func replay(_ event: NetworkPendingEvent) {
        switch event {
        case .requestWillBeSent(let params, let targetIdentifier):
            handleRequestWillBeSent(params, targetIdentifier: targetIdentifier)
        case .responseReceived(let params, let targetIdentifier):
            handleResponseReceived(params, targetIdentifier: targetIdentifier)
        case .loadingFinished(let params, let targetIdentifier):
            handleLoadingFinished(params, targetIdentifier: targetIdentifier)
        case .loadingFailed(let params, let targetIdentifier):
            handleLoadingFailed(params, targetIdentifier: targetIdentifier)
        case .webSocketCreated(let params, let targetIdentifier):
            handleWebSocketCreated(params, targetIdentifier: targetIdentifier)
        case .webSocketHandshakeRequest(let params, let targetIdentifier):
            handleWebSocketHandshakeRequest(params, targetIdentifier: targetIdentifier)
        case .webSocketHandshakeResponseReceived(let params, let targetIdentifier):
            handleWebSocketHandshakeResponseReceived(params, targetIdentifier: targetIdentifier)
        case .webSocketFrameReceived(let params, let targetIdentifier):
            handleWebSocketFrame(params, direction: .incoming, targetIdentifier: targetIdentifier)
        case .webSocketFrameSent(let params, let targetIdentifier):
            handleWebSocketFrame(params, direction: .outgoing, targetIdentifier: targetIdentifier)
        case .webSocketFrameError(let params, let targetIdentifier):
            handleWebSocketFrameError(params, targetIdentifier: targetIdentifier)
        case .webSocketClosed(let params, let targetIdentifier):
            handleWebSocketClosed(params, targetIdentifier: targetIdentifier)
        }
    }

    func handleRequestWillBeSent(_ params: RequestWillBeSentParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let normalizedMethod = params.request.method.uppercased()

        if let redirectResponse = params.redirectResponse,
           let previousRequestID = resolver.resolveEvent(
                sessionID: sessionID,
                rawRequestID: params.requestId,
                url: redirectResponse.url,
                requestType: params.type,
                targetIdentifier: normalizedScopeID(targetIdentifier),
                store: store
           ) {
            store.applyEvent(
                makeResponseEvent(
                    sessionID: sessionID,
                    requestID: previousRequestID,
                    timestamp: params.timestamp,
                    requestType: params.type,
                    response: redirectResponse
                )
            )
            store.applyEvent(
                makeLoadingFinishedEvent(
                    sessionID: sessionID,
                    requestID: previousRequestID,
                    rawRequestID: params.requestId,
                    timestamp: params.timestamp,
                    metrics: nil,
                    includeResponseBodyPlaceholder: false,
                    targetIdentifier: normalizedScopeID(targetIdentifier)
                )
            )
            resolver.complete(sessionID: sessionID, rawRequestID: params.requestId)
        }

        let requestID = resolver.resolveRequestStart(
            sessionID: sessionID,
            rawRequestID: params.requestId,
            url: params.request.url,
            requestType: params.type,
            targetIdentifier: normalizedScopeID(targetIdentifier),
            store: store
        )

        store.applyEvent(
            HTTPNetworkEvent(
                kind: .requestWillBeSent,
                sessionID: sessionID,
                requestID: requestID,
                url: params.request.url,
                method: normalizedMethod,
                statusCode: nil,
                statusText: nil,
                mimeType: nil,
                requestHeaders: NetworkHeaders(dictionary: params.request.headers),
                responseHeaders: NetworkHeaders(),
                startTimeSeconds: params.timestamp,
                endTimeSeconds: nil,
                wallTimeSeconds: params.walltime,
                encodedBodyLength: nil,
                decodedBodySize: nil,
                errorDescription: nil,
                requestType: params.type,
                requestBody: makeRequestBody(
                    postData: params.request.postData,
                    method: params.request.method,
                    requestID: params.requestId,
                    targetIdentifier: normalizedScopeID(targetIdentifier)
                ),
                requestBodyBytesSent: params.request.postData?.utf8.count,
                responseBody: nil,
                blockedCookies: []
            )
        )
    }

    func handleResponseReceived(_ params: ResponseReceivedParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = resolver.resolveEvent(
            sessionID: sessionID,
            rawRequestID: params.requestId,
            url: params.response.url,
            requestType: params.type,
            targetIdentifier: normalizedScopeID(targetIdentifier),
            store: store
        ) else {
            return
        }

        store.applyEvent(
            makeResponseEvent(
                sessionID: sessionID,
                requestID: requestID,
                timestamp: params.timestamp,
                requestType: params.type,
                response: params.response
            )
        )
    }

    func handleLoadingFinished(_ params: LoadingFinishedParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = resolver.resolveEvent(
            sessionID: sessionID,
            rawRequestID: params.requestId,
            url: nil,
            requestType: nil,
            targetIdentifier: normalizedScopeID(targetIdentifier),
            store: store
        ) else {
            return
        }
        let entry = store.entry(requestID: requestID, sessionID: sessionID)
        let knownTargetIdentifiers = resolver.knownTargetIdentifiers(
            sessionID: sessionID,
            rawRequestID: params.requestId
        )
        resolver.complete(sessionID: sessionID, rawRequestID: params.requestId)

        store.applyEvent(
            makeLoadingFinishedEvent(
                sessionID: sessionID,
                requestID: requestID,
                rawRequestID: params.requestId,
                timestamp: params.timestamp,
                metrics: params.metrics,
                includeResponseBodyPlaceholder: entry?.responseBody?.hasDeferredContent != true,
                targetIdentifier: knownTargetIdentifiers?.response ?? normalizedScopeID(targetIdentifier)
            )
        )
    }

    func handleLoadingFailed(_ params: LoadingFailedParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = resolver.resolveEvent(
            sessionID: sessionID,
            rawRequestID: params.requestId,
            url: nil,
            requestType: nil,
            targetIdentifier: normalizedScopeID(targetIdentifier),
            store: store
        ) else {
            return
        }
        resolver.complete(sessionID: sessionID, rawRequestID: params.requestId)

        store.applyEvent(
            HTTPNetworkEvent(
                kind: .loadingFailed,
                sessionID: sessionID,
                requestID: requestID,
                url: nil,
                method: nil,
                statusCode: nil,
                statusText: nil,
                mimeType: nil,
                requestHeaders: NetworkHeaders(),
                responseHeaders: NetworkHeaders(),
                startTimeSeconds: params.timestamp,
                endTimeSeconds: params.timestamp,
                wallTimeSeconds: nil,
                encodedBodyLength: nil,
                decodedBodySize: nil,
                errorDescription: params.errorText,
                requestType: nil,
                requestBody: nil,
                requestBodyBytesSent: nil,
                responseBody: nil,
                blockedCookies: []
            )
        )
    }

    func handleWebSocketCreated(_ params: WebSocketCreatedParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let requestID = resolver.resolveRequestStart(
            sessionID: sessionID,
            rawRequestID: params.requestId,
            url: params.url,
            requestType: "websocket",
            targetIdentifier: normalizedScopeID(targetIdentifier),
            store: store
        )

        store.applyEvent(
            WSNetworkEvent(
                kind: .created,
                sessionID: sessionID,
                requestID: requestID,
                url: params.url,
                startTimeSeconds: params.timestamp ?? 0,
                endTimeSeconds: nil,
                wallTimeSeconds: nil,
                framePayload: nil,
                framePayloadIsBase64: false,
                framePayloadSize: nil,
                frameDirection: nil,
                frameOpcode: nil,
                framePayloadTruncated: false,
                statusCode: nil,
                statusText: nil,
                closeCode: nil,
                closeReason: nil,
                errorDescription: nil,
                requestHeaders: NetworkHeaders(),
                closeWasClean: nil
            )
        )
    }

    func handleWebSocketHandshakeRequest(
        _ params: WebSocketHandshakeRequestParams,
        targetIdentifier: String?
    ) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = resolver.resolveWebSocketRequestID(
            sessionID: sessionID,
            rawRequestID: params.requestId
        ) else {
            return
        }

        store.applyEvent(
            WSNetworkEvent(
                kind: .handshakeRequest,
                sessionID: sessionID,
                requestID: requestID,
                url: nil,
                startTimeSeconds: params.timestamp,
                endTimeSeconds: nil,
                wallTimeSeconds: params.walltime,
                framePayload: nil,
                framePayloadIsBase64: false,
                framePayloadSize: nil,
                frameDirection: nil,
                frameOpcode: nil,
                framePayloadTruncated: false,
                statusCode: nil,
                statusText: nil,
                closeCode: nil,
                closeReason: nil,
                errorDescription: nil,
                requestHeaders: NetworkHeaders(dictionary: params.request.headers),
                closeWasClean: nil
            )
        )
    }

    func handleWebSocketHandshakeResponseReceived(
        _ params: WebSocketHandshakeResponseReceivedParams,
        targetIdentifier: String?
    ) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = resolver.resolveWebSocketRequestID(
            sessionID: sessionID,
            rawRequestID: params.requestId
        ) else {
            return
        }

        store.applyEvent(
            WSNetworkEvent(
                kind: .handshake,
                sessionID: sessionID,
                requestID: requestID,
                url: nil,
                startTimeSeconds: params.timestamp,
                endTimeSeconds: params.timestamp,
                wallTimeSeconds: nil,
                framePayload: nil,
                framePayloadIsBase64: false,
                framePayloadSize: nil,
                frameDirection: nil,
                frameOpcode: nil,
                framePayloadTruncated: false,
                statusCode: params.response.status,
                statusText: params.response.statusText,
                closeCode: nil,
                closeReason: nil,
                errorDescription: nil,
                requestHeaders: NetworkHeaders(dictionary: params.response.headers),
                closeWasClean: nil
            )
        )
    }

    func handleWebSocketFrame(
        _ params: WebSocketFrameParams,
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

        store.applyEvent(
            WSNetworkEvent(
                kind: .frame,
                sessionID: sessionID,
                requestID: requestID,
                url: nil,
                startTimeSeconds: params.timestamp,
                endTimeSeconds: params.timestamp,
                wallTimeSeconds: nil,
                framePayload: params.response.payloadData,
                framePayloadIsBase64: params.response.opcode == 2,
                framePayloadSize: params.response.payloadLength,
                frameDirection: direction,
                frameOpcode: params.response.opcode,
                framePayloadTruncated: false,
                statusCode: nil,
                statusText: nil,
                closeCode: nil,
                closeReason: nil,
                errorDescription: nil,
                requestHeaders: NetworkHeaders(),
                closeWasClean: nil
            )
        )
    }

    func handleWebSocketFrameError(_ params: WebSocketFrameErrorParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = resolver.resolveWebSocketRequestID(
            sessionID: sessionID,
            rawRequestID: params.requestId
        ) else {
            return
        }
        resolver.complete(sessionID: sessionID, rawRequestID: params.requestId)

        store.applyEvent(
            WSNetworkEvent(
                kind: .frameError,
                sessionID: sessionID,
                requestID: requestID,
                url: nil,
                startTimeSeconds: params.timestamp,
                endTimeSeconds: params.timestamp,
                wallTimeSeconds: nil,
                framePayload: nil,
                framePayloadIsBase64: false,
                framePayloadSize: nil,
                frameDirection: nil,
                frameOpcode: nil,
                framePayloadTruncated: false,
                statusCode: nil,
                statusText: nil,
                closeCode: nil,
                closeReason: nil,
                errorDescription: params.errorMessage,
                requestHeaders: NetworkHeaders(),
                closeWasClean: nil
            )
        )
    }

    func handleWebSocketClosed(_ params: WebSocketClosedParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = resolver.resolveWebSocketRequestID(
            sessionID: sessionID,
            rawRequestID: params.requestId
        ) else {
            return
        }
        resolver.complete(sessionID: sessionID, rawRequestID: params.requestId)

        store.applyEvent(
            WSNetworkEvent(
                kind: .closed,
                sessionID: sessionID,
                requestID: requestID,
                url: nil,
                startTimeSeconds: params.timestamp,
                endTimeSeconds: params.timestamp,
                wallTimeSeconds: nil,
                framePayload: nil,
                framePayloadIsBase64: false,
                framePayloadSize: nil,
                frameDirection: nil,
                frameOpcode: nil,
                framePayloadTruncated: false,
                statusCode: nil,
                statusText: nil,
                closeCode: nil,
                closeReason: nil,
                errorDescription: nil,
                requestHeaders: NetworkHeaders(),
                closeWasClean: nil
            )
        )
    }

    func makeResponseEvent(
        sessionID: String,
        requestID: Int,
        timestamp: TimeInterval,
        requestType: String?,
        response: ResponsePayload
    ) -> HTTPNetworkEvent {
        HTTPNetworkEvent(
            kind: .responseReceived,
            sessionID: sessionID,
            requestID: requestID,
            url: response.url,
            method: nil,
            statusCode: response.status,
            statusText: response.statusText,
            mimeType: response.mimeType,
            requestHeaders: NetworkHeaders(),
            responseHeaders: NetworkHeaders(dictionary: response.headers),
            startTimeSeconds: timestamp,
            endTimeSeconds: nil,
            wallTimeSeconds: nil,
            encodedBodyLength: nil,
            decodedBodySize: nil,
            errorDescription: nil,
            requestType: requestType,
            requestBody: nil,
            requestBodyBytesSent: nil,
            responseBody: nil,
            blockedCookies: []
        )
    }

    func makeLoadingFinishedEvent(
        sessionID: String,
        requestID: Int,
        rawRequestID: String,
        timestamp: TimeInterval,
        metrics: LoadingFinishedParams.Metrics?,
        includeResponseBodyPlaceholder: Bool,
        targetIdentifier: String?
    ) -> HTTPNetworkEvent {
        HTTPNetworkEvent(
            kind: .loadingFinished,
            sessionID: sessionID,
            requestID: requestID,
            url: nil,
            method: nil,
            statusCode: nil,
            statusText: nil,
            mimeType: nil,
            requestHeaders: NetworkHeaders(),
            responseHeaders: NetworkHeaders(),
            startTimeSeconds: timestamp,
            endTimeSeconds: timestamp,
            wallTimeSeconds: nil,
            encodedBodyLength: metrics?.responseBodyBytesReceived,
            decodedBodySize: metrics?.responseBodyDecodedSize,
            errorDescription: nil,
            requestType: nil,
            requestBody: nil,
            requestBodyBytesSent: metrics?.requestBodyBytesSent,
            responseBody: includeResponseBodyPlaceholder
                ? NetworkBody(
                    kind: .text,
                    preview: nil,
                    full: nil,
                    size: metrics?.responseBodyDecodedSize,
                    isBase64Encoded: false,
                    isTruncated: true,
                    summary: nil,
                    deferredLocator: .networkRequest(id: rawRequestID, targetIdentifier: targetIdentifier),
                    formEntries: [],
                    fetchState: .inline,
                    role: .response
                )
                : nil,
            blockedCookies: []
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
        using lease: WISharedTransportRegistry.Lease
    ) async throws -> NetworkBootstrapLoad {
        try await transportClient.loadBootstrapResources(
            using: lease,
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
}
