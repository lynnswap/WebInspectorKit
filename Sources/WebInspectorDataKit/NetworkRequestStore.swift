import Observation
import WebInspectorProxyKit

@Observable
@MainActor
package final class NetworkRequestStore {
    private struct ResourceTreeKey: Hashable {
        let frameID: FrameID
        let loaderID: String
        let url: String

        init(url: String, origin: Network.Request.Origin) {
            frameID = origin.frameID
            loaderID = origin.loaderID
            self.url = url
        }
    }
    struct Registration {
        let request: NetworkRequest
        let orderIndex: Int
        private let generation: UInt64

        fileprivate init(request: NetworkRequest, orderIndex: Int, generation: UInt64) {
            self.request = request
            self.orderIndex = orderIndex
            self.generation = generation
        }

        fileprivate func belongs(to generation: UInt64) -> Bool {
            self.generation == generation
        }
    }

    enum Resolution {
        case existing(Registration)
        case inserted(Registration)

        var registration: Registration {
            switch self {
            case let .existing(registration), let .inserted(registration):
                registration
            }
        }
    }

    enum Admission {
        case ordinary
        case requestWillBeSent(hasRedirectResponse: Bool)
        case webSocketCreated
    }

    enum ResetReason {
        case userClear
        case newAttachment
    }

    private var orderedRegistrations: [Registration]
    @ObservationIgnored private var registrationsByID: [NetworkRequest.ID: Registration]
    @ObservationIgnored private var requestAliases: [NetworkRequest.ID: NetworkRequest.ID] = [:]
    @ObservationIgnored private var clearedResourceTreeKeys: Set<ResourceTreeKey> = []
    @ObservationIgnored private var pendingResourceTreeRequests: [ResourceTreeKey: NetworkRequest.ID] = [:]
    @ObservationIgnored private var tombstonedIDs: Set<NetworkRequest.ID>
    /// Advances whenever the collection is reset.
    @ObservationIgnored private(set) var generation: UInt64
    @ObservationIgnored private let changeRelay = WebInspectorAsyncStreamRelay<WebInspectorCollectionChange<NetworkRequest>>()

    init() {
        orderedRegistrations = []
        registrationsByID = [:]
        tombstonedIDs = []
        generation = 0
    }

    /// The changes to `requests`, starting from the moment of the call.
    var changes: AsyncStream<WebInspectorCollectionChange<NetworkRequest>> {
        changeRelay.makeStream()
    }

    package var hasRequests: Bool {
        orderedRegistrations.isEmpty == false
    }

    var requestCount: Int {
        orderedRegistrations.count
    }

    /// Returns the registration for `id`, creating the request when the
    /// identifier is admitted and not yet registered.
    func resolve(
        id: NetworkRequest.ID,
        admission: Admission,
        create: () -> NetworkRequest
    ) -> Resolution? {
        guard prepareAdmission(for: id, admission: admission) else {
            return nil
        }
        if let registration = registration(for: id) {
            return .existing(registration)
        }
        let request = create()
        precondition(request.id == id, "A Network request must be registered under its own ID.")
        let registration = register(request)
        changeRelay.yield(.inserted([request]))
        return .inserted(registration)
    }

    /// Publishes that a registered request changed.
    func commitUpdate(_ registration: Registration) {
        guard isCurrent(registration) else {
            return
        }
        changeRelay.yield(.updated([registration.request]))
    }

    func insertResourceTreeRequests(_ newRequests: [NetworkRequest]) {
        guard !newRequests.isEmpty else { return }
        for request in newRequests { _ = register(request) }
        changeRelay.yield(.inserted(newRequests))
    }

    func invalidateResourceTreeContent(replacedBy request: Network.Request) {
        guard let origin = request.origin else { return }
        let key = ResourceTreeKey(url: request.url, origin: origin)
        if let id = pendingResourceTreeRequests[key] {
            registration(for: id)?.request.invalidateResourceTreeContent()
        }
    }

    func invalidateResourceTreeContent(frameID: FrameID? = nil, keepingLoaderID: String? = nil) {
        for key in Array(pendingResourceTreeRequests.keys)
        where (frameID == nil || key.frameID == frameID) && key.loaderID != keepingLoaderID {
            if let id = pendingResourceTreeRequests.removeValue(forKey: key) {
                registration(for: id)?.request.invalidateResourceTreeContent()
            }
        }
    }

    var requests: [NetworkRequest] {
        orderedRegistrations.map(\.request)
    }

    func registration(for id: NetworkRequest.ID) -> Registration? {
        registrationsByID[requestAliases[id] ?? id]
    }

    func bindResourceTreeRequest(
        id: Network.Request.ID,
        url: String,
        origin: Network.Request.Origin?
    ) {
        let modelID = NetworkRequest.ID(id)
        guard registration(for: modelID) == nil, !isTombstoned(modelID), let origin else {
            return
        }
        let key = ResourceTreeKey(url: url, origin: origin)
        guard let snapshotID = pendingResourceTreeRequests.removeValue(forKey: key),
              let registration = registration(for: snapshotID) else {
            return
        }
        requestAliases[modelID] = registration.request.id
        registration.request.bindResourceTreeRequest(to: id)
    }

    func isClearedResourceTreeResponse(id: Network.Request.ID, url: String, origin: Network.Request.Origin?) -> Bool {
        guard registration(forProxyID: id) == nil, let origin else { return false }
        return clearedResourceTreeKeys.contains(ResourceTreeKey(url: url, origin: origin))
    }

    func registration(forProxyID id: Network.Request.ID) -> Registration? {
        registration(for: NetworkRequest.ID(id))
    }

    private func register(_ request: NetworkRequest) -> Registration {
        precondition(
            registrationsByID[request.id] == nil,
            "A Network request can only be registered once per store generation."
        )
        precondition(
            tombstonedIDs.contains(request.id) == false,
            "A tombstoned Network request must begin a new lifecycle before registration."
        )
        let registration = Registration(
            request: request,
            orderIndex: orderedRegistrations.count,
            generation: generation
        )
        registrationsByID[request.id] = registration
        orderedRegistrations.append(registration)
        if request.resourceContentFrameID != nil, let origin = request.origin {
            let key = ResourceTreeKey(url: request.url, origin: origin)
            clearedResourceTreeKeys.remove(key)
            pendingResourceTreeRequests[key] = request.id
        }
        return registration
    }

    func isCurrent(_ registration: Registration) -> Bool {
        guard registration.belongs(to: generation),
            orderedRegistrations.indices.contains(registration.orderIndex)
        else {
            return false
        }
        return orderedRegistrations[registration.orderIndex].request === registration.request
    }

    func isCurrent(_ request: NetworkRequest) -> Bool {
        guard let registration = registrationsByID[request.id] else {
            return false
        }
        return registration.request === request
    }

    func isTombstoned(_ id: NetworkRequest.ID) -> Bool {
        tombstonedIDs.contains(id)
    }

    func reset(for reason: ResetReason) {
        switch reason {
        case .userClear:
            tombstonedIDs.formUnion(orderedRegistrations.map { $0.request.id })
            tombstonedIDs.formUnion(requestAliases.keys)
            for registration in orderedRegistrations {
                let request = registration.request
                if request.resourceContentLocation != nil, let origin = request.origin {
                    clearedResourceTreeKeys.insert(ResourceTreeKey(url: request.url, origin: origin))
                }
            }
        case .newAttachment:
            tombstonedIDs.removeAll(keepingCapacity: false)
            clearedResourceTreeKeys = []
        }
        for registration in orderedRegistrations {
            registration.request.invalidateResponseBodyFetch()
        }
        generation += 1
        orderedRegistrations = []
        registrationsByID = [:]
        requestAliases = [:]
        pendingResourceTreeRequests = [:]
        changeRelay.yield(.removedAll)
    }

    private func prepareAdmission(for id: NetworkRequest.ID, admission: Admission) -> Bool {
        switch admission {
        case .ordinary:
            return tombstonedIDs.contains(id) == false
        case let .requestWillBeSent(hasRedirectResponse):
            guard tombstonedIDs.contains(id) else {
                return true
            }
            guard hasRedirectResponse == false else {
                return false
            }
            tombstonedIDs.remove(id)
            return true
        case .webSocketCreated:
            tombstonedIDs.remove(id)
            return true
        }
    }
}
