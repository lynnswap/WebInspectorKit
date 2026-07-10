import Foundation
import WebInspectorProxyKit

/// Owns Network request identity, order, query projection, and publication.
///
/// `WebInspectorContext` remains the attachment and transport coordinator. The
/// store is confined by the actor supplied by each caller and never retains an
/// actor token or starts transport work.
package final class NetworkRequestStore {
    private enum ConcreteQueryBufferDestination {
        case candidate
        case committing
    }

    private struct PendingConcreteQuery {
        var generation: UInt64
        var query: NetworkQuery
        var projection: NetworkRequestIndex.QueryProjection?
    }

    private struct ConcreteQueryRegistration {
        var results: WeakWebInspectorFetchedResults<NetworkRequest>
        var activeGeneration: UInt64
        var activeQuery: NetworkQuery
        var candidate: PendingConcreteQuery?
        var committing: [UInt64: PendingConcreteQuery]
    }

    package struct QueryIndexReset: Sendable {
        fileprivate var sequence: UInt64
        fileprivate var sourceEpoch: UInt64
    }

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
    private var querySourceEpoch: UInt64
    private var nextConcreteQueryRegistrationID: UInt64
    private var initializingConcreteQueries: [
        WebInspectorQueryRegistrationID: PendingConcreteQuery
    ]
    private var concreteQueryRegistrations: [
        WebInspectorQueryRegistrationID: ConcreteQueryRegistration
    ]
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
        querySourceEpoch = 0
        nextConcreteQueryRegistrationID = 0
        initializingConcreteQueries = [:]
        concreteQueryRegistrations = [:]
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

    package func results(
        matching query: NetworkQuery,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor) = #isolation
    ) async throws -> WebInspectorFetchedResults<NetworkRequest> {
        await syncQueryIndexIfNeeded(isolation: isolation)
        let id = allocateConcreteQueryRegistrationID(isolation: isolation)
        let lifetime = WebInspectorQueryRegistrationLifetime()
        let results = WebInspectorFetchedResults<NetworkRequest>(
            fetchDescriptor: WebInspectorFetchDescriptor(),
            modelContext: modelContext
        )
        results.installQueryRegistration(id: id, lifetime: lifetime)
        let generation = results.nextConcreteQueryGeneration()
        initializingConcreteQueries[id] = PendingConcreteQuery(
            generation: generation,
            query: query,
            projection: nil
        )

        let initialProjection: NetworkRequestIndex.QueryProjection
        do {
            initialProjection = try await queryIndex.register(
                id: id,
                generation: generation,
                query: query,
                lifetime: lifetime,
                minimumSequence: queryIndexSequence
            )
        } catch {
            initializingConcreteQueries[id] = nil
            throw error
        }

        guard var initialization = initializingConcreteQueries.removeValue(forKey: id),
              initialization.generation == generation else {
            preconditionFailure("Network query initialization lost its owner state after index commit.")
        }
        initialization.projection = coalesce(
            initialization.projection,
            with: initialProjection
        )
        let installedProjection = initialization.projection ?? initialProjection
        guard installedProjection.sourceEpoch == querySourceEpoch else {
            throw CancellationError()
        }
        results.installInitialNetworkQuery(
            query,
            generation: generation,
            projection: installedProjection,
            lookup: { id in self.requestForResult(id, isolation: isolation) }
        )
        concreteQueryRegistrations[id] = ConcreteQueryRegistration(
            results: WeakWebInspectorFetchedResults(results),
            activeGeneration: generation,
            activeQuery: query,
            candidate: nil,
            committing: [:]
        )
        await queryIndex.acknowledge(
            id: id,
            generation: generation,
            sourceEpoch: installedProjection.sourceEpoch,
            sequence: installedProjection.sequence
        )
        return results
    }

    package func update(
        _ query: NetworkQuery,
        for results: WebInspectorFetchedResults<NetworkRequest>,
        isolation: isolated (any Actor) = #isolation
    ) async throws {
        guard let id = results.concreteQueryRegistrationID else {
            preconditionFailure("Network fetched results are not registered in this store.")
        }
        await syncQueryIndexIfNeeded(isolation: isolation)
        guard var registration = concreteQueryRegistrations[id],
              registration.results.value === results else {
            preconditionFailure("Network fetched results are not registered in this store.")
        }
        let generation = results.nextConcreteQueryGeneration()
        registration.candidate = PendingConcreteQuery(
            generation: generation,
            query: query,
            projection: nil
        )
        concreteQueryRegistrations[id] = registration

        do {
            let prepared = try await queryIndex.prepareReplacement(
                id: id,
                generation: generation,
                query: query,
                minimumSequence: queryIndexSequence
            )
            buffer(
                prepared,
                for: id,
                generation: generation,
                query: query,
                destination: .candidate
            )
            guard results.isCurrentConcreteQueryGeneration(generation) else {
                throw CancellationError()
            }
            try Task.checkCancellation()
        } catch {
            await queryIndex.discardCandidates(id: id, through: generation)
            clearCandidate(id: id, generation: generation)
            throw error
        }

        guard var beforeCommit = concreteQueryRegistrations[id],
              let candidate = beforeCommit.candidate,
              candidate.generation == generation,
              candidate.projection?.sourceEpoch == querySourceEpoch else {
            await queryIndex.discardCandidates(id: id, through: generation)
            clearCandidate(id: id, generation: generation)
            throw CancellationError()
        }
        beforeCommit.committing[generation] = candidate
        beforeCommit.candidate = nil
        concreteQueryRegistrations[id] = beforeCommit

        guard let committed = await queryIndex.commitReplacement(
            id: id,
            generation: generation
        ) else {
            clearCommitting(id: id, generation: generation)
            throw CancellationError()
        }

        guard var afterCommit = concreteQueryRegistrations[id],
              var pendingPublication = afterCommit.committing.removeValue(forKey: generation) else {
            preconditionFailure("Network query replacement lost committed publication state.")
        }
        pendingPublication.projection = coalesce(
            pendingPublication.projection,
            with: committed
        )
        let publication = pendingPublication.projection ?? committed
        let applied = results.applyNetworkQueryProjection(
            publication,
            query: query,
            generation: generation,
            isReplacement: true,
            lookup: { id in self.requestForResult(id, isolation: isolation) }
        )
        if generation > afterCommit.activeGeneration {
            afterCommit.activeGeneration = generation
            afterCommit.activeQuery = query
        }
        concreteQueryRegistrations[id] = afterCommit
        if applied {
            await queryIndex.acknowledge(
                id: id,
                generation: generation,
                sourceEpoch: publication.sourceEpoch,
                sequence: publication.sequence
            )
        }
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
    package func clear(isolation: isolated (any Actor) = #isolation) async {
        clearedRequestIDs.formUnion(requestsByID.keys)
        let reset = prepareRemoveAllRequests(isolation: isolation)
        await finishQueryIndexReset(reset, isolation: isolation)
    }

    /// Begins a new attachment epoch and immediately removes prior identities.
    package func prepareResetForNewAttachment(
        isolation: isolated (any Actor) = #isolation
    ) -> QueryIndexReset {
        clearedRequestIDs = []
        return prepareRemoveAllRequests(isolation: isolation)
    }

    package func finishQueryIndexReset(
        _ reset: QueryIndexReset,
        isolation: isolated (any Actor) = #isolation
    ) async {
        let deliveries = await queryIndex.replace(
            with: [],
            sequence: reset.sequence,
            sourceEpoch: reset.sourceEpoch
        )
        await applyConcreteDeliveries(deliveries, isolation: isolation)
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

    private func prepareRemoveAllRequests(
        isolation: isolated (any Actor)
    ) -> QueryIndexReset {
        requestsByID = [:]
        orderedRequestIDs = []
        orderIndicesByID = [:]
        queryIndexNeedsRebuild = false
        advanceQuerySourceEpoch(isolation: isolation)
        let sequence = nextQueryIndexSequence(isolation: isolation)
        collectionState.replaceCount(0)
        resetFetchedResults(isolation: isolation)
        let reset = QueryIndexReset(
            sequence: sequence,
            sourceEpoch: querySourceEpoch
        )
        publishEmptyConcreteQueryResults(for: reset, isolation: isolation)
        return reset
    }

    private func publishEmptyConcreteQueryResults(
        for reset: QueryIndexReset,
        isolation: isolated (any Actor)
    ) {
        pruneConcreteQueryRegistrations(isolation: isolation)
        let projection = NetworkRequestIndex.QueryProjection(
            sourceEpoch: reset.sourceEpoch,
            sequence: reset.sequence,
            snapshot: WebInspectorFetchedResultsSnapshot(),
            reconfigureItemIDs: []
        )
        for registration in concreteQueryRegistrations.values {
            registration.results.value?.applyNetworkQueryProjection(
                projection,
                query: registration.activeQuery,
                generation: registration.activeGeneration,
                isReplacement: false,
                lookup: { _ in
                    preconditionFailure("An empty Network reset cannot resolve a model identity.")
                }
            )
        }
    }

    private func advanceQuerySourceEpoch(isolation: isolated (any Actor)) {
        _ = isolation
        precondition(
            querySourceEpoch < UInt64.max,
            "Network query source epoch overflowed."
        )
        querySourceEpoch += 1
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
        let deliveries = await queryIndex.replace(
            with: inputs,
            sequence: sequence,
            sourceEpoch: querySourceEpoch
        )
        await applyConcreteDeliveries(deliveries, isolation: isolation)
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
        let deliveries = await queryIndex.upsert(input, sequence: sequence)
        await applyConcreteDeliveries(deliveries, isolation: isolation)
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
        let deliveries = await queryIndex.upsert(input, sequence: sequence)
        await applyConcreteDeliveries(deliveries, isolation: isolation)
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

    private func allocateConcreteQueryRegistrationID(
        isolation: isolated (any Actor)
    ) -> WebInspectorQueryRegistrationID {
        _ = isolation
        precondition(
            nextConcreteQueryRegistrationID < UInt64.max,
            "Network concrete query registration identity overflowed."
        )
        let id = WebInspectorQueryRegistrationID(rawValue: nextConcreteQueryRegistrationID)
        nextConcreteQueryRegistrationID += 1
        return id
    }

    private func applyConcreteDeliveries(
        _ deliveries: [NetworkRequestIndex.QueryDelivery],
        isolation: isolated (any Actor)
    ) async {
        pruneConcreteQueryRegistrations(isolation: isolation)
        var acknowledgements: [(
            id: WebInspectorQueryRegistrationID,
            generation: UInt64,
            sourceEpoch: UInt64,
            sequence: UInt64
        )] = []
        for delivery in deliveries {
            guard delivery.projection.sourceEpoch == querySourceEpoch else {
                continue
            }
            let id = delivery.registrationID
            if var initialization = initializingConcreteQueries[id],
               initialization.generation == delivery.generation {
                initialization.projection = coalesce(
                    initialization.projection,
                    with: delivery.projection
                )
                initializingConcreteQueries[id] = initialization
                continue
            }
            guard var registration = concreteQueryRegistrations[id] else {
                continue
            }
            if delivery.generation == registration.activeGeneration {
                guard let results = registration.results.value else {
                    concreteQueryRegistrations[id] = nil
                    continue
                }
                let applied = results.applyNetworkQueryProjection(
                    delivery.projection,
                    query: registration.activeQuery,
                    generation: delivery.generation,
                    isReplacement: false,
                    lookup: { id in self.requestForResult(id, isolation: isolation) }
                )
                if applied {
                    acknowledgements.append((
                        id,
                        delivery.generation,
                        delivery.projection.sourceEpoch,
                        delivery.projection.sequence
                    ))
                }
            } else if var candidate = registration.candidate,
                      candidate.generation == delivery.generation {
                candidate.projection = coalesce(candidate.projection, with: delivery.projection)
                registration.candidate = candidate
            } else if var committing = registration.committing[delivery.generation] {
                committing.projection = coalesce(
                    committing.projection,
                    with: delivery.projection
                )
                registration.committing[delivery.generation] = committing
            }
            concreteQueryRegistrations[id] = registration
        }
        for acknowledgement in acknowledgements {
            await queryIndex.acknowledge(
                id: acknowledgement.id,
                generation: acknowledgement.generation,
                sourceEpoch: acknowledgement.sourceEpoch,
                sequence: acknowledgement.sequence
            )
        }
    }

    private func buffer(
        _ projection: NetworkRequestIndex.QueryProjection,
        for id: WebInspectorQueryRegistrationID,
        generation: UInt64,
        query: NetworkQuery,
        destination: ConcreteQueryBufferDestination
    ) {
        guard var registration = concreteQueryRegistrations[id] else {
            return
        }
        switch destination {
        case .candidate:
            guard var candidate = registration.candidate,
                  candidate.generation == generation,
                  candidate.query == query else {
                return
            }
            candidate.projection = coalesce(candidate.projection, with: projection)
            registration.candidate = candidate
        case .committing:
            guard var committing = registration.committing[generation],
                  committing.query == query else {
                return
            }
            committing.projection = coalesce(committing.projection, with: projection)
            registration.committing[generation] = committing
        }
        concreteQueryRegistrations[id] = registration
    }

    private func clearCandidate(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64
    ) {
        guard var registration = concreteQueryRegistrations[id],
              registration.candidate?.generation == generation else {
            return
        }
        registration.candidate = nil
        concreteQueryRegistrations[id] = registration
    }

    private func clearCommitting(
        id: WebInspectorQueryRegistrationID,
        generation: UInt64
    ) {
        guard var registration = concreteQueryRegistrations[id] else {
            return
        }
        registration.committing[generation] = nil
        concreteQueryRegistrations[id] = registration
    }

    private func coalesce(
        _ current: NetworkRequestIndex.QueryProjection?,
        with incoming: NetworkRequestIndex.QueryProjection
    ) -> NetworkRequestIndex.QueryProjection {
        guard let current else {
            return incoming
        }
        let incomingIsNewer = incoming.sourceEpoch > current.sourceEpoch
            || (incoming.sourceEpoch == current.sourceEpoch && incoming.sequence > current.sequence)
        let newest = incomingIsNewer ? incoming : current
        let reconfigureItemIDs = current.reconfigureItemIDs
            .union(incoming.reconfigureItemIDs)
            .intersection(newest.snapshot.itemIDs)
        return NetworkRequestIndex.QueryProjection(
            sourceEpoch: newest.sourceEpoch,
            sequence: newest.sequence,
            snapshot: newest.snapshot,
            reconfigureItemIDs: reconfigureItemIDs
        )
    }

    private func pruneConcreteQueryRegistrations(isolation: isolated (any Actor)) {
        _ = isolation
        concreteQueryRegistrations = concreteQueryRegistrations.filter { _, registration in
            registration.results.value != nil
        }
    }

#if DEBUG
    package func concreteQueryRegistrationCountForTesting(
        isolation: isolated (any Actor) = #isolation
    ) async -> Int {
        _ = isolation
        return await queryIndex.queryRegistrationCountForTesting()
    }
#endif

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
