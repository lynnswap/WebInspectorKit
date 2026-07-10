import Foundation
import WebInspectorProxyKit

/// Owns Network request identity, order, query projection, and publication.
///
/// `WebInspectorContext` remains the attachment and transport coordinator. The
/// store is confined by the actor supplied by each caller and never retains an
/// actor token or starts transport work.
package final class NetworkRequestStore {
#if DEBUG
    package struct PerformanceCounters: Equatable {
        package var fullModelProjectionCount = 0
        package var fullRecordProjectionCount = 0
        package var incrementalRecordProjectionCount = 0
        package var resultIdentityLookupCount = 0
    }
#endif

    package let collectionState: NetworkRequestCollectionState

    private var requestsByID: [NetworkRequest.ID: NetworkRequest]
    private var orderedRequestIDs: [NetworkRequest.ID]
    private var orderIndicesByID: [NetworkRequest.ID: Int]
    private var clearedRequestIDs: Set<NetworkRequest.ID>
    private let queryIndex: NetworkRequestIndex
    private var queryIndexSequence: UInt64
    private var queryIndexNeedsRebuild: Bool
    private var fetchedResults: [WeakWebInspectorFetchedResults<NetworkRequest>]
#if DEBUG
    private var performanceCounters: PerformanceCounters
#endif

    package init() {
        collectionState = NetworkRequestCollectionState()
        requestsByID = [:]
        orderedRequestIDs = []
        orderIndicesByID = [:]
        clearedRequestIDs = []
        queryIndex = NetworkRequestIndex()
        queryIndexSequence = 0
        queryIndexNeedsRebuild = false
        fetchedResults = []
#if DEBUG
        performanceCounters = PerformanceCounters()
#endif
    }

#if DEBUG
    package var performanceCountersForTesting: PerformanceCounters {
        performanceCounters
    }

    package func resetPerformanceCountersForTesting(
        isolation: isolated (any Actor) = #isolation
    ) {
        _ = isolation
        performanceCounters = PerformanceCounters()
    }
#endif

    package func request(
        for id: NetworkRequest.ID,
        isolation: isolated (any Actor) = #isolation
    ) -> NetworkRequest? {
        _ = isolation
        return requestsByID[id]
    }

    package func request(
        forProxyID id: Network.Request.ID,
        isolation: isolated (any Actor) = #isolation
    ) -> NetworkRequest? {
        request(for: NetworkRequest.ID(id), isolation: isolation)
    }

    package func finishResponseBodyFetch(
        _ result: Result<Network.Body, WebInspectorProxyError>,
        for request: NetworkRequest,
        expectedBody: NetworkBody,
        isolation: isolated (any Actor) = #isolation
    ) {
        _ = isolation
        guard requestsByID[request.id] === request else {
            return
        }
        request.finishResponseBodyFetch(result: result, expectedBody: expectedBody)
    }

    package func register(
        _ results: WebInspectorFetchedResults<NetworkRequest>,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) {
        let plan = NetworkRequestQueryPlan(descriptor: results.fetchDescriptor, context: modelContext)
        results.setNetworkItems(
            currentRequests(isolation: isolation),
            plan: plan,
            indexSequence: queryIndexSequence,
            lookup: { id in self.requestsByID[id] }
        )
        fetchedResults.append(WeakWebInspectorFetchedResults(results))
    }

    package func updateFetchDescriptor(
        _ descriptor: WebInspectorFetchDescriptor<NetworkRequest>,
        for results: WebInspectorFetchedResults<NetworkRequest>,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) {
        let plan = NetworkRequestQueryPlan(descriptor: descriptor, context: modelContext)
        results.applyNetworkFetchDescriptor(
            descriptor,
            plan: plan,
            requests: currentRequests(isolation: isolation),
            indexSequence: queryIndexSequence,
            lookup: { id in self.requestsByID[id] }
        )
    }

    /// Clears requests while remembering their protocol identities so late
    /// terminal events from the cleared loads remain ignorable.
    package func clear(isolation: isolated (any Actor) = #isolation) {
        clearedRequestIDs.formUnion(requestsByID.keys)
        removeAllRequests(isolation: isolation)
    }

    /// Resets state for a new attachment. Protocol identities may be reused by
    /// the new target, so the late-event suppression set is also discarded.
    package func resetForNewAttachment(isolation: isolated (any Actor) = #isolation) {
        clearedRequestIDs = []
        removeAllRequests(isolation: isolation)
    }

    @discardableResult
    package func seedRequest(
        requestID rawRequestID: String,
        url: String,
        method: String = "GET",
        resourceTypeRawValue: String?,
        requestHeaders: [String: String] = [:],
        postData: String? = nil,
        responseMIMEType: String,
        responseStatus: Int,
        responseStatusText: String,
        responseHeaders: [String: String] = [:],
        responseBody: String? = nil,
        timestamp: Double,
        encodedBodyLength: Int = 0,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) -> NetworkRequest.ID {
        _ = isolation
        let requestID = Network.Request.ID(rawRequestID)
        let resourceType = resourceTypeRawValue.map(Network.ResourceType.init(rawValue:))
        let payload = Network.Request(
            id: requestID,
            url: url,
            method: method,
            headers: requestHeaders,
            postData: postData
        )
        let id = NetworkRequest.ID(requestID)
        let request: NetworkRequest
        let inserted: Bool
        if let existing = requestsByID[id] {
            request = existing
            request.applyRequestWillBeSent(
                request: payload,
                resourceType: resourceType,
                timestamp: timestamp
            )
            inserted = false
        } else {
            request = NetworkRequest(
                request: payload,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
            requestsByID[id] = request
            appendRequestID(id, isolation: isolation)
            inserted = true
        }
        request.applyResponse(
            Network.Response(
                url: url,
                status: responseStatus,
                statusText: responseStatusText,
                mimeType: responseMIMEType,
                headers: responseHeaders,
                source: Network.Source(rawValue: "network"),
                requestHeaders: requestHeaders
            ),
            resourceType: resourceType ?? .other,
            timestamp: timestamp + 0.1
        )
        request.applyDataReceived(
            dataLength: encodedBodyLength,
            encodedDataLength: encodedBodyLength,
            timestamp: timestamp + 0.11
        )
        request.finish(
            timestamp: timestamp + 0.2,
            sourceMapURL: nil,
            metrics: Network.Metrics(
                encodedDataLength: encodedBodyLength,
                decodedBodyLength: encodedBodyLength
            )
        )
        if let responseBody {
            request.responseBody.load(Network.Body(data: responseBody, base64Encoded: false))
        }
        queryIndexNeedsRebuild = true
        pruneFetchedResults(isolation: isolation)
        if inserted {
            collectionState.didInsertRequest()
            for registration in fetchedResults {
                registration.value?.insertNetworkRequest(
                    request,
                    lookup: { id in self.requestsByID[id] }
                )
            }
        } else {
            for registration in fetchedResults {
                registration.value?.refreshNetworkRequestAfterMutation(
                    request,
                    lookup: { id in self.requestsByID[id] }
                )
            }
        }
        return request.id
    }

    package func seedResponseBody(
        for requestID: NetworkRequest.ID,
        body: String,
        base64Encoded: Bool = false,
        size: Int? = nil,
        isTruncated: Bool = false,
        isolation: isolated (any Actor) = #isolation
    ) {
        _ = isolation
        guard let request = requestsByID[requestID] else {
            preconditionFailure("Cannot seed a response body for an unregistered NetworkRequest.")
        }
        request.responseBody.load(NetworkBody.Payload(
            body: body,
            base64Encoded: base64Encoded,
            size: size,
            isTruncated: isTruncated
        ))
    }

    package func apply(
        _ event: Network.Event,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) async {
        switch event {
        case let .requestWillBeSent(id, request, resourceType, redirectResponse, timestamp):
            await applyRequestWillBeSent(
                id: id,
                request: request,
                resourceType: resourceType,
                redirectResponse: redirectResponse,
                timestamp: timestamp,
                modelContext: modelContext,
                isolation: isolation
            )
        case let .responseReceived(id, response, resourceType, timestamp):
            await applyResponseReceived(
                id: id,
                response: response,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext,
                isolation: isolation
            )
        case let .dataReceived(id, dataLength, encodedDataLength, timestamp):
            guard let request = request(for: id, method: "dataReceived", isolation: isolation) else {
                return
            }
            request.applyDataReceived(
                dataLength: dataLength,
                encodedDataLength: encodedDataLength,
                timestamp: timestamp
            )
            await notifyRequestMutated(request, modelContext: modelContext, isolation: isolation)
        case let .loadingFinished(id, timestamp, sourceMapURL, metrics):
            guard let request = request(for: id, method: "loadingFinished", isolation: isolation) else {
                return
            }
            request.finish(timestamp: timestamp, sourceMapURL: sourceMapURL, metrics: metrics)
            await notifyRequestMutated(request, modelContext: modelContext, isolation: isolation)
        case let .loadingFailed(id, errorText, canceled, timestamp):
            guard let request = request(for: id, method: "loadingFailed", isolation: isolation) else {
                return
            }
            request.fail(errorText: errorText, canceled: canceled, timestamp: timestamp)
            await notifyRequestMutated(request, modelContext: modelContext, isolation: isolation)
        case let .webSocket(event):
            await apply(event, modelContext: modelContext, isolation: isolation)
        case let .requestServedFromMemoryCache(id, response, resourceType, timestamp):
            await applyRequestServedFromMemoryCache(
                id: id,
                response: response,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext,
                isolation: isolation
            )
        case .unknown:
            break
        }
    }

    private func applyRequestWillBeSent(
        id proxyID: Network.Request.ID,
        request payload: Network.Request,
        resourceType: Network.ResourceType?,
        redirectResponse: Network.Response?,
        timestamp: Double,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        let id = NetworkRequest.ID(proxyID)
        guard clearedRequestIDs.contains(id) == false || redirectResponse == nil else {
            return
        }
        clearedRequestIDs.remove(id)
        let request: NetworkRequest
        var inserted = false
        var topologyMayHaveChanged = false
        if let existing = requestsByID[id] {
            request = existing
            if let redirectResponse, existing.isActive {
                request.applyRedirect(
                    to: payload,
                    redirectResponse: redirectResponse,
                    timestamp: timestamp,
                    resourceType: resourceType
                )
                topologyMayHaveChanged = true
            } else if existing.isActive == false {
                request.applyRequestWillBeSent(request: payload, resourceType: resourceType, timestamp: timestamp)
                topologyMayHaveChanged = true
            }
        } else {
            request = NetworkRequest(
                request: payload,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
            requestsByID[id] = request
            appendRequestID(id, isolation: isolation)
            inserted = true
        }
        if inserted {
            await notifyRequestInserted(request, modelContext: modelContext, isolation: isolation)
        } else if topologyMayHaveChanged {
            await notifyRequestMutated(request, modelContext: modelContext, isolation: isolation)
        }
    }

    private func applyRequestServedFromMemoryCache(
        id proxyID: Network.Request.ID,
        response: Network.Response,
        resourceType: Network.ResourceType?,
        timestamp: Double,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        let id = NetworkRequest.ID(proxyID)
        guard clearedRequestIDs.contains(id) == false else {
            return
        }
        let request: NetworkRequest
        if let existing = requestsByID[id] {
            request = existing
        } else {
            guard let url = response.url else {
                skipEvent("Network.requestServedFromMemoryCache omitted response URL for a new request")
                return
            }
            let payload = Network.Request(
                id: proxyID,
                url: url,
                method: "GET",
                headers: response.requestHeaders ?? [:]
            )
            request = NetworkRequest(
                request: payload,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
            requestsByID[id] = request
            appendRequestID(id, isolation: isolation)
            request.applyMemoryCache(response: response, resourceType: resourceType, timestamp: timestamp)
            await notifyRequestInserted(request, modelContext: modelContext, isolation: isolation)
            return
        }
        request.applyMemoryCache(response: response, resourceType: resourceType, timestamp: timestamp)
        await notifyRequestMutated(request, modelContext: modelContext, isolation: isolation)
    }

    private func applyResponseReceived(
        id proxyID: Network.Request.ID,
        response: Network.Response,
        resourceType: Network.ResourceType?,
        timestamp: Double,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        let id = NetworkRequest.ID(proxyID)
        guard clearedRequestIDs.contains(id) == false else {
            return
        }
        let request: NetworkRequest
        var inserted = false
        if let existing = requestsByID[id] {
            request = existing
        } else {
            guard let url = response.url else {
                skipEvent("Network.responseReceived omitted response URL for an untracked request")
                return
            }
            // WebKit's frontend creates a resource here when inspection starts
            // after Network.requestWillBeSent. The response event has no method,
            // so keep the same GET default WebKit uses when serializing such a
            // resource later.
            let payload = Network.Request(
                id: proxyID,
                url: url,
                method: "GET",
                headers: response.requestHeaders ?? [:]
            )
            request = NetworkRequest(
                request: payload,
                resourceType: resourceType,
                timestamp: timestamp,
                modelContext: modelContext
            )
            requestsByID[id] = request
            appendRequestID(id, isolation: isolation)
            inserted = true
        }
        request.applyResponse(response, resourceType: resourceType, timestamp: timestamp)
        if inserted {
            await notifyRequestInserted(request, modelContext: modelContext, isolation: isolation)
        } else {
            await notifyRequestMutated(request, modelContext: modelContext, isolation: isolation)
        }
    }

    private func apply(
        _ event: Network.WebSocketEvent,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        switch event {
        case let .created(id, url):
            await applyWebSocketCreated(
                id: id,
                url: url,
                modelContext: modelContext,
                isolation: isolation
            )
        case let .handshakeRequest(id, payload, timestamp):
            guard let networkRequest = request(
                for: id,
                method: "webSocketWillSendHandshakeRequest",
                isolation: isolation
            ) else {
                return
            }
            networkRequest.applyWebSocketHandshakeRequest(payload, timestamp: timestamp)
            await notifyRequestMutated(networkRequest, modelContext: modelContext, isolation: isolation)
        case let .handshakeResponse(id, response, timestamp):
            guard let networkRequest = request(
                for: id,
                method: "webSocketHandshakeResponseReceived",
                isolation: isolation
            ) else {
                return
            }
            networkRequest.applyWebSocketHandshakeResponse(response, timestamp: timestamp)
            await notifyRequestMutated(networkRequest, modelContext: modelContext, isolation: isolation)
        case let .frameSent(id, frame, timestamp):
            guard let networkRequest = request(
                for: id,
                method: "webSocketFrameSent",
                isolation: isolation
            ) else {
                return
            }
            networkRequest.appendWebSocketFrame(frame, direction: .sent, timestamp: timestamp)
            await notifyRequestMutated(networkRequest, modelContext: modelContext, isolation: isolation)
        case let .frameReceived(id, frame, timestamp):
            guard let networkRequest = request(
                for: id,
                method: "webSocketFrameReceived",
                isolation: isolation
            ) else {
                return
            }
            networkRequest.appendWebSocketFrame(frame, direction: .received, timestamp: timestamp)
            await notifyRequestMutated(networkRequest, modelContext: modelContext, isolation: isolation)
        case let .error(id, message, timestamp):
            guard let networkRequest = request(
                for: id,
                method: "webSocketFrameError",
                isolation: isolation
            ) else {
                return
            }
            networkRequest.appendWebSocketError(message, timestamp: timestamp)
            await notifyRequestMutated(networkRequest, modelContext: modelContext, isolation: isolation)
        case let .closed(id, timestamp):
            guard let networkRequest = request(
                for: id,
                method: "webSocketClosed",
                isolation: isolation
            ) else {
                return
            }
            networkRequest.closeWebSocket(timestamp: timestamp)
            await notifyRequestMutated(networkRequest, modelContext: modelContext, isolation: isolation)
        case .other:
            break
        }
    }

    private func applyWebSocketCreated(
        id proxyID: Network.Request.ID,
        url: String,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        let id = NetworkRequest.ID(proxyID)
        clearedRequestIDs.remove(id)
        let request: NetworkRequest
        var inserted = false
        if let existing = requestsByID[id] {
            request = existing
        } else {
            let payload = Network.Request(id: proxyID, url: url, method: "GET")
            request = NetworkRequest(
                request: payload,
                resourceType: .webSocket,
                timestamp: nil,
                modelContext: modelContext
            )
            requestsByID[id] = request
            appendRequestID(id, isolation: isolation)
            inserted = true
        }
        request.applyWebSocketCreated(url: url)
        if inserted {
            await notifyRequestInserted(request, modelContext: modelContext, isolation: isolation)
        } else {
            await notifyRequestMutated(request, modelContext: modelContext, isolation: isolation)
        }
    }

    private func request(
        for proxyID: Network.Request.ID,
        method: String,
        isolation: isolated (any Actor)
    ) -> NetworkRequest? {
        _ = isolation
        let id = NetworkRequest.ID(proxyID)
        guard let request = requestsByID[id] else {
            if clearedRequestIDs.contains(id) == false {
                skipEvent("Network.\(method) referenced an untracked request")
            }
            return nil
        }
        return request
    }

    private func removeAllRequests(isolation: isolated (any Actor)) {
        _ = isolation
        requestsByID = [:]
        orderedRequestIDs = []
        orderIndicesByID = [:]
        // The index is an actor. Mark it stale synchronously and replace it on
        // the next async mutation instead of spawning unowned cleanup work.
        queryIndexNeedsRebuild = true
        collectionState.replaceCount(0)
        resetFetchedResults(isolation: isolation)
    }

    private func currentRequests(isolation: isolated (any Actor)) -> [NetworkRequest] {
        _ = isolation
#if DEBUG
        performanceCounters.fullModelProjectionCount += orderedRequestIDs.count
#endif
        return orderedRequestIDs.compactMap { requestsByID[$0] }
    }

    private func appendRequestID(
        _ id: NetworkRequest.ID,
        isolation: isolated (any Actor)
    ) {
        _ = isolation
        orderIndicesByID[id] = orderedRequestIDs.count
        orderedRequestIDs.append(id)
    }

    private func currentRecordInputs(
        isolation: isolated (any Actor)
    ) -> [NetworkRequestRecordInput] {
        _ = isolation
#if DEBUG
        performanceCounters.fullRecordProjectionCount += orderedRequestIDs.count
#endif
        return orderedRequestIDs.enumerated().compactMap { index, id in
            requestsByID[id].map { NetworkRequestRecordInput(request: $0, orderIndex: index) }
        }
    }

    private func recordInput(
        for request: NetworkRequest,
        isolation: isolated (any Actor)
    ) -> NetworkRequestRecordInput {
        _ = isolation
#if DEBUG
        performanceCounters.incrementalRecordProjectionCount += 1
#endif
        let orderIndex = orderIndicesByID[request.id] ?? orderedRequestIDs.count
        return NetworkRequestRecordInput(request: request, orderIndex: orderIndex)
    }

    private func isCurrent(
        _ request: NetworkRequest,
        isolation: isolated (any Actor)
    ) -> Bool {
        _ = isolation
        return requestsByID[request.id] === request
    }

    private func nextQueryIndexSequence(isolation: isolated (any Actor)) -> UInt64 {
        _ = isolation
        // The index drains a contiguous operation log, so every allocated
        // sequence must be submitted exactly once to replace or upsert.
        precondition(
            queryIndexSequence < UInt64.max,
            "NetworkRequestIndex mutation sequence overflowed."
        )
        queryIndexSequence += 1
        return queryIndexSequence
    }

    private func syncQueryIndexIfNeeded(isolation: isolated (any Actor)) async {
        guard queryIndexNeedsRebuild else {
            return
        }
        queryIndexNeedsRebuild = false
        let sequence = nextQueryIndexSequence(isolation: isolation)
        let inputs = currentRecordInputs(isolation: isolation)
        await queryIndex.replace(with: inputs, sequence: sequence)
    }

    private func notifyRequestInserted(
        _ request: NetworkRequest,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        collectionState.didInsertRequest()
        await syncQueryIndexIfNeeded(isolation: isolation)
        guard isCurrent(request, isolation: isolation) else {
            return
        }
        let sequence = nextQueryIndexSequence(isolation: isolation)
        let input = recordInput(for: request, isolation: isolation)
        await queryIndex.upsert(input, sequence: sequence)
        guard isCurrent(request, isolation: isolation) else {
            return
        }
        await applyResultDeltas(
            for: request,
            inserted: true,
            modelContext: modelContext,
            isolation: isolation
        )
    }

    private func notifyRequestMutated(
        _ request: NetworkRequest,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        await syncQueryIndexIfNeeded(isolation: isolation)
        guard isCurrent(request, isolation: isolation) else {
            return
        }
        let sequence = nextQueryIndexSequence(isolation: isolation)
        let input = recordInput(for: request, isolation: isolation)
        await queryIndex.upsert(input, sequence: sequence)
        guard isCurrent(request, isolation: isolation) else {
            return
        }
        await applyResultDeltas(
            for: request,
            inserted: false,
            modelContext: modelContext,
            isolation: isolation
        )
    }

    private func applyResultDeltas(
        for request: NetworkRequest,
        inserted: Bool,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        pruneFetchedResults(isolation: isolation)
        for registration in fetchedResults {
            guard let results = registration.value else {
                continue
            }
            let plan = results.currentNetworkQueryPlan(context: modelContext)
            if plan.requiresModelPredicate {
                if inserted {
                    results.insertNetworkRequest(
                        request,
                        lookup: { id in self.requestsByID[id] }
                    )
                } else {
                    results.refreshNetworkRequestAfterMutation(
                        request,
                        lookup: { id in self.requestsByID[id] }
                    )
                }
                continue
            }
            let oldSnapshot = results.networkSnapshotForDelta
            let resultTopologyRevision = results.topologyRevision
            let resultIndexSequence = results.networkIndexSequenceForDelta
            let indexSequence = queryIndexSequence
            let delta = await queryIndex.delta(
                plan: plan,
                sectionBy: results.sectionBy,
                oldSnapshot: oldSnapshot,
                changedSince: resultIndexSequence
            )
            guard queryIndexSequence == indexSequence,
                  results.topologyRevision == resultTopologyRevision,
                  results.networkSnapshotForDelta == oldSnapshot else {
                continue
            }
            results.applyNetworkDelta(
                delta,
                lookup: { id in self.requestForResult(id, isolation: isolation) }
            )
        }
    }

    private func requestForResult(
        _ id: NetworkRequest.ID,
        isolation: isolated (any Actor)
    ) -> NetworkRequest? {
        _ = isolation
#if DEBUG
        performanceCounters.resultIdentityLookupCount += 1
#endif
        return requestsByID[id]
    }

    private func pruneFetchedResults(isolation: isolated (any Actor)) {
        _ = isolation
        fetchedResults.removeAll { $0.value == nil }
    }

    private func resetFetchedResults(isolation: isolated (any Actor)) {
        pruneFetchedResults(isolation: isolation)
        for registration in fetchedResults {
            registration.value?.resetNetworkItems(indexSequence: queryIndexSequence)
        }
    }

    private func skipEvent(_ reason: String) {
        WebInspectorDataKitLog.debug("event skipped: \(reason)")
    }
}
