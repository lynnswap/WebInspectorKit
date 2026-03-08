import Foundation
import OSLog
import WebKit
import WebInspectorTransport

@MainActor
final class NetworkTransportDriver: NetworkPageDriving, InspectorTransportCapabilityProviding {
    private struct RequestKey: Hashable {
        let sessionID: String
        let rawRequestID: String
    }

    private struct RequestWillBeSentParams: Decodable {
        struct Request: Decodable {
            let url: String
            let method: String
            let headers: [String: String]
            let postData: String?
        }

        let requestId: String
        let timestamp: Double
        let walltime: Double?
        let type: String?
        let request: Request
        let redirectResponse: ResponsePayload?
    }

    private struct ResponseReceivedParams: Decodable {
        let requestId: String
        let timestamp: Double
        let type: String
        let response: ResponsePayload
    }

    private struct LoadingFinishedParams: Decodable {
        struct Metrics: Decodable {
            let requestBodyBytesSent: Int?
            let responseBodyBytesReceived: Int?
            let responseBodyDecodedSize: Int?
        }

        let requestId: String
        let timestamp: Double
        let metrics: Metrics?
    }

    private struct LoadingFailedParams: Decodable {
        let requestId: String
        let timestamp: Double
        let errorText: String
        let canceled: Bool?
    }

    private struct ResponsePayload: Decodable {
        let url: String?
        let status: Int
        let statusText: String
        let headers: [String: String]
        let mimeType: String
        let requestHeaders: [String: String]?
    }

    private struct WebSocketCreatedParams: Decodable {
        let requestId: String
        let url: String
        let timestamp: Double?
    }

    private struct WebSocketHandshakeRequestParams: Decodable {
        struct Request: Decodable {
            let headers: [String: String]
        }

        let requestId: String
        let timestamp: Double
        let walltime: Double?
        let request: Request
    }

    private struct WebSocketHandshakeResponseReceivedParams: Decodable {
        struct Response: Decodable {
            let status: Int
            let statusText: String
            let headers: [String: String]
        }

        let requestId: String
        let timestamp: Double
        let response: Response
    }

    private struct WebSocketFrameParams: Decodable {
        struct Frame: Decodable {
            let opcode: Int
            let mask: Bool
            let payloadData: String
            let payloadLength: Int
        }

        let requestId: String
        let timestamp: Double
        let response: Frame
    }

    private struct WebSocketFrameErrorParams: Decodable {
        let requestId: String
        let timestamp: Double
        let errorMessage: String
    }

    private struct WebSocketClosedParams: Decodable {
        let requestId: String
        let timestamp: Double
    }

    weak var webView: WKWebView?
    let store = NetworkStore()

    private let registry: WISharedTransportRegistry
    private let logger = Logger(subsystem: "WebInspectorKit", category: "NetworkTransportDriver")
    private let eventConsumerIdentifier = UUID()

    private var loggingMode: NetworkLoggingMode = .buffering
    private var lease: WISharedTransportRegistry.Lease?
    private var attachTask: Task<Void, Never>?
    private var requestIdentifiers: [RequestKey: Int] = [:]
    private var nextSyntheticRequestIdentifier = 1

    init(registry: WISharedTransportRegistry = .shared) {
        self.registry = registry
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

        let lease = registry.acquireLease(for: newWebView)
        self.lease = lease
        lease.addNetworkConsumer(eventConsumerIdentifier) { [weak self] event in
            self?.handle(event)
        }

        attachTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            do {
                try await lease.ensureAttached()
                try await lease.ensureNetworkEventIngress()
            } catch {
                guard self.shouldLogAttachFailure(error, lease: lease) else {
                    self.attachTask = nil
                    return
                }
                self.logger.error("network transport attach failed: \(error.localizedDescription, privacy: .public)")
            }

            self.attachTask = nil
        }
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

    package func fetchBodyResult(ref: String?, handle: AnyObject?, role: NetworkBody.Role) async -> NetworkBodyFetchResult {
        _ = handle

        guard let ref, !ref.isEmpty else {
            return .bodyUnavailable
        }
        guard let lease else {
            return .agentUnavailable
        }

        do {
            try await lease.ensureAttached()
            try await lease.ensureNetworkEventIngress()
            switch role {
            case .request:
                let response = try await lease.sendPage(WITransportCommands.Network.GetRequestPostData(requestId: ref))
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
                        reference: ref,
                        formEntries: [],
                        fetchState: .full,
                        role: .request
                    )
                )
            case .response:
                let response = try await lease.sendPage(WITransportCommands.Network.GetResponseBody(requestId: ref))
                return .fetched(
                    NetworkBody(
                        kind: response.base64Encoded ? .binary : .text,
                        preview: nil,
                        full: response.body,
                        size: nil,
                        isBase64Encoded: response.base64Encoded,
                        isTruncated: false,
                        summary: nil,
                        reference: ref,
                        formEntries: [],
                        fetchState: .full,
                        role: .response
                    )
                )
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

private extension NetworkTransportDriver {
    func tearDownLifecycle() {
        attachTask?.cancel()
        attachTask = nil
        releaseLease()
    }

    private func releaseLease() {
        lease?.removeNetworkConsumer(eventConsumerIdentifier)
        lease?.release()
        lease = nil
    }

    private func shouldLogAttachFailure(_ error: Error, lease: WISharedTransportRegistry.Lease) -> Bool {
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

    private func resetStoreState() {
        store.reset()
        requestIdentifiers.removeAll()
        nextSyntheticRequestIdentifier = 1
    }

    private func handle(_ envelope: WITransportEventEnvelope) {
        switch envelope.method {
        case "Network.requestWillBeSent":
            guard let params = try? JSONDecoder().decode(RequestWillBeSentParams.self, from: envelope.paramsData) else {
                return
            }
            handleRequestWillBeSent(params, targetIdentifier: envelope.targetIdentifier)

        case "Network.responseReceived":
            guard let params = try? JSONDecoder().decode(ResponseReceivedParams.self, from: envelope.paramsData) else {
                return
            }
            handleResponseReceived(params, targetIdentifier: envelope.targetIdentifier)

        case "Network.loadingFinished":
            guard let params = try? JSONDecoder().decode(LoadingFinishedParams.self, from: envelope.paramsData) else {
                return
            }
            handleLoadingFinished(params, targetIdentifier: envelope.targetIdentifier)

        case "Network.loadingFailed":
            guard let params = try? JSONDecoder().decode(LoadingFailedParams.self, from: envelope.paramsData) else {
                return
            }
            handleLoadingFailed(params, targetIdentifier: envelope.targetIdentifier)

        case "Network.webSocketCreated":
            guard let params = try? JSONDecoder().decode(WebSocketCreatedParams.self, from: envelope.paramsData) else {
                return
            }
            handleWebSocketCreated(params, targetIdentifier: envelope.targetIdentifier)

        case "Network.webSocketWillSendHandshakeRequest":
            guard let params = try? JSONDecoder().decode(WebSocketHandshakeRequestParams.self, from: envelope.paramsData) else {
                return
            }
            handleWebSocketHandshakeRequest(params, targetIdentifier: envelope.targetIdentifier)

        case "Network.webSocketHandshakeResponseReceived":
            guard let params = try? JSONDecoder().decode(WebSocketHandshakeResponseReceivedParams.self, from: envelope.paramsData) else {
                return
            }
            handleWebSocketHandshakeResponseReceived(params, targetIdentifier: envelope.targetIdentifier)

        case "Network.webSocketFrameReceived":
            guard let params = try? JSONDecoder().decode(WebSocketFrameParams.self, from: envelope.paramsData) else {
                return
            }
            handleWebSocketFrame(params, direction: .incoming, targetIdentifier: envelope.targetIdentifier)

        case "Network.webSocketFrameSent":
            guard let params = try? JSONDecoder().decode(WebSocketFrameParams.self, from: envelope.paramsData) else {
                return
            }
            handleWebSocketFrame(params, direction: .outgoing, targetIdentifier: envelope.targetIdentifier)

        case "Network.webSocketFrameError":
            guard let params = try? JSONDecoder().decode(WebSocketFrameErrorParams.self, from: envelope.paramsData) else {
                return
            }
            handleWebSocketFrameError(params, targetIdentifier: envelope.targetIdentifier)

        case "Network.webSocketClosed":
            guard let params = try? JSONDecoder().decode(WebSocketClosedParams.self, from: envelope.paramsData) else {
                return
            }
            handleWebSocketClosed(params, targetIdentifier: envelope.targetIdentifier)

        default:
            return
        }
    }

    private func handleRequestWillBeSent(_ params: RequestWillBeSentParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let key = RequestKey(sessionID: sessionID, rawRequestID: params.requestId)

        if let redirectResponse = params.redirectResponse,
           let previousRequestIdentifier = requestIdentifiers[key] {
            store.applyEvent(
                makeResponseEvent(
                    sessionID: sessionID,
                    requestID: previousRequestIdentifier,
                    timestamp: params.timestamp,
                    requestType: params.type,
                    response: redirectResponse
                )
            )
            store.applyEvent(
                makeLoadingFinishedEvent(
                    sessionID: sessionID,
                    requestID: previousRequestIdentifier,
                    rawRequestID: params.requestId,
                    timestamp: params.timestamp,
                    metrics: nil,
                    includeResponseBodyPlaceholder: false
                )
            )
            requestIdentifiers.removeValue(forKey: key)
        }

        guard requestIdentifiers[key] == nil else {
            return
        }

        let requestID = allocateRequestIdentifier(for: key)
        store.applyEvent(
            HTTPNetworkEvent(
                kind: .requestWillBeSent,
                sessionID: sessionID,
                requestID: requestID,
                url: params.request.url,
                method: params.request.method.uppercased(),
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
                    reference: params.requestId
                ),
                requestBodyBytesSent: params.request.postData?.utf8.count,
                responseBody: nil,
                blockedCookies: []
            )
        )
    }

    private func handleResponseReceived(_ params: ResponseReceivedParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let key = RequestKey(sessionID: sessionID, rawRequestID: params.requestId)
        guard let requestID = requestIdentifiers[key] else {
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

    private func handleLoadingFinished(_ params: LoadingFinishedParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let key = RequestKey(sessionID: sessionID, rawRequestID: params.requestId)
        guard let requestID = requestIdentifiers.removeValue(forKey: key) else {
            return
        }

        store.applyEvent(
            makeLoadingFinishedEvent(
                sessionID: sessionID,
                requestID: requestID,
                rawRequestID: params.requestId,
                timestamp: params.timestamp,
                metrics: params.metrics,
                includeResponseBodyPlaceholder: true
            )
        )
    }

    private func handleLoadingFailed(_ params: LoadingFailedParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let key = RequestKey(sessionID: sessionID, rawRequestID: params.requestId)
        guard let requestID = requestIdentifiers.removeValue(forKey: key) else {
            return
        }

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

    private func handleWebSocketCreated(_ params: WebSocketCreatedParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let key = RequestKey(sessionID: sessionID, rawRequestID: params.requestId)
        guard requestIdentifiers[key] == nil else {
            return
        }

        let requestID = allocateRequestIdentifier(for: key)
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

    private func handleWebSocketHandshakeRequest(
        _ params: WebSocketHandshakeRequestParams,
        targetIdentifier: String?
    ) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = webSocketRequestIdentifier(sessionID: sessionID, rawRequestID: params.requestId) else {
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

    private func handleWebSocketHandshakeResponseReceived(
        _ params: WebSocketHandshakeResponseReceivedParams,
        targetIdentifier: String?
    ) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = webSocketRequestIdentifier(sessionID: sessionID, rawRequestID: params.requestId) else {
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

    private func handleWebSocketFrame(
        _ params: WebSocketFrameParams,
        direction: NetworkWebSocketFrame.Direction,
        targetIdentifier: String?
    ) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        guard let requestID = webSocketRequestIdentifier(sessionID: sessionID, rawRequestID: params.requestId) else {
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

    private func handleWebSocketFrameError(_ params: WebSocketFrameErrorParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let key = RequestKey(sessionID: sessionID, rawRequestID: params.requestId)
        guard let requestID = requestIdentifiers.removeValue(forKey: key) else {
            return
        }

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

    private func handleWebSocketClosed(_ params: WebSocketClosedParams, targetIdentifier: String?) {
        let sessionID = sessionIdentifier(for: targetIdentifier)
        let key = RequestKey(sessionID: sessionID, rawRequestID: params.requestId)
        guard let requestID = requestIdentifiers.removeValue(forKey: key) else {
            return
        }

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

    private func makeResponseEvent(
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

    private func makeLoadingFinishedEvent(
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
                    reference: rawRequestID,
                    formEntries: [],
                    fetchState: .inline,
                    role: .response
                )
                : nil,
            blockedCookies: []
        )
    }

    private func makeRequestBody(postData: String?, method: String, reference: String) -> NetworkBody? {
        if let postData, !postData.isEmpty {
            return NetworkBody(
                kind: .text,
                preview: postData,
                full: postData,
                size: postData.utf8.count,
                isBase64Encoded: false,
                isTruncated: false,
                summary: nil,
                reference: nil,
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
            reference: reference,
            formEntries: [],
            fetchState: .inline,
            role: .request
        )
    }

    private func requestMethodMayCarryBody(_ method: String) -> Bool {
        switch method.uppercased() {
        case "GET", "HEAD":
            false
        default:
            true
        }
    }

    private func sessionIdentifier(for targetIdentifier: String?) -> String {
        targetIdentifier ?? "page"
    }

    private func webSocketRequestIdentifier(sessionID: String, rawRequestID: String) -> Int? {
        let key = RequestKey(sessionID: sessionID, rawRequestID: rawRequestID)
        return requestIdentifiers[key]
    }

    private func allocateRequestIdentifier(for key: RequestKey) -> Int {
        defer { nextSyntheticRequestIdentifier += 1 }
        let identifier = nextSyntheticRequestIdentifier
        requestIdentifiers[key] = identifier
        return identifier
    }
}
