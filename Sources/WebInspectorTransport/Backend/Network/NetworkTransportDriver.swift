import Foundation
import OSLog
import WebInspectorCore
import WebKit

@MainActor
final class NetworkTransportDriver: WINetworkBackend, InspectorTransportCapabilityProviding {
    weak var webView: WKWebView?
    let store = NetworkStore()

    private let registry: WISharedTransportRegistry
    private let logger = Logger(subsystem: "WebInspectorKit", category: "NetworkTransportDriver")
    private let eventConsumerIdentifier = UUID()
    private let resolver = NetworkTimelineResolver()
    private let initialSupport: WIBackendSupport

    private var loggingMode: NetworkLoggingMode = .buffering
    private var lease: WISharedTransportRegistry.Lease?
    private var attachTask: Task<Void, Never>?

    init(
        registry: WISharedTransportRegistry = .shared,
        initialSupport: WIBackendSupport = WITransportSession().supportSnapshot.backendSupport
    ) {
        self.registry = registry
        self.initialSupport = initialSupport
        store.setRecording(true)
    }

    isolated deinit {
        tearDownLifecycle()
    }

    package var inspectorTransportCapabilities: Set<InspectorTransportCapability> {
        lease?.inspectorTransportCapabilities ?? []
    }

    package var inspectorTransportSupportSnapshot: WITransportSupportSnapshot? {
        lease?.supportSnapshot
    }

    var support: WIBackendSupport {
        lease?.supportSnapshot.backendSupport ?? initialSupport
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
        guard webView !== newWebView || lease == nil else {
            return
        }

        let previousWebView = webView
        releaseLease()
        webView = newWebView

        if previousWebView !== newWebView {
            resetStoreState()
        }

        guard let newWebView else {
            return
        }

        startLeaseAttachment(for: newWebView)
    }

    func detachPageWebView(preparing modeBeforeDetach: NetworkLoggingMode?) {
        attachTask?.cancel()
        attachTask = nil

        if let modeBeforeDetach {
            loggingMode = modeBeforeDetach
            store.setRecording(modeBeforeDetach != .stopped)
            if modeBeforeDetach == .stopped {
                resetStoreState()
            }
        }

        releaseLease()
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
        guard let lease else {
            return .agentUnavailable
        }

        do {
            try await lease.ensureAttached()
            try await lease.ensureNetworkEventIngress()
            switch locator {
            case .networkRequest(let requestID):
                switch role {
                case .request:
                    let response = try await lease.sendPage(
                        WITransportCommands.Network.GetRequestPostData(requestId: requestID)
                    )
                    guard !response.postData.isEmpty else {
                        return .bodyUnavailable
                    }
                    return .fetched(
                        NetworkBody(
                            kind: .text,
                            preview: nil,
                            full: response.postData,
                            size: response.postData.utf8.count,
                            isBase64Encoded: false,
                            isTruncated: false,
                            summary: nil,
                            formEntries: [],
                            fetchState: .full,
                            role: .request
                        )
                    )
                case .response:
                    let response = try await lease.sendPage(
                        WITransportCommands.Network.GetResponseBody(requestId: requestID)
                    )
                    return .fetched(
                        NetworkBody(
                            kind: response.base64Encoded ? .binary : .text,
                            preview: nil,
                            full: response.body,
                            size: nil,
                            isBase64Encoded: response.base64Encoded,
                            isTruncated: false,
                            summary: nil,
                            formEntries: [],
                            fetchState: .full,
                            role: .response
                        )
                    )
                }
            case .pageResource(let targetIdentifier, let frameID, let url):
                guard role == .response else {
                    return .bodyUnavailable
                }
                let response = try await lease.sendPage(
                    WITransportCommands.Page.GetResourceContent(frameId: frameID, url: url),
                    targetIdentifier: targetIdentifier
                )
                return .fetched(
                    NetworkBody(
                        kind: response.base64Encoded ? .binary : .text,
                        preview: nil,
                        full: response.content,
                        size: nil,
                        isBase64Encoded: response.base64Encoded,
                        isTruncated: false,
                        summary: nil,
                        formEntries: [],
                        fetchState: .full,
                        role: .response
                    )
                )
            case .opaqueHandle:
                return .bodyUnavailable
            }
        } catch let error as WITransportError {
            switch error {
            case .unsupported, .alreadyAttached, .notAttached, .attachFailed, .pageTargetUnavailable, .transportClosed:
                return .agentUnavailable
            case .remoteError, .requestTimedOut, .invalidResponse, .invalidCommandEncoding, .invalidChannelScope:
                return .bodyUnavailable
            }
        } catch {
            return .bodyUnavailable
        }
    }
}

extension NetworkTransportDriver {
    func prepareForNavigationReconnect() {
        attachTask?.cancel()
        attachTask = nil
        releaseLease()
    }

    func resumeAfterNavigationReconnect() {
        guard let webView else {
            return
        }
        guard lease == nil else {
            return
        }

        startLeaseAttachment(for: webView)
    }
}

private extension NetworkTransportDriver {
    func tearDownLifecycle() {
        attachTask?.cancel()
        attachTask = nil
        releaseLease()
    }

    func startLeaseAttachment(for webView: WKWebView) {
        attachTask?.cancel()
        attachTask = nil
        releaseLease()

        let lease = registry.acquireLease(for: webView)
        self.lease = lease
        let bootstrapContextID = UUID()
        resolver.begin(contextID: bootstrapContextID)
        lease.addNetworkConsumer(eventConsumerIdentifier) { [weak self] envelope in
            self?.handle(envelope)
        }

        attachTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await lease.ensureAttached()
                try await lease.ensureNetworkEventIngress()
                try await self.bootstrapExistingResources(using: lease, contextID: bootstrapContextID)
                self.finishBootstrap(contextID: bootstrapContextID)
            } catch is CancellationError {
                self.finishBootstrap(contextID: bootstrapContextID)
            } catch {
                self.finishBootstrap(contextID: bootstrapContextID)
                guard self.shouldLogAttachFailure(error, lease: lease) else {
                    self.attachTask = nil
                    return
                }
                self.logger.error("network transport attach failed: \(error.localizedDescription, privacy: .public)")
            }

            self.attachTask = nil
        }
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

    func releaseLease() {
        lease?.removeNetworkConsumer(eventConsumerIdentifier)
        lease?.release()
        lease = nil
    }

    func shouldLogAttachFailure(_ error: Error, lease: WISharedTransportRegistry.Lease) -> Bool {
        if lease !== self.lease {
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
        guard let event = decodePendingEvent(from: envelope) else {
            return
        }
        if resolver.buffersPendingEvents {
            resolver.buffer(event)
            return
        }
        replay(event)
    }

    func decodePendingEvent(from envelope: WITransportEventEnvelope) -> NetworkPendingEvent? {
        switch envelope.method {
        case "Network.requestWillBeSent":
            guard let params = try? JSONDecoder().decode(RequestWillBeSentParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .requestWillBeSent(params, envelope.targetIdentifier)
        case "Network.responseReceived":
            guard let params = try? JSONDecoder().decode(ResponseReceivedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .responseReceived(params, envelope.targetIdentifier)
        case "Network.loadingFinished":
            guard let params = try? JSONDecoder().decode(LoadingFinishedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .loadingFinished(params, envelope.targetIdentifier)
        case "Network.loadingFailed":
            guard let params = try? JSONDecoder().decode(LoadingFailedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .loadingFailed(params, envelope.targetIdentifier)
        case "Network.webSocketCreated":
            guard let params = try? JSONDecoder().decode(WebSocketCreatedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketCreated(params, envelope.targetIdentifier)
        case "Network.webSocketWillSendHandshakeRequest":
            guard let params = try? JSONDecoder().decode(WebSocketHandshakeRequestParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketHandshakeRequest(params, envelope.targetIdentifier)
        case "Network.webSocketHandshakeResponseReceived":
            guard let params = try? JSONDecoder().decode(WebSocketHandshakeResponseReceivedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketHandshakeResponseReceived(params, envelope.targetIdentifier)
        case "Network.webSocketFrameReceived":
            guard let params = try? JSONDecoder().decode(WebSocketFrameParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketFrameReceived(params, envelope.targetIdentifier)
        case "Network.webSocketFrameSent":
            guard let params = try? JSONDecoder().decode(WebSocketFrameParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketFrameSent(params, envelope.targetIdentifier)
        case "Network.webSocketFrameError":
            guard let params = try? JSONDecoder().decode(WebSocketFrameErrorParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketFrameError(params, envelope.targetIdentifier)
        case "Network.webSocketClosed":
            guard let params = try? JSONDecoder().decode(WebSocketClosedParams.self, from: envelope.paramsData) else {
                return nil
            }
            return .webSocketClosed(params, envelope.targetIdentifier)
        default:
            return nil
        }
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
                url: params.request.url,
                requestType: params.type,
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
                    includeResponseBodyPlaceholder: false
                )
            )
            resolver.complete(sessionID: sessionID, rawRequestID: params.requestId)
        }

        let requestID = resolver.resolveRequestStart(
            sessionID: sessionID,
            rawRequestID: params.requestId,
            url: params.request.url,
            requestType: params.type,
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
                    requestID: params.requestId
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
            store: store
        ) else {
            return
        }
        let entry = store.entry(requestID: requestID, sessionID: sessionID)
        resolver.complete(sessionID: sessionID, rawRequestID: params.requestId)

        store.applyEvent(
            makeLoadingFinishedEvent(
                sessionID: sessionID,
                requestID: requestID,
                rawRequestID: params.requestId,
                timestamp: params.timestamp,
                metrics: params.metrics,
                includeResponseBodyPlaceholder: entry?.responseBody?.hasDeferredContent != true
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
        includeResponseBodyPlaceholder: Bool
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
                    deferredLocator: .networkRequest(id: rawRequestID),
                    formEntries: [],
                    fetchState: .inline,
                    role: .response
                )
                : nil,
            blockedCookies: []
        )
    }

    func makeRequestBody(postData: String?, method: String, requestID: String) -> NetworkBody? {
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
            deferredLocator: .networkRequest(id: requestID),
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
        let defaultSessionID: (String?) -> String = { [weak self] in
            self?.sessionIdentifier(for: $0) ?? "page"
        }
        let normalizeScopeID: (String?) -> String? = { [weak self] in
            self?.normalizedScopeID($0)
        }
        let allocateRequestID = { [resolver] in
            resolver.allocateCanonicalRequestID()
        }

        if lease.supportSnapshot.capabilities.contains(.networkBootstrapSnapshot) {
            do {
                return try await StableBootstrapSource().load(
                    using: lease,
                    allocateRequestID: allocateRequestID,
                    defaultSessionID: defaultSessionID,
                    normalizeScopeID: normalizeScopeID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.debug("stable network bootstrap skipped: \(error.localizedDescription, privacy: .public)")
            }
        }

        do {
            return try await HistoricalBootstrapSource().load(
                using: lease,
                allocateRequestID: allocateRequestID,
                defaultSessionID: defaultSessionID,
                normalizeScopeID: normalizeScopeID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.debug("historical network bootstrap skipped: \(error.localizedDescription, privacy: .public)")
            return NetworkBootstrapLoad(seeds: [])
        }
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
