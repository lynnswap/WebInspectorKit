import Foundation
import WebInspectorProxyKit

private struct NetworkFrameNavigationTimeline {
    private struct Visit {
        let loaderID: String
        let targetID: String?
        let epoch: UInt64
    }

    private struct PendingVisitKey: Hashable {
        let loaderID: String
        let targetID: String?
    }

    private var committed: Visit?
    private var pendingEpochByVisit: [PendingVisitKey: UInt64]
    private var lastAllocatedEpoch: UInt64

    init(initialLoaderID: String, targetID: String?) {
        committed = Visit(loaderID: initialLoaderID, targetID: targetID, epoch: 0)
        pendingEpochByVisit = [:]
        lastAllocatedEpoch = 0
    }

    mutating func epoch(for loaderID: String, targetID: String?) -> UInt64 {
        let key = PendingVisitKey(loaderID: loaderID, targetID: targetID)
        if let pending = pendingEpochByVisit[key] {
            return pending
        }
        let pendingVisits = pendingVisits(for: loaderID)
        if let current = committed, current.loaderID == loaderID {
            if let targetID {
                if current.targetID == targetID {
                    return current.epoch
                }
                if current.targetID == nil, pendingVisits.isEmpty {
                    committed = Visit(loaderID: loaderID, targetID: targetID, epoch: current.epoch)
                    return current.epoch
                }
            } else if pendingVisits.isEmpty {
                return current.epoch
            }
        }
        if targetID == nil, pendingVisits.count == 1, let pending = pendingVisits.first {
            return pending.epoch
        }
        let epoch = allocateEpoch()
        pendingEpochByVisit[key] = epoch
        return epoch
    }

    mutating func commit(loaderID: String, targetID: String? = nil) -> UInt64 {
        let pending: (targetID: String?, epoch: UInt64)?
        if let targetID {
            pending = pendingEpochByVisit[PendingVisitKey(loaderID: loaderID, targetID: targetID)].map {
                (targetID, $0)
            }
        } else {
            let pendingVisits = pendingVisits(for: loaderID)
            let unattributed = pendingEpochByVisit[PendingVisitKey(loaderID: loaderID, targetID: nil)].map {
                (targetID: Optional<String>.none, epoch: $0)
            }
            pending = unattributed ?? (pendingVisits.count == 1 ? pendingVisits.first : nil)
            if let unattributed, pendingVisits.count > 1 {
                committed = Visit(loaderID: loaderID, targetID: nil, epoch: unattributed.epoch)
                return unattributed.epoch
            }
            if unattributed == nil, pendingVisits.count > 1 {
                let visit = Visit(loaderID: loaderID, targetID: nil, epoch: allocateEpoch())
                committed = visit
                pendingEpochByVisit[PendingVisitKey(loaderID: loaderID, targetID: nil)] = visit.epoch
                return visit.epoch
            }
        }
        if let pending {
            committed = Visit(loaderID: loaderID, targetID: pending.targetID, epoch: pending.epoch)
            pendingEpochByVisit.removeAll(keepingCapacity: true)
            return pending.epoch
        }
        if let current = committed, current.loaderID == loaderID {
            if targetID == nil || current.targetID == targetID {
                pendingEpochByVisit.removeAll(keepingCapacity: true)
                return current.epoch
            }
            if current.targetID == nil, pendingEpochByVisit.isEmpty, let targetID {
                committed = Visit(loaderID: loaderID, targetID: targetID, epoch: current.epoch)
                return current.epoch
            }
        }
        let visit = Visit(loaderID: loaderID, targetID: targetID, epoch: allocateEpoch())
        committed = visit
        pendingEpochByVisit.removeAll(keepingCapacity: true)
        return visit.epoch
    }

    mutating func retire() {
        committed = nil
        pendingEpochByVisit.removeAll(keepingCapacity: true)
    }

    mutating func abandon(targetID: String) {
        if committed?.targetID == targetID {
            committed = nil
        }
        pendingEpochByVisit = pendingEpochByVisit.filter { $0.key.targetID != targetID }
    }

    mutating func bindSoleUnattributedVisit(to targetID: String) -> Bool {
        if pendingEpochByVisit.count == 1,
           let pending = pendingEpochByVisit.first,
           pending.key.targetID == nil {
            committed = Visit(
                loaderID: pending.key.loaderID,
                targetID: targetID,
                epoch: pending.value
            )
            pendingEpochByVisit.removeAll(keepingCapacity: true)
            return true
        }
        if let current = committed, current.targetID == nil {
            committed = Visit(
                loaderID: current.loaderID,
                targetID: targetID,
                epoch: current.epoch
            )
            return true
        }
        return false
    }

    private func pendingVisits(for loaderID: String) -> [(targetID: String?, epoch: UInt64)] {
        Array(pendingEpochByVisit.lazy
            .filter { $0.key.loaderID == loaderID }
            .map { (targetID: $0.key.targetID, epoch: $0.value) })
    }

    private mutating func allocateEpoch() -> UInt64 {
        lastAllocatedEpoch += 1
        return lastAllocatedEpoch
    }
}

/// Applies Network events to the request models of one `WebInspectorContext`.
///
/// The recorder owns the request store, the per-frame navigation timelines
/// that group requests by page visit, and the resource-tree restore. The
/// owning context forwards Network events and the lifecycle events that move
/// those timelines. Calls must come from the context's actor.
final class NetworkEventRecorder {
    let requestStore = NetworkRequestStore()

    /// Advances whenever a frame navigates or detaches, so an in-flight
    /// resource-tree snapshot can tell that it is out of date.
    private(set) var resourceTreeRevision: UInt64 = 0
    private var attachmentEpoch: UInt64 = 0
    private var navigationTimelines: [FrameID: NetworkFrameNavigationTimeline] = [:]
    private var pendingNavigationsByTargetID: [String: [FrameID: String]] = [:]
    private var nextChronologySequence: UInt64 = 0

    // MARK: - Lifecycle

    /// Starts a new attachment: drops every request and navigation timeline.
    func beginAttachment() {
        attachmentEpoch += 1
        navigationTimelines = [:]
        pendingNavigationsByTargetID = [:]
        requestStore.reset(for: .newAttachment)
    }

    /// Clears the requests on the user's behalf.
    func clearRequests() {
        requestStore.reset(for: .userClear)
    }

    func frameNavigated(_ frame: WebInspectorPageFrameLifecycle) {
        resourceTreeRevision &+= 1
        requestStore.invalidateResourceTreeContent(frameID: frame.id, keepingLoaderID: frame.loaderID)
        commitNetworkNavigation(frame)
    }

    func frameDetached(_ frameID: FrameID) {
        resourceTreeRevision &+= 1
        requestStore.invalidateResourceTreeContent(frameID: frameID)
        retireNetworkNavigation(frameID: frameID)
    }

    func targetDestroyed(_ targetID: WebInspectorTarget.ID) {
        abandonNetworkNavigation(targetID: targetID)
    }

    func targetCommitted(_ commit: WebInspectorTargetCommitLifecycle) {
        requestStore.invalidateResourceTreeContent()
        commitNetworkNavigation(commit)
    }

    private func skipEvent(_ reason: String) {
        WebInspectorDataKitLog.debug("event skipped: \(reason)")
    }

    // MARK: - Events

    @discardableResult
    func seedNetworkRequest(
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
        isolation: isolated (any Actor)
    ) -> NetworkRequest.ID {
        let requestID = Network.Request.ID(rawRequestID)
        let resourceType = resourceTypeRawValue.map(Network.ResourceType.init(rawValue:))
        let payload = Network.Request(
            id: requestID,
            url: url,
            method: method,
            headers: requestHeaders,
            postData: postData
        )
        let chronologySequence = takeNetworkChronologySequence()
        let id = NetworkRequest.ID(requestID)
        let hydrate: (NetworkRequest) -> Void = { request in
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
        }
        guard let resolution = requestStore.resolveSynchronously(
            id: id,
            admission: .requestWillBeSent(hasRedirectResponse: false),
            create: {
                let request = NetworkRequest(
                    request: payload,
                    initiator: nil,
                    resourceType: resourceType,
                    timestamp: timestamp,
                    chronologySequence: chronologySequence,
                    modelContext: modelContext
                )
                hydrate(request)
                return request
            }
        ) else {
            preconditionFailure("A seeded Network request must be admitted by the store.")
        }
        switch resolution {
        case let .existing(registration):
            registration.request.applyRequestWillBeSent(
                request: payload,
                initiator: nil,
                navigationVisit: nil,
                resourceType: resourceType,
                timestamp: timestamp,
                chronologySequence: chronologySequence
            )
            hydrate(registration.request)
            requestStore.commitUpdateSynchronously(registration)
        case .inserted:
            break
        }
        return resolution.registration.request.id
    }

    func seedResponseBody(
        for requestID: NetworkRequest.ID,
        body: String,
        base64Encoded: Bool = false,
        size: Int? = nil,
        isTruncated: Bool = false,
        isolation: isolated (any Actor)
    ) {
        guard let request = requestStore.registration(for: requestID)?.request else {
            preconditionFailure("Cannot seed a response body for an unregistered NetworkRequest.")
        }
        request.responseBody.load(NetworkBody.Payload(
            body: body,
            base64Encoded: base64Encoded,
            size: size,
            isTruncated: isTruncated
        ))
    }

    func apply(
        _ event: Network.Event,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        let chronologySequence = takeNetworkChronologySequence()
        switch event {
        case let .requestWillBeSent(id, request, initiator, resourceType, redirectResponse, timestamp):
            await applyRequestWillBeSent(
                id: id,
                request: request,
                initiator: initiator,
                resourceType: resourceType,
                redirectResponse: redirectResponse,
                timestamp: timestamp,
                chronologySequence: chronologySequence,
                modelContext: modelContext,
                isolation: isolation
            )
        case let .responseReceived(id, response, resourceType, timestamp):
            await applyResponseReceived(
                id: id,
                response: response,
                resourceType: resourceType,
                timestamp: timestamp,
                chronologySequence: chronologySequence,
                modelContext: modelContext,
                isolation: isolation
            )
        case let .dataReceived(id, dataLength, encodedDataLength, timestamp):
            guard let registration = networkRegistration(for: id, method: "dataReceived") else {
                return
            }
            let request = registration.request
            request.applyDataReceived(
                dataLength: dataLength,
                encodedDataLength: encodedDataLength,
                timestamp: timestamp
            )
            await requestStore.commitUpdate(registration, isolation: isolation)
        case let .loadingFinished(id, timestamp, sourceMapURL, metrics):
            guard let registration = networkRegistration(for: id, method: "loadingFinished") else {
                return
            }
            let request = registration.request
            request.finish(timestamp: timestamp, sourceMapURL: sourceMapURL, metrics: metrics)
            await requestStore.commitUpdate(registration, isolation: isolation)
        case let .loadingFailed(id, errorText, canceled, timestamp):
            guard let registration = networkRegistration(for: id, method: "loadingFailed") else {
                return
            }
            let request = registration.request
            request.fail(errorText: errorText, canceled: canceled, timestamp: timestamp)
            await requestStore.commitUpdate(registration, isolation: isolation)
        case let .webSocket(event):
            await apply(
                event,
                chronologySequence: chronologySequence,
                modelContext: modelContext,
                isolation: isolation
            )
        case let .requestServedFromMemoryCache(id, response, initiator, resourceType, timestamp):
            await applyRequestServedFromMemoryCache(
                id: id,
                response: response,
                initiator: initiator,
                resourceType: resourceType,
                timestamp: timestamp,
                chronologySequence: chronologySequence,
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
        initiator: Network.Initiator,
        resourceType: Network.ResourceType?,
        redirectResponse: Network.Response?,
        timestamp: Double,
        chronologySequence: UInt64,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        _ = isolation
        requestStore.invalidateResourceTreeContent(replacedBy: payload)
        let id = NetworkRequest.ID(proxyID)
        guard let resolution = await requestStore.resolve(
            id: id,
            admission: .requestWillBeSent(hasRedirectResponse: redirectResponse != nil),
            create: {
                NetworkRequest(
                    request: payload,
                    initiator: initiator,
                    navigationVisit: networkNavigationVisit(for: payload),
                    resourceType: resourceType,
                    timestamp: timestamp,
                    chronologySequence: chronologySequence,
                    modelContext: modelContext
                )
            },
            isolation: isolation
        ) else {
            return
        }
        var topologyMayHaveChanged = false
        switch resolution {
        case let .existing(registration):
            let request = registration.request
            if let redirectResponse, request.isActive {
                request.applyRedirect(
                    to: payload,
                    redirectResponse: redirectResponse,
                    timestamp: timestamp,
                    resourceType: resourceType
                )
                topologyMayHaveChanged = true
            } else if request.isActive == false {
                request.applyRequestWillBeSent(
                    request: payload,
                    initiator: initiator,
                    navigationVisit: networkNavigationVisit(for: payload),
                    resourceType: resourceType,
                    timestamp: timestamp,
                    chronologySequence: chronologySequence
                )
                topologyMayHaveChanged = true
            }
            if topologyMayHaveChanged {
                await requestStore.commitUpdate(registration, isolation: isolation)
            }
        case .inserted:
            break
        }
    }

    private func networkNavigationVisit(
        for request: Network.Request
    ) -> NetworkNavigationVisit? {
        guard let origin = request.origin,
              !origin.frameID.rawValue.isEmpty,
              !origin.loaderID.isEmpty else {
            return nil
        }
        let targetID = origin.targetID.flatMap { $0.isEmpty ? nil : $0 }
        var timeline = navigationTimelines[origin.frameID]
            ?? NetworkFrameNavigationTimeline(initialLoaderID: origin.loaderID, targetID: targetID)
        let epoch = timeline.epoch(for: origin.loaderID, targetID: targetID)
        navigationTimelines[origin.frameID] = timeline
        if let targetID {
            pendingNavigationsByTargetID[targetID, default: [:]][origin.frameID] = origin.loaderID
        }
        return NetworkNavigationVisit(
            attachmentEpoch: attachmentEpoch,
            frameID: origin.frameID,
            epoch: epoch
        )
    }

    private func commitNetworkNavigation(_ frame: WebInspectorPageFrameLifecycle) {
        guard let loaderID = frame.loaderID else {
            return
        }
        commitNetworkNavigation(
            frameID: frame.id,
            loaderID: loaderID,
            targetID: frame.pageBindingID
        )
    }

    private func commitNetworkNavigation(_ commit: WebInspectorTargetCommitLifecycle) {
        guard let bindingID = commit.newTarget.pageBindingID, !bindingID.isEmpty else {
            if let frameID = commit.newTarget.frameID {
                retireNetworkNavigation(frameID: frameID)
            }
            return
        }
        guard let pendingByFrameID = pendingNavigationsByTargetID[bindingID] else {
            if let frameID = commit.newTarget.frameID,
               var timeline = navigationTimelines[frameID] {
                if timeline.bindSoleUnattributedVisit(to: bindingID) {
                    navigationTimelines[frameID] = timeline
                } else {
                    retireNetworkNavigation(frameID: frameID)
                }
            }
            return
        }
        let pending: (frameID: FrameID, loaderID: String)
        if let committedFrameID = commit.newTarget.frameID {
            guard let loaderID = pendingByFrameID[committedFrameID] else {
                skipEvent(
                    "Target.didCommitProvisionalTarget frame did not match its pending Network navigation"
                )
                return
            }
            pending = (committedFrameID, loaderID)
        } else if pendingByFrameID.count == 1,
                  let entry = pendingByFrameID.first {
            pending = (entry.key, entry.value)
        } else {
            skipEvent("Target.didCommitProvisionalTarget had ambiguous pending Network frames")
            return
        }
        commitNetworkNavigation(
            frameID: pending.frameID,
            loaderID: pending.loaderID,
            targetID: bindingID
        )
        removePendingNetworkNavigations(frameID: pending.frameID)
    }

    private func commitNetworkNavigation(
        frameID: FrameID,
        loaderID: String,
        targetID: String? = nil
    ) {
        var timeline = navigationTimelines[frameID]
            ?? NetworkFrameNavigationTimeline(initialLoaderID: loaderID, targetID: targetID)
        _ = timeline.commit(loaderID: loaderID, targetID: targetID)
        navigationTimelines[frameID] = timeline
    }

    private func retireNetworkNavigation(frameID: FrameID) {
        navigationTimelines[frameID]?.retire()
        removePendingNetworkNavigations(frameID: frameID)
    }

    private func abandonNetworkNavigation(targetID: WebInspectorTarget.ID) {
        guard targetID != .currentPage,
              let pendingByFrameID = pendingNavigationsByTargetID.removeValue(forKey: targetID.rawValue) else {
            return
        }
        for frameID in pendingByFrameID.keys {
            navigationTimelines[frameID]?.abandon(targetID: targetID.rawValue)
        }
    }

    private func removePendingNetworkNavigations(frameID: FrameID) {
        for targetID in Array(pendingNavigationsByTargetID.keys) {
            pendingNavigationsByTargetID[targetID]?.removeValue(forKey: frameID)
            if pendingNavigationsByTargetID[targetID]?.isEmpty == true {
                pendingNavigationsByTargetID.removeValue(forKey: targetID)
            }
        }
    }

    private func applyRequestServedFromMemoryCache(
        id proxyID: Network.Request.ID,
        response: Network.Response,
        initiator: Network.Initiator,
        resourceType: Network.ResourceType?,
        timestamp: Double,
        chronologySequence: UInt64,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        _ = isolation
        let id = NetworkRequest.ID(proxyID)
        guard requestStore.isTombstoned(id) == false else {
            return
        }
        if requestStore.registration(for: id) == nil, response.url == nil {
            skipEvent("Network.requestServedFromMemoryCache omitted response URL for a new request")
            return
        }
        guard let resolution = await requestStore.resolve(
            id: id,
            admission: .ordinary,
            create: {
                guard let url = response.url else {
                    preconditionFailure("A new memory-cache request must have a response URL.")
                }
                let payload = Network.Request(
                    id: proxyID,
                    url: url,
                    method: "GET",
                    headers: response.requestHeaders ?? [:],
                    origin: response.origin
                )
                let request = NetworkRequest(
                    request: payload,
                    initiator: initiator,
                    navigationVisit: networkNavigationVisit(for: payload),
                    resourceType: resourceType,
                    timestamp: timestamp,
                    chronologySequence: chronologySequence,
                    requestHeaderSource: .unavailable,
                    modelContext: modelContext
                )
                request.applyMemoryCache(
                    response: response,
                    initiator: initiator,
                    resourceType: resourceType,
                    timestamp: timestamp
                )
                return request
            },
            isolation: isolation
        ) else {
            return
        }
        switch resolution {
        case let .existing(registration):
            registration.request.applyMemoryCache(
                response: response,
                initiator: initiator,
                resourceType: resourceType,
                timestamp: timestamp
            )
            await requestStore.commitUpdate(registration, isolation: isolation)
        case .inserted:
            break
        }
    }

    private func applyResponseReceived(
        id proxyID: Network.Request.ID,
        response: Network.Response,
        resourceType: Network.ResourceType?,
        timestamp: Double,
        chronologySequence: UInt64,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        _ = isolation
        if let url = response.url {
            guard !requestStore.isClearedResourceTreeResponse(id: proxyID, url: url, origin: response.origin) else { return }
            requestStore.bindResourceTreeRequest(id: proxyID, url: url, origin: response.origin)
        }
        let id = NetworkRequest.ID(proxyID)
        guard requestStore.isTombstoned(id) == false else {
            return
        }
        if requestStore.registration(for: id) == nil, response.url == nil {
            skipEvent("Network.responseReceived omitted response URL for an untracked request")
            return
        }
        guard let resolution = await requestStore.resolve(
            id: id,
            admission: .ordinary,
            create: {
                guard let url = response.url else {
                    preconditionFailure("A response-first Network request must have a URL.")
                }
                // WebKit's frontend creates a resource here when inspection starts
                // after Network.requestWillBeSent. The response event has no method,
                // so keep the same GET default WebKit uses when serializing such a
                // resource later.
                let payload = Network.Request(
                    id: proxyID,
                    url: url,
                    method: "GET",
                    headers: response.requestHeaders ?? [:],
                    origin: response.origin
                )
                let request = NetworkRequest(
                    request: payload,
                    initiator: nil,
                    navigationVisit: networkNavigationVisit(for: payload),
                    resourceType: resourceType,
                    timestamp: timestamp,
                    chronologySequence: chronologySequence,
                    requestHeaderSource: .unavailable,
                    modelContext: modelContext
                )
                request.applyResponse(response, resourceType: resourceType, timestamp: timestamp)
                return request
            },
            isolation: isolation
        ) else {
            return
        }
        switch resolution {
        case let .existing(registration):
            registration.request.applyResponse(
                response,
                resourceType: resourceType,
                timestamp: timestamp
            )
            await requestStore.commitUpdate(registration, isolation: isolation)
        case .inserted:
            break
        }
    }

    private func apply(
        _ event: Network.WebSocketEvent,
        chronologySequence: UInt64,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        _ = isolation
        switch event {
        case let .created(id, url):
            await applyWebSocketCreated(
                id: id,
                url: url,
                chronologySequence: chronologySequence,
                modelContext: modelContext,
                isolation: isolation
            )
        case let .handshakeRequest(id, request, timestamp):
            guard let registration = networkRegistration(
                for: id,
                method: "webSocketWillSendHandshakeRequest"
            ) else {
                return
            }
            let networkRequest = registration.request
            guard networkRequest.applyWebSocketHandshakeRequest(
                request,
                timestamp: timestamp,
                chronologySequence: chronologySequence
            ) else {
                return
            }
            await requestStore.commitUpdate(registration, isolation: isolation)
        case let .handshakeResponse(id, response, timestamp):
            guard let registration = networkRegistration(
                for: id,
                method: "webSocketHandshakeResponseReceived"
            ) else {
                return
            }
            let networkRequest = registration.request
            guard networkRequest.applyWebSocketHandshakeResponse(
                response,
                timestamp: timestamp,
                chronologySequence: chronologySequence
            ) else {
                return
            }
            await requestStore.commitUpdate(registration, isolation: isolation)
        case let .frameSent(id, frame, timestamp):
            guard let registration = networkRegistration(for: id, method: "webSocketFrameSent") else {
                return
            }
            let networkRequest = registration.request
            networkRequest.appendWebSocketFrame(
                frame,
                direction: .sent,
                timestamp: timestamp,
                chronologySequence: chronologySequence
            )
            await requestStore.commitUpdate(registration, isolation: isolation)
        case let .frameReceived(id, frame, timestamp):
            guard let registration = networkRegistration(for: id, method: "webSocketFrameReceived") else {
                return
            }
            let networkRequest = registration.request
            networkRequest.appendWebSocketFrame(
                frame,
                direction: .received,
                timestamp: timestamp,
                chronologySequence: chronologySequence
            )
            await requestStore.commitUpdate(registration, isolation: isolation)
        case let .error(id, message, timestamp):
            guard let registration = networkRegistration(for: id, method: "webSocketFrameError") else {
                return
            }
            let networkRequest = registration.request
            networkRequest.appendWebSocketError(
                message,
                timestamp: timestamp,
                chronologySequence: chronologySequence
            )
            await requestStore.commitUpdate(registration, isolation: isolation)
        case let .closed(id, timestamp):
            guard let registration = networkRegistration(for: id, method: "webSocketClosed") else {
                return
            }
            let networkRequest = registration.request
            guard networkRequest.closeWebSocket(
                timestamp: timestamp,
                chronologySequence: chronologySequence
            ) else {
                return
            }
            await requestStore.commitUpdate(registration, isolation: isolation)
        case .other:
            break
        }
    }

    private func applyWebSocketCreated(
        id proxyID: Network.Request.ID,
        url: String,
        chronologySequence: UInt64,
        modelContext: WebInspectorContext,
        isolation: isolated (any Actor)
    ) async {
        _ = isolation
        let id = NetworkRequest.ID(proxyID)
        guard let resolution = await requestStore.resolve(
            id: id,
            admission: .webSocketCreated,
            create: {
                let payload = Network.Request(id: proxyID, url: url, method: "GET")
                let request = NetworkRequest(
                    request: payload,
                    initiator: nil,
                    resourceType: .webSocket,
                    timestamp: nil,
                    chronologySequence: chronologySequence,
                    requestHeaderSource: .unavailable,
                    modelContext: modelContext
                )
                request.applyWebSocketCreated(url: url, chronologySequence: chronologySequence)
                return request
            },
            isolation: isolation
        ) else {
            return
        }
        switch resolution {
        case let .existing(registration):
            registration.request.applyWebSocketCreated(
                url: url,
                chronologySequence: chronologySequence
            )
            await requestStore.commitUpdate(registration, isolation: isolation)
        case .inserted:
            break
        }
    }

    private func networkRegistration(
        for proxyID: Network.Request.ID,
        method: String
    ) -> NetworkRequestStore.Registration? {
        let id = NetworkRequest.ID(proxyID)
        guard let registration = requestStore.registration(for: id) else {
            if requestStore.isTombstoned(id) == false {
                skipEvent("Network.\(method) referenced an untracked request")
            }
            return nil
        }
        return registration
    }

    private func takeNetworkChronologySequence() -> UInt64 {
        defer { nextChronologySequence += 1 }
        return nextChronologySequence
    }

    func applyResourceTree(_ tree: Page.ResourceTree, modelContext: WebInspectorContext) {
        struct ResourceKey: Hashable {
            let frameID: FrameID
            let loaderID: String
            let visit: NetworkNavigationVisit?
            let url: String
        }
        var knownResources = Set(requestStore.requests.compactMap { request -> ResourceKey? in
            guard let origin = request.origin, request.resourceContentLocation != .unavailable else { return nil }
            return ResourceKey(
                frameID: origin.frameID, loaderID: origin.loaderID,
                visit: request.navigationVisit, url: request.responseURL ?? request.url
            )
        })
        var restoredRequests: [NetworkRequest] = []
        func add(
            url: String,
            type: String,
            mimeType: String,
            failed: Bool = false,
            canceled: Bool = false,
            sourceMapURL: String? = nil,
            frame: Page.ResourceTree.Frame
        ) {
            let frameID = FrameID(frame.id)
            // Resource-tree entries have no protocol request ID. Keep their UI
            // identity stable if a later response supplies that backend identity.
            let payload = Network.Request(
                id: Network.Request.ID("resource-tree:\(UUID().uuidString)"),
                url: url,
                method: "GET",
                origin: .init(frameID: frameID, loaderID: frame.loaderId, targetID: nil)
            )
            let navigationVisit = networkNavigationVisit(for: payload)
            let key = ResourceKey(frameID: frameID, loaderID: frame.loaderId, visit: navigationVisit, url: url)
            guard knownResources.insert(key).inserted else { return }
            let request = NetworkRequest(
                request: payload,
                initiator: nil,
                navigationVisit: navigationVisit,
                resourceType: Network.ResourceType(rawValue: type),
                timestamp: nil,
                chronologySequence: takeNetworkChronologySequence(),
                requestHeaderSource: .unavailable,
                modelContext: modelContext
            )
            request.applyResourceTreeMetadata(
                frameID: frameID, mimeType: mimeType, failed: failed,
                canceled: canceled, sourceMapURL: sourceMapURL
            )
            restoredRequests.append(request)
        }
        func visit(_ tree: Page.ResourceTree) {
            add(url: tree.frame.url.isEmpty ? "about:blank" : tree.frame.url,
                type: "Document", mimeType: tree.frame.mimeType, frame: tree.frame)
            for child in tree.childFrames ?? [] { visit(child) }
            for resource in tree.resources {
                add(url: resource.url, type: resource.type, mimeType: resource.mimeType,
                    failed: resource.failed == true, canceled: resource.canceled == true,
                    sourceMapURL: resource.sourceMapURL, frame: tree.frame)
            }
        }
        visit(tree)
        requestStore.insertResourceTreeRequests(restoredRequests)
    }
}
