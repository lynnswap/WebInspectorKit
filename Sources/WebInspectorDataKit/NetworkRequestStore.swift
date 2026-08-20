import Observation
import WebInspectorProxyKit

@Observable
package final class NetworkRequestStore {
    struct Registration {
        let request: NetworkRequest
        let orderIndex: Int
        private let generation: UInt64

        fileprivate init(request: NetworkRequest, orderIndex: Int, generation: UInt64) {
            self.request = request
            self.orderIndex = orderIndex
            self.generation = generation
        }

        fileprivate func belongs(to generation: ProjectionGeneration) -> Bool {
            self.generation == generation.id
        }
    }

    struct Change {
        let registration: Registration
        let projectionGeneration: ProjectionGeneration
        let isInsertion: Bool

        fileprivate init(
            registration: Registration,
            projectionGeneration: ProjectionGeneration,
            isInsertion: Bool
        ) {
            self.registration = registration
            self.projectionGeneration = projectionGeneration
            self.isInsertion = isInsertion
        }

        var publishesContentUpdate: Bool {
            isInsertion == false
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

    struct ProjectionGeneration {
        let id: UInt64
        let ledger: WebInspectorFetchedResultsSingleSectionSnapshotLedger<NetworkRequest.ID>
    }

    private struct IndexedResultCommit {
        let registrationID: UInt64
        let results: WebInspectorFetchedResults<NetworkRequest>
        let plan: NetworkRequestQueryPlan
        let sectionBy: NetworkRequestQuery.Section?
        let oldSnapshot: WebInspectorFetchedResultsSnapshot<NetworkRequest.ID>
        let topologyRevision: Int
        let changedIDs: Set<NetworkRequest.ID>

        var input: NetworkResultProjectionInput {
            NetworkResultProjectionInput(
                plan: plan,
                sectionBy: sectionBy,
                oldSnapshot: oldSnapshot,
                changedIDs: changedIDs
            )
        }
    }

    private struct FetchedResultRegistration {
        let id: UInt64
        let weakReference: WeakWebInspectorFetchedResults<NetworkRequest>
    }

    private var orderedRegistrations: [Registration]
    @ObservationIgnored private var registrationsByID: [NetworkRequest.ID: Registration]
    @ObservationIgnored private var tombstonedIDs: Set<NetworkRequest.ID>
    @ObservationIgnored private var generation: UInt64
    @ObservationIgnored private var ledger: WebInspectorFetchedResultsSingleSectionSnapshotLedger<NetworkRequest.ID>
    @ObservationIgnored private var index: NetworkRequestIndexClient
    @ObservationIgnored private let indexFactory: () -> NetworkRequestIndexClient
    @ObservationIgnored private var indexSequence: UInt64
    @ObservationIgnored private var indexNeedsRebuild: Bool
    @ObservationIgnored private var activeIndexSequences: Set<UInt64>
    @ObservationIgnored private var pendingChangedIDsByResult: [UInt64: Set<NetworkRequest.ID>]
    @ObservationIgnored private var fetchedResults: [FetchedResultRegistration]
    @ObservationIgnored private var nextFetchedResultRegistrationID: UInt64

    init(indexFactory: @escaping () -> NetworkRequestIndexClient = { .live() }) {
        orderedRegistrations = []
        registrationsByID = [:]
        tombstonedIDs = []
        generation = 0
        ledger = WebInspectorFetchedResultsSingleSectionSnapshotLedger(itemIDs: [])
        self.indexFactory = indexFactory
        index = indexFactory()
        indexSequence = 0
        indexNeedsRebuild = false
        activeIndexSequences = []
        pendingChangedIDsByResult = [:]
        fetchedResults = []
        nextFetchedResultRegistrationID = 0
    }

    package var hasRequests: Bool {
        orderedRegistrations.isEmpty == false
    }

    var requestCount: Int {
        orderedRegistrations.count
    }

    func resolve(
        id: NetworkRequest.ID,
        admission: Admission,
        create: () -> NetworkRequest,
        isolation: isolated (any Actor)
    ) async -> Resolution? {
        _ = isolation
        guard prepareAdmission(for: id, admission: admission) else {
            return nil
        }
        if let registration = registrationsByID[id] {
            return .existing(registration)
        }
        let request = create()
        precondition(request.id == id, "A Network request must be registered under its own ID.")
        let registration = register(request)
        let change = makeChange(registration, isInsertion: true)
        publishSynchronousPrefix(change)
        await commitIndexed(change, isolation: isolation)
        guard isCurrent(registration) else {
            return nil
        }
        return .inserted(registration)
    }

    func resolveSynchronously(
        id: NetworkRequest.ID,
        admission: Admission,
        create: () -> NetworkRequest
    ) -> Resolution? {
        guard prepareAdmission(for: id, admission: admission) else {
            return nil
        }
        if let registration = registrationsByID[id] {
            return .existing(registration)
        }
        let request = create()
        precondition(request.id == id, "A Network request must be registered under its own ID.")
        let registration = register(request)
        commitSynchronously(makeChange(registration, isInsertion: true))
        return .inserted(registration)
    }

    func commitUpdate(
        _ registration: Registration,
        isolation: isolated (any Actor)
    ) async {
        _ = isolation
        guard isCurrent(registration) else {
            return
        }
        let change = makeChange(registration, isInsertion: false)
        publishSynchronousPrefix(change)
        await commitIndexed(change, isolation: isolation)
    }

    func commitUpdateSynchronously(_ registration: Registration) {
        guard isCurrent(registration) else {
            return
        }
        commitSynchronously(makeChange(registration, isInsertion: false))
    }

    func makeFetchedResults(
        query: NetworkRequestQuery,
        modelContext: WebInspectorContext
    ) -> WebInspectorFetchedResults<NetworkRequest> {
        let results = WebInspectorFetchedResults<NetworkRequest>(
            query: query,
            generation: projectionGeneration,
            modelContext: modelContext
        )
        let plan = NetworkRequestQueryPlan(query: query)
        results.setNetworkItems(
            requests,
            plan: plan,
            generation: projectionGeneration
        )
        let registrationID = takeFetchedResultRegistrationID()
        fetchedResults.append(
            FetchedResultRegistration(
                id: registrationID,
                weakReference: WeakWebInspectorFetchedResults(results)
            ))
        return results
    }

    func updateQuery(
        _ query: NetworkRequestQuery,
        for results: WebInspectorFetchedResults<NetworkRequest>
    ) {
        if let registration = fetchedResults.first(where: {
            $0.weakReference.value === results
        }) {
            pendingChangedIDsByResult[registration.id] = nil
        }
        let plan = NetworkRequestQueryPlan(query: query)
        results.applyNetworkQuery(
            query,
            plan: plan,
            requests: requests,
            generation: projectionGeneration
        )
    }

    func invalidateFetchedResultsRegistrations() {
        let results = fetchedResults.compactMap(\.weakReference.value)
        fetchedResults.removeAll(keepingCapacity: false)
        for results in results {
            results.invalidateRegistration()
        }
    }

    #if DEBUG
        func fullProjectionRecordVisitCount(
            isolation: isolated (any Actor)
        ) async -> Int {
            _ = isolation
            return await index.fullProjectionRecordVisitCount()
        }

        var indexSequenceForTesting: UInt64 {
            indexSequence
        }
    #endif

    var projectionGeneration: ProjectionGeneration {
        ProjectionGeneration(id: generation, ledger: ledger)
    }

    var requests: [NetworkRequest] {
        orderedRegistrations.map(\.request)
    }

    var registrations: [Registration] {
        orderedRegistrations
    }

    func registration(for id: NetworkRequest.ID) -> Registration? {
        registrationsByID[id]
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
        _ = ledger.append(request.id, expectedCount: registration.orderIndex)
        registrationsByID[request.id] = registration
        orderedRegistrations.append(registration)
        return registration
    }

    func isCurrent(_ registration: Registration) -> Bool {
        guard registration.belongs(to: projectionGeneration),
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

    @discardableResult
    func reset(for reason: ResetReason) -> ProjectionGeneration {
        switch reason {
        case .userClear:
            tombstonedIDs.formUnion(orderedRegistrations.map { $0.request.id })
        case .newAttachment:
            tombstonedIDs.removeAll(keepingCapacity: false)
        }
        for registration in orderedRegistrations {
            registration.request.invalidateResponseBodyFetch()
        }
        let (nextGeneration, overflow) = generation.addingReportingOverflow(1)
        precondition(!overflow, "Network request store generation exhausted.")
        generation = nextGeneration
        orderedRegistrations = []
        registrationsByID = [:]
        ledger = WebInspectorFetchedResultsSingleSectionSnapshotLedger(itemIDs: [])
        indexNeedsRebuild = true
        nextIndexSequence()
        index = indexFactory()
        activeIndexSequences.removeAll(keepingCapacity: false)
        pendingChangedIDsByResult.removeAll(keepingCapacity: false)
        pruneFetchedResults()
        let currentGeneration = projectionGeneration
        for results in fetchedResults.compactMap(\.weakReference.value) {
            results.resetNetworkItems(to: currentGeneration)
        }
        return projectionGeneration
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

    private func makeChange(_ registration: Registration, isInsertion: Bool) -> Change {
        Change(
            registration: registration,
            projectionGeneration: projectionGeneration,
            isInsertion: isInsertion
        )
    }

    private func commitSynchronously(_ change: Change) {
        guard isCurrent(change.registration) else {
            return
        }
        let supersedesIndexedWork =
            activeIndexSequences.isEmpty == false
            || pendingChangedIDsByResult.isEmpty == false
        indexNeedsRebuild = true
        nextIndexSequence()
        publishSynchronousPrefix(change)
        pruneFetchedResults()
        var indexedResults: [WebInspectorFetchedResults<NetworkRequest>] = []
        for results in fetchedResults.compactMap(\.weakReference.value) {
            if results.usesUnfilteredNetworkProjection == false {
                indexedResults.append(results)
            }
        }
        guard indexedResults.isEmpty == false else {
            pendingChangedIDsByResult.removeAll(keepingCapacity: true)
            return
        }
        let allRequests = requests
        for results in indexedResults {
            if supersedesIndexedWork {
                results.resetSynchronousIndexedNetworkItems(allRequests)
            } else {
                results.applySynchronousIndexedNetworkChange(
                    change,
                    allRequests: allRequests
                )
            }
        }
        if supersedesIndexedWork {
            pendingChangedIDsByResult.removeAll(keepingCapacity: true)
        }
    }

    private func publishSynchronousPrefix(_ change: Change) {
        pruneFetchedResults()
        for results in fetchedResults.compactMap(\.weakReference.value)
        where results.usesUnfilteredNetworkProjection {
            results.applyUnfilteredNetworkChange(change)
        }
    }

    private func commitIndexed(
        _ change: Change,
        isolation: isolated (any Actor)
    ) async {
        _ = isolation
        guard isCurrent(change.registration) else {
            return
        }
        pruneFetchedResults()
        let indexedResults = fetchedResults.compactMap { registration in
            registration.weakReference.value.map { (registration.id, $0) }
        }.filter {
            $0.1.usesUnfilteredNetworkProjection == false
        }
        guard indexedResults.isEmpty == false else {
            indexNeedsRebuild = true
            nextIndexSequence()
            pendingChangedIDsByResult.removeAll(keepingCapacity: true)
            return
        }
        let resultCommits = indexedResults.map { registrationID, results in
            pendingChangedIDsByResult[registrationID, default: []].insert(
                change.registration.request.id
            )
            return IndexedResultCommit(
                registrationID: registrationID,
                results: results,
                plan: results.currentNetworkQueryPlan(),
                sectionBy: results.networkQuery.sectionBy,
                oldSnapshot: results.networkSnapshotForDelta,
                topologyRevision: results.topologyRevision,
                changedIDs: pendingChangedIDsByResult[registrationID] ?? []
            )
        }
        let currentIndex = index
        let requiresReplacement = indexNeedsRebuild || activeIndexSequences.isEmpty == false
        let replacementInputs =
            requiresReplacement
            ? registrations.map(NetworkRequestRecordInput.init)
            : []
        let sequence = nextIndexSequence()
        activeIndexSequences.insert(sequence)
        if requiresReplacement {
            indexNeedsRebuild = false
            await currentIndex.replace(with: replacementInputs, sequence: sequence)
        } else {
            await currentIndex.upsert(
                NetworkRequestRecordInput(registration: change.registration),
                sequence: sequence
            )
        }
        guard currentIndex.identity === index.identity,
            indexSequence == sequence,
            isCurrent(change.registration)
        else {
            activeIndexSequences.remove(sequence)
            return
        }
        let deltas = await currentIndex.deltas(
            for: resultCommits.map(\.input),
            sequence: sequence
        )
        activeIndexSequences.remove(sequence)
        guard currentIndex.identity === index.identity,
            indexSequence == sequence,
            isCurrent(change.registration),
            let deltas
        else {
            return
        }
        for (commit, delta) in zip(resultCommits, deltas) {
            defer {
                pendingChangedIDsByResult[commit.registrationID]?.subtract(commit.changedIDs)
                if pendingChangedIDsByResult[commit.registrationID]?.isEmpty == true {
                    pendingChangedIDsByResult[commit.registrationID] = nil
                }
            }
            guard commit.results.usesUnfilteredNetworkProjection == false,
                commit.results.topologyRevision == commit.topologyRevision,
                commit.results.networkSnapshotForDelta == commit.oldSnapshot
            else {
                continue
            }
            guard let delta else {
                continue
            }
            commit.results.applyNetworkDelta(delta, lookup: requiredRequest(for:))
        }
    }

    private func requiredRequest(for id: NetworkRequest.ID) -> NetworkRequest {
        guard let request = registrationsByID[id]?.request else {
            preconditionFailure("An indexed Network result must reference a registered request.")
        }
        return request
    }

    private func pruneFetchedResults() {
        fetchedResults.removeAll { $0.weakReference.value == nil }
        let retainedResultIDs = Set(fetchedResults.map(\.id))
        pendingChangedIDsByResult = pendingChangedIDsByResult.filter { resultID, _ in
            retainedResultIDs.contains(resultID)
        }
    }

    private func takeFetchedResultRegistrationID() -> UInt64 {
        precondition(
            nextFetchedResultRegistrationID < UInt64.max,
            "Network fetched-result registration identity exhausted."
        )
        defer { nextFetchedResultRegistrationID += 1 }
        return nextFetchedResultRegistrationID
    }

    @discardableResult
    private func nextIndexSequence() -> UInt64 {
        precondition(indexSequence < UInt64.max, "Network request index sequence exhausted.")
        indexSequence += 1
        return indexSequence
    }
}
