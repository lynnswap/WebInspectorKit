import Foundation
import Observation
import Synchronization
import WebInspectorDataKit
import WebInspectorUIBase

private struct NetworkStatusSeverityCounts {
    private var success = 0
    private var notice = 0
    private var warning = 0
    private var error = 0
    private var neutral = 0

    mutating func insert(_ severity: NetworkDisplay.StatusSeverity) {
        switch severity {
        case .success: success += 1
        case .notice: notice += 1
        case .warning: warning += 1
        case .error: error += 1
        case .neutral: neutral += 1
        }
    }

    mutating func remove(_ severity: NetworkDisplay.StatusSeverity) {
        switch severity {
        case .success:
            precondition(success > 0, "Network entry success severity count underflowed.")
            success -= 1
        case .notice:
            precondition(notice > 0, "Network entry notice severity count underflowed.")
            notice -= 1
        case .warning:
            precondition(warning > 0, "Network entry warning severity count underflowed.")
            warning -= 1
        case .error:
            precondition(error > 0, "Network entry error severity count underflowed.")
            error -= 1
        case .neutral:
            precondition(neutral > 0, "Network entry neutral severity count underflowed.")
            neutral -= 1
        }
    }

    var highest: NetworkDisplay.StatusSeverity {
        if error > 0 { return .error }
        if warning > 0 { return .warning }
        if notice > 0 { return .notice }
        if success > 0 { return .success }
        return .neutral
    }
}

@MainActor
@Observable
package final class NetworkListEntry: Identifiable {
    package struct ID: Hashable, Sendable {
        private enum Storage: Hashable, Sendable {
            case group(visit: NetworkNavigationVisit, initiatorNodeID: String)
            case singleton(NetworkRequest.ID)
        }

        private let storage: Storage

        fileprivate static func group(
            visit: NetworkNavigationVisit,
            initiatorNodeID: String
        ) -> ID {
            ID(storage: .group(visit: visit, initiatorNodeID: initiatorNodeID))
        }

        fileprivate static func singleton(_ requestID: NetworkRequest.ID) -> ID {
            ID(storage: .singleton(requestID))
        }
    }

    package let id: ID
    package private(set) var requests: [NetworkRequest]
    package private(set) var statusSeverity: NetworkDisplay.StatusSeverity

    @ObservationIgnored fileprivate var chronologyTimestamp: Double?
    @ObservationIgnored fileprivate var chronologySequence: UInt64
    @ObservationIgnored private var statusSeverityCounts: NetworkStatusSeverityCounts

    fileprivate init(
        id: ID,
        request: NetworkRequest,
        chronologyTimestamp: Double?,
        chronologySequence: UInt64
    ) {
        self.id = id
        requests = [request]
        var statusSeverityCounts = NetworkStatusSeverityCounts()
        statusSeverityCounts.insert(request.statusSeverity)
        self.statusSeverityCounts = statusSeverityCounts
        statusSeverity = statusSeverityCounts.highest
        self.chronologyTimestamp = chronologyTimestamp
        self.chronologySequence = chronologySequence
    }

    package var representativeRequest: NetworkRequest {
        guard let request = requests.first else {
            preconditionFailure("A Network list entry must own at least one request.")
        }
        return request
    }

    fileprivate func replaceRequests(_ requests: [NetworkRequest]) {
        precondition(requests.isEmpty == false, "A Network list entry must own at least one request.")
        self.requests = requests
    }

    fileprivate func appendRequest(_ request: NetworkRequest) {
        insertStatusSeverity(request.statusSeverity)
        requests.append(request)
    }

    fileprivate func insertRequest(_ request: NetworkRequest, at index: Int) {
        insertStatusSeverity(request.statusSeverity)
        requests.insert(request, at: index)
    }

    fileprivate func replaceRequest(at index: Int, with request: NetworkRequest) {
        requests[index] = request
    }

    fileprivate func replaceChronology(timestamp: Double?, sequence: UInt64) {
        chronologyTimestamp = timestamp
        chronologySequence = sequence
    }

    fileprivate func updateStatusSeverity(
        from oldSeverity: NetworkDisplay.StatusSeverity,
        to newSeverity: NetworkDisplay.StatusSeverity
    ) {
        guard oldSeverity != newSeverity else {
            return
        }
        statusSeverityCounts.remove(oldSeverity)
        statusSeverityCounts.insert(newSeverity)
        statusSeverity = statusSeverityCounts.highest
    }

    fileprivate func removeStatusSeverity(_ severity: NetworkDisplay.StatusSeverity) {
        statusSeverityCounts.remove(severity)
        statusSeverity = statusSeverityCounts.highest
    }

    private func insertStatusSeverity(_ severity: NetworkDisplay.StatusSeverity) {
        statusSeverityCounts.insert(severity)
        statusSeverity = statusSeverityCounts.highest
    }
}

package struct NetworkPanelListVersion: Equatable, Sendable {
    package let revision: UInt64
    package let entryIdentityGeneration: UInt64
}

package struct NetworkPanelListInvalidation: Equatable, Sendable {
    package let version: NetworkPanelListVersion
}

package struct NetworkPanelListProjection: Equatable, Sendable {
    package let version: NetworkPanelListVersion
    package let entryIDs: [NetworkListEntry.ID]
}

enum NetworkPanelSelection: Equatable, Sendable {
    case entry(NetworkListEntry.ID)
    case request(entryID: NetworkListEntry.ID, requestID: NetworkRequest.ID)

    var entryID: NetworkListEntry.ID {
        switch self {
        case .entry(let entryID), .request(let entryID, _):
            entryID
        }
    }
}

enum NetworkPanelSelectionIntent {
    struct ID: Equatable, Hashable, Sendable {
        fileprivate let rawValue: UInt64
    }
}

@MainActor
struct NetworkDetailSubject {
    enum Scope: Equatable, Sendable {
        case entry
        case request
    }

    private enum Storage {
        case entry(NetworkListEntry)
        case request(entry: NetworkListEntry, request: NetworkRequest)
    }

    let intentID: NetworkPanelSelectionIntent.ID
    private let storage: Storage

    fileprivate init(
        entry: NetworkListEntry,
        intentID: NetworkPanelSelectionIntent.ID
    ) {
        storage = .entry(entry)
        self.intentID = intentID
    }

    fileprivate init(
        entry: NetworkListEntry,
        request: NetworkRequest,
        intentID: NetworkPanelSelectionIntent.ID
    ) {
        storage = .request(entry: entry, request: request)
        self.intentID = intentID
    }

    var scope: Scope {
        switch storage {
        case .entry:
            .entry
        case .request:
            .request
        }
    }

    var entry: NetworkListEntry {
        switch storage {
        case .entry(let entry), .request(let entry, _):
            entry
        }
    }

    var activeRequest: NetworkRequest {
        switch storage {
        case .entry(let entry):
            entry.representativeRequest
        case .request(_, let request):
            request
        }
    }

    var renderRequests: [NetworkRequest] {
        switch storage {
        case .entry(let entry):
            entry.requests
        case .request(_, let request):
            [request]
        }
    }

    var entryRequests: [NetworkRequest] {
        entry.requests
    }

    var selection: NetworkPanelSelection {
        switch storage {
        case .entry(let entry):
            .entry(entry.id)
        case .request(let entry, let request):
            .request(entryID: entry.id, requestID: request.id)
        }
    }

    func hasSameIdentity(as other: Self) -> Bool {
        guard intentID == other.intentID else {
            return false
        }
        switch (storage, other.storage) {
        case let (.entry(lhsEntry), .entry(rhsEntry)):
            return lhsEntry === rhsEntry
        case let (.request(lhsEntry, lhsRequest), .request(rhsEntry, rhsRequest)):
            return lhsEntry === rhsEntry && lhsRequest === rhsRequest
        case (.entry, .request), (.request, .entry):
            return false
        }
    }
}

private final class NetworkPanelListInvalidationRelay: Sendable {
    private struct State {
        var continuations: [UUID: AsyncStream<NetworkPanelListInvalidation>.Continuation] = [:]
        var isFinished = false
    }

    private let state = Mutex(State())

    func makeStream() -> AsyncStream<NetworkPanelListInvalidation> {
        let id = UUID()
        let pair = AsyncStream<NetworkPanelListInvalidation>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let shouldFinish = state.withLock { state in
            guard state.isFinished == false else {
                return true
            }
            state.continuations[id] = pair.continuation
            return false
        }
        if shouldFinish {
            pair.continuation.finish()
            return pair.stream
        }
        pair.continuation.onTermination = { [weak self] _ in
            self?.removeStream(id)
        }
        return pair.stream
    }

    func yield(_ invalidation: NetworkPanelListInvalidation) {
        let continuations = state.withLock { Array($0.continuations.values) }
        for continuation in continuations {
            continuation.yield(invalidation)
        }
    }

    func finish() {
        let continuations = state.withLock { state -> [AsyncStream<NetworkPanelListInvalidation>.Continuation] in
            guard state.isFinished == false else {
                return []
            }
            state.isFinished = true
            let continuations = Array(state.continuations.values)
            state.continuations.removeAll(keepingCapacity: false)
            return continuations
        }
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeStream(_ id: UUID) {
        state.withLock { state in
            state.continuations.removeValue(forKey: id)
        }?.finish()
    }

    deinit {
        finish()
    }
}

@MainActor
@Observable
package final class NetworkPanelModel {
    private struct RequestCreationMetadata {
        var timestamp: Double?
        var sequence: UInt64
        var lifecycleRevision: UInt64
    }

    private struct RequestRegistration {
        var request: NetworkRequest
        var entry: NetworkListEntry
        var statusSeverity: NetworkDisplay.StatusSeverity
        var creation: RequestCreationMetadata
    }

    package let context: WebInspectorContext
    package let requests: WebInspectorFetchedResults<NetworkRequest>
    private let fetchedResultsController: WebInspectorFetchedResultsController<NetworkRequest>
    private let collectionState: NetworkRequestStore

    private(set) var detailSubject: NetworkDetailSubject?
    package private(set) var searchText = ""
    package private(set) var activeResourceFilters: Set<NetworkDisplay.ResourceFilter> = []

    @ObservationIgnored private let listInvalidationRelay = NetworkPanelListInvalidationRelay()
    @ObservationIgnored private var fetchedResultsTransactionTask: Task<Void, Never>?
    @ObservationIgnored private var entriesByID: [NetworkListEntry.ID: NetworkListEntry] = [:]
    @ObservationIgnored private var registrationsByRequestID: [NetworkRequest.ID: RequestRegistration] = [:]
    @ObservationIgnored private var orderedEntryIDs: [NetworkListEntry.ID] = []
    @ObservationIgnored private var visibleEntryIDs: [NetworkListEntry.ID] = []
    @ObservationIgnored private var visibleEntryIDSet: Set<NetworkListEntry.ID> = []
    @ObservationIgnored private var nextListTransactionRevision: UInt64 = 0
    @ObservationIgnored private var listEntryIdentityGeneration: UInt64 = 0
    @ObservationIgnored private var nextSelectionIntentID: UInt64 = 0
#if DEBUG
    private struct RawTransactionDeliveryWaiter {
        var id: Int
        var baselineCount: Int
        var continuation: CheckedContinuation<Bool, Never>
        var timeoutTask: Task<Void, Never>
    }

    @ObservationIgnored private var rawTransactionDeliveryCountStorageForTesting = 0
    @ObservationIgnored private var fullEntryRebuildCountStorageForTesting = 0
    @ObservationIgnored private var filterEvaluationCountStorageForTesting = 0
    @ObservationIgnored private var memberTraversalCountStorageForTesting = 0
    @ObservationIgnored private var requestOrderComparisonCountStorageForTesting = 0
    @ObservationIgnored private var listTransactionPublicationCountStorageForTesting = 0
    @ObservationIgnored private var lastListInvalidationStorageForTesting: NetworkPanelListInvalidation?
    @ObservationIgnored private var rawTransactionDeliveryWaitersForTesting: [RawTransactionDeliveryWaiter] = []
    @ObservationIgnored private var rawTransactionDeliveryWaiterIDStorageForTesting = 0
#endif

    package init(context: WebInspectorContext) {
        self.context = context
        let requests: WebInspectorFetchedResults<NetworkRequest> = context.network.fetchedResults()
        self.requests = requests
        fetchedResultsController = WebInspectorFetchedResultsController(fetchedResults: requests)
        collectionState = context.networkRequestsCollectionState
        rebuildEntries(from: requests.items)
        startObservingFetchedResultsTransactions()
    }

    isolated deinit {
        fetchedResultsTransactionTask?.cancel()
        listInvalidationRelay.finish()
#if DEBUG
        resolveRawTransactionDeliveryWaitersForTesting(result: false)
#endif
    }

    package var listInvalidations: AsyncStream<NetworkPanelListInvalidation> {
        listInvalidationRelay.makeStream()
    }

    package var listProjectionVersion: NetworkPanelListVersion {
        NetworkPanelListVersion(
            revision: nextListTransactionRevision,
            entryIdentityGeneration: listEntryIdentityGeneration
        )
    }

    package func captureListProjection() -> NetworkPanelListProjection {
        NetworkPanelListProjection(
            version: listProjectionVersion,
            entryIDs: visibleEntryIDs
        )
    }

    package var displayEntryIDs: [NetworkListEntry.ID] {
        visibleEntryIDs
    }

    package var displayEntries: [NetworkListEntry] {
        visibleEntryIDs.compactMap { entriesByID[$0] }
    }

    package var displayRequestIDs: [NetworkRequest.ID] {
        displayEntries.map { $0.representativeRequest.id }
    }

    package var displayRequests: [NetworkRequest] {
        displayEntries.map(\.representativeRequest)
    }

    package var isEmpty: Bool {
        visibleEntryIDs.isEmpty
    }

    package var hasClearableRequests: Bool {
        collectionState.hasRequests
    }

    package var effectiveResourceFilters: Set<NetworkDisplay.ResourceFilter> {
        NetworkDisplay.ResourceFilter.normalizedSelection(activeResourceFilters)
    }

    var selection: NetworkPanelSelection? {
        detailSubject?.selection
    }

    var selectedEntry: NetworkListEntry? {
        detailSubject?.entry
    }

    var selectedRequest: NetworkRequest? {
        detailSubject?.activeRequest
    }

    var selectedEntryRequests: [NetworkRequest] {
        detailSubject?.entryRequests ?? []
    }

    var selectedEntryID: NetworkListEntry.ID? {
        detailSubject?.entry.id
    }

    var selectedRequestID: NetworkRequest.ID? {
        detailSubject?.activeRequest.id
    }

    package func entry(for id: NetworkListEntry.ID) -> NetworkListEntry? {
        entriesByID[id]
    }

    package func entryID(containing requestID: NetworkRequest.ID) -> NetworkListEntry.ID? {
        registrationsByRequestID[requestID]?.entry.id
    }

    package func request(for id: NetworkRequest.ID) -> NetworkRequest? {
        registrationsByRequestID[id]?.request
    }

    func selectEntry(_ entry: NetworkListEntry?) {
        guard let entry else {
            detailSubject = nil
            return
        }
        guard entriesByID[entry.id] === entry else {
            return
        }
        detailSubject = NetworkDetailSubject(
            entry: entry,
            intentID: takeSelectionIntentID()
        )
    }

    func selectRequest(_ request: NetworkRequest?) {
        guard let request else {
            detailSubject = nil
            return
        }
        guard let registration = registrationsByRequestID[request.id],
              registration.request === request else {
            return
        }
        detailSubject = NetworkDetailSubject(
            entry: registration.entry,
            request: request,
            intentID: takeSelectionIntentID()
        )
    }

    func selectRequest(
        _ request: NetworkRequest,
        ifSubjectUnchanged expectedSubject: NetworkDetailSubject
    ) -> NetworkDetailSubject? {
        guard detailSubject?.hasSameIdentity(as: expectedSubject) == true,
              let registration = registrationsByRequestID[request.id],
              registration.request === request,
              registration.entry === expectedSubject.entry else {
            return nil
        }
        let subject = NetworkDetailSubject(
            entry: registration.entry,
            request: request,
            intentID: takeSelectionIntentID()
        )
        detailSubject = subject
        return subject
    }

    func selectEntry(
        _ entry: NetworkListEntry,
        ifSubjectUnchanged expectedSubject: NetworkDetailSubject
    ) -> NetworkDetailSubject? {
        guard detailSubject?.hasSameIdentity(as: expectedSubject) == true,
              expectedSubject.entry === entry,
              entriesByID[entry.id] === entry else {
            return nil
        }
        let subject = NetworkDetailSubject(
            entry: entry,
            intentID: takeSelectionIntentID()
        )
        detailSubject = subject
        return subject
    }

    func clearSelection(
        ifIntentUnchanged expectedIntentID: NetworkPanelSelectionIntent.ID
    ) {
        guard detailSubject?.intentID == expectedIntentID else {
            return
        }
        detailSubject = nil
    }

    package func setSearchText(_ text: String) {
        guard searchText != text else {
            return
        }
        searchText = text
        reapplyDisplayCriteria()
    }

    package func setResourceFilter(_ filter: NetworkDisplay.ResourceFilter, enabled: Bool) {
        var nextFilters = activeResourceFilters
        if enabled {
            nextFilters.insert(filter)
        } else {
            nextFilters.remove(filter)
        }
        nextFilters = NetworkDisplay.ResourceFilter.normalizedSelection(nextFilters)
        guard nextFilters != activeResourceFilters else {
            return
        }
        activeResourceFilters = nextFilters
        reapplyDisplayCriteria()
    }

    package func clearResourceFilters() {
        guard activeResourceFilters.isEmpty == false else {
            return
        }
        activeResourceFilters = []
        reapplyDisplayCriteria()
    }

    package func clearRequests() {
        detailSubject = nil
        context.network.clearRequests()
    }

    @discardableResult
    package func fetchResponseBodyIfNeeded(for request: NetworkRequest) -> Bool {
        guard registrationsByRequestID[request.id]?.request === request,
              request.canFetchResponseBody else {
            return false
        }
        Task { @MainActor in
            await request.fetchResponseBody()
        }
        return true
    }

    @discardableResult
    func fetchResponseBodyIfNeeded(
        for request: NetworkRequest,
        ifSubjectUnchanged expectedSubject: NetworkDetailSubject
    ) -> Bool {
        guard let currentSubject = detailSubject,
              currentSubject.hasSameIdentity(as: expectedSubject),
              isRegistered(request, in: currentSubject) else {
            return false
        }
        return fetchResponseBodyIfNeeded(for: request)
    }

    private func isRegistered(
        _ request: NetworkRequest,
        in subject: NetworkDetailSubject
    ) -> Bool {
        guard let registration = registrationsByRequestID[request.id],
              registration.request === request,
              registration.entry === subject.entry else {
            return false
        }
        switch subject.scope {
        case .entry:
            return true
        case .request:
            return subject.activeRequest === request
        }
    }

    private func startObservingFetchedResultsTransactions() {
        let transactions = fetchedResultsController.transactions
        fetchedResultsTransactionTask = Task { @MainActor [weak self] in
            for await transaction in transactions {
                guard let self else {
                    return
                }
                consume(transaction)
            }
        }
    }

    private func consume(_ transaction: WebInspectorFetchedResultsTransaction<NetworkRequest>) {
#if DEBUG
        rawTransactionDeliveryCountStorageForTesting &+= 1
        resolveRawTransactionDeliveryWaitersForTesting(result: true)
#endif
        let subjectBeforeTransaction = detailSubject
        if transaction.isReset {
            rebuildEntries(from: requests.items)
            reconcileSubjectAfterReset(subjectBeforeTransaction)
            publishListTransaction(
                topologyChangedEntryIDs: Set(visibleEntryIDs),
                rebindsStableEntries: true
            )
            return
        }

        var affectedEntryIDs: Set<NetworkListEntry.ID> = []
        var topologyChangedEntryIDs: Set<NetworkListEntry.ID> = []

        for change in transaction.itemChanges {
            guard case let .delete(requestID, _) = change else {
                continue
            }
            removeRequest(
                requestID,
                affectedEntryIDs: &affectedEntryIDs,
                topologyChangedEntryIDs: &topologyChangedEntryIDs
            )
        }

        for change in transaction.itemChanges {
            switch change {
            case let .insert(requestID, _),
                 let .move(requestID, _, _),
                 let .update(requestID, _):
                guard let request = registrationsByRequestID[requestID]?.request
                    ?? context.registeredRequest(for: requestID) else {
                    continue
                }
                upsertRequest(
                    request,
                    affectedEntryIDs: &affectedEntryIDs,
                    topologyChangedEntryIDs: &topologyChangedEntryIDs
                )
            case .delete:
                break
            }
        }

        for entryID in affectedEntryIDs {
            reconcileVisibility(
                of: entryID,
                topologyChangedEntryIDs: &topologyChangedEntryIDs
            )
        }

        reconcileSubjectAfterIncrementalChange(subjectBeforeTransaction)

        publishListTransaction(
            topologyChangedEntryIDs: topologyChangedEntryIDs,
            rebindsStableEntries: false
        )
    }

    private func rebuildEntries(from requests: [NetworkRequest]) {
#if DEBUG
        fullEntryRebuildCountStorageForTesting &+= 1
#endif
        entriesByID.removeAll(keepingCapacity: true)
        registrationsByRequestID.removeAll(keepingCapacity: true)
        orderedEntryIDs.removeAll(keepingCapacity: true)
        visibleEntryIDs.removeAll(keepingCapacity: true)
        visibleEntryIDSet.removeAll(keepingCapacity: true)

        for request in requests {
            insertRequestWithoutPublishing(request)
        }
        for entry in entriesByID.values where entry.requests.count > 1 {
            entry.replaceRequests(sortedRequests(entry.requests))
            replaceEntryChronologyFromRequests(entry)
        }
        orderedEntryIDs.sort { lhs, rhs in
            guard let lhsEntry = entriesByID[lhs],
                  let rhsEntry = entriesByID[rhs] else {
                preconditionFailure("Network entry ordering referenced an unregistered entry.")
            }
            return entryOrdersBefore(lhsEntry, rhsEntry)
        }
        visibleEntryIDs = orderedEntryIDs.filter { entryID in
            guard let entry = entriesByID[entryID] else {
                preconditionFailure("Network entry visibility referenced an unregistered entry.")
            }
            return entryMatchesDisplayCriteria(entry)
        }
        visibleEntryIDSet = Set(visibleEntryIDs)
    }

    private func insertRequestWithoutPublishing(_ request: NetworkRequest) {
        let creation = RequestCreationMetadata(
            timestamp: request.logicalStartTimestamp,
            sequence: request.chronologySequence,
            lifecycleRevision: request.lifecycleRevision
        )
        let entryID = listEntryID(for: request)
        if let entry = entriesByID[entryID] {
            registrationsByRequestID[request.id] = RequestRegistration(
                request: request,
                entry: entry,
                statusSeverity: request.statusSeverity,
                creation: creation
            )
            entry.appendRequest(request)
        } else {
            let entry = NetworkListEntry(
                id: entryID,
                request: request,
                chronologyTimestamp: request.logicalStartTimestamp,
                chronologySequence: request.chronologySequence
            )
            entriesByID[entryID] = entry
            registrationsByRequestID[request.id] = RequestRegistration(
                request: request,
                entry: entry,
                statusSeverity: request.statusSeverity,
                creation: creation
            )
            orderedEntryIDs.append(entryID)
        }
    }

    private func upsertRequest(
        _ request: NetworkRequest,
        affectedEntryIDs: inout Set<NetworkListEntry.ID>,
        topologyChangedEntryIDs: inout Set<NetworkListEntry.ID>
    ) {
        let creation = RequestCreationMetadata(
            timestamp: request.logicalStartTimestamp,
            sequence: request.chronologySequence,
            lifecycleRevision: request.lifecycleRevision
        )
        let nextEntryID = listEntryID(for: request)
        guard var registration = registrationsByRequestID[request.id] else {
            if let entry = entriesByID[nextEntryID] {
                registrationsByRequestID[request.id] = RequestRegistration(
                    request: request,
                    entry: entry,
                    statusSeverity: request.statusSeverity,
                    creation: creation
                )
                insertRequest(request, into: entry)
                refreshEntryChronologyAndOrdering(
                    entry,
                    topologyChangedEntryIDs: &topologyChangedEntryIDs
                )
                if hasActiveDisplayCriteria {
                    affectedEntryIDs.insert(nextEntryID)
                }
            } else {
                let entry = NetworkListEntry(
                    id: nextEntryID,
                    request: request,
                    chronologyTimestamp: creation.timestamp,
                    chronologySequence: creation.sequence
                )
                registrationsByRequestID[request.id] = RequestRegistration(
                    request: request,
                    entry: entry,
                    statusSeverity: request.statusSeverity,
                    creation: creation
                )
                entriesByID[nextEntryID] = entry
                insertOrderedEntryID(nextEntryID)
                topologyChangedEntryIDs.insert(nextEntryID)
                affectedEntryIDs.insert(nextEntryID)
            }
            return
        }

        let previousRequest = registration.request
        let previousEntry = registration.entry
        let previousStatusSeverity = registration.statusSeverity
        let lifecycleRestarted = registration.creation.lifecycleRevision != creation.lifecycleRevision
        let chronologyChanged = registration.creation.timestamp != creation.timestamp
            || registration.creation.sequence != creation.sequence

        if previousEntry.id == nextEntryID {
            registration.request = request
            registration.statusSeverity = request.statusSeverity
            registration.creation = creation
            registrationsByRequestID[request.id] = registration
            previousEntry.updateStatusSeverity(
                from: previousStatusSeverity,
                to: request.statusSeverity
            )
            if previousRequest !== request || lifecycleRestarted || chronologyChanged {
#if DEBUG
                memberTraversalCountStorageForTesting += previousEntry.requests.count
#endif
                guard let index = previousEntry.requests.firstIndex(where: { $0.id == request.id }) else {
                    preconditionFailure("A registered Network request must be present in its entry.")
                }
                if previousRequest !== request {
                    previousEntry.replaceRequest(at: index, with: request)
                }
                if lifecycleRestarted || chronologyChanged {
                    repositionRequest(at: index, in: previousEntry)
                    refreshEntryChronologyAndOrdering(
                        previousEntry,
                        topologyChangedEntryIDs: &topologyChangedEntryIDs
                    )
                }
            }
            if hasActiveDisplayCriteria {
                affectedEntryIDs.insert(previousEntry.id)
            }
            return
        }

        removeRequestFromEntry(
            request.id,
            entry: previousEntry,
            statusSeverity: previousStatusSeverity,
            affectedEntryIDs: &affectedEntryIDs,
            topologyChangedEntryIDs: &topologyChangedEntryIDs
        )
        if let entry = entriesByID[nextEntryID] {
            registration.request = request
            registration.entry = entry
            registration.statusSeverity = request.statusSeverity
            registration.creation = creation
            registrationsByRequestID[request.id] = registration
            insertRequest(request, into: entry)
            refreshEntryChronologyAndOrdering(
                entry,
                topologyChangedEntryIDs: &topologyChangedEntryIDs
            )
            if hasActiveDisplayCriteria {
                affectedEntryIDs.insert(nextEntryID)
            }
        } else {
            let entry = NetworkListEntry(
                id: nextEntryID,
                request: request,
                chronologyTimestamp: creation.timestamp,
                chronologySequence: creation.sequence
            )
            registration.request = request
            registration.entry = entry
            registration.statusSeverity = request.statusSeverity
            registration.creation = creation
            registrationsByRequestID[request.id] = registration
            entriesByID[nextEntryID] = entry
            insertOrderedEntryID(nextEntryID)
            topologyChangedEntryIDs.insert(nextEntryID)
            affectedEntryIDs.insert(nextEntryID)
        }

    }

    private func removeRequest(
        _ requestID: NetworkRequest.ID,
        affectedEntryIDs: inout Set<NetworkListEntry.ID>,
        topologyChangedEntryIDs: inout Set<NetworkListEntry.ID>
    ) {
        guard let registration = registrationsByRequestID.removeValue(forKey: requestID) else {
            return
        }
        removeRequestFromEntry(
            requestID,
            entry: registration.entry,
            statusSeverity: registration.statusSeverity,
            affectedEntryIDs: &affectedEntryIDs,
            topologyChangedEntryIDs: &topologyChangedEntryIDs
        )

    }

    private func removeRequestFromEntry(
        _ requestID: NetworkRequest.ID,
        entry: NetworkListEntry,
        statusSeverity: NetworkDisplay.StatusSeverity,
        affectedEntryIDs: inout Set<NetworkListEntry.ID>,
        topologyChangedEntryIDs: inout Set<NetworkListEntry.ID>
    ) {
        guard entriesByID[entry.id] === entry else {
            preconditionFailure("A Network request referenced an unregistered entry.")
        }
        let remainingRequests = entry.requests.filter { $0.id != requestID }
        if remainingRequests.isEmpty {
            entriesByID.removeValue(forKey: entry.id)
            orderedEntryIDs.removeAll { $0 == entry.id }
            if visibleEntryIDSet.remove(entry.id) != nil {
                visibleEntryIDs.removeAll { $0 == entry.id }
                topologyChangedEntryIDs.insert(entry.id)
            }
        } else {
#if DEBUG
            memberTraversalCountStorageForTesting += entry.requests.count
#endif
            entry.removeStatusSeverity(statusSeverity)
            entry.replaceRequests(remainingRequests)
            refreshEntryChronologyAndOrdering(
                entry,
                topologyChangedEntryIDs: &topologyChangedEntryIDs
            )
            if hasActiveDisplayCriteria {
                affectedEntryIDs.insert(entry.id)
            }
        }
    }

    private func reconcileSubjectAfterIncrementalChange(
        _ previousSubject: NetworkDetailSubject?
    ) {
        guard detailSubject?.intentID == previousSubject?.intentID else {
            return
        }
        guard let previousSubject else {
            return
        }
        let subject: NetworkDetailSubject
        switch previousSubject.scope {
        case .entry:
            guard entriesByID[previousSubject.entry.id] === previousSubject.entry else {
                detailSubject = nil
                return
            }
            subject = NetworkDetailSubject(
                entry: previousSubject.entry,
                intentID: previousSubject.intentID
            )
        case .request:
            guard let registration = registrationsByRequestID[previousSubject.activeRequest.id] else {
                detailSubject = nil
                return
            }
            subject = NetworkDetailSubject(
                entry: registration.entry,
                request: registration.request,
                intentID: previousSubject.intentID
            )
        }
        if previousSubject.hasSameIdentity(as: subject) == false {
            detailSubject = subject
        }
    }

    private func reconcileSubjectAfterReset(
        _ previousSubject: NetworkDetailSubject?
    ) {
        guard detailSubject?.intentID == previousSubject?.intentID else {
            return
        }
        guard let previousSubject else {
            detailSubject = nil
            return
        }
        switch previousSubject.scope {
        case .entry:
            guard let entry = entriesByID[previousSubject.entry.id] else {
                detailSubject = nil
                return
            }
            let previousRequestIdentities = Set(
                previousSubject.entryRequests.map(ObjectIdentifier.init)
            )
            guard entry.requests.contains(where: {
                previousRequestIdentities.contains(ObjectIdentifier($0))
            }) else {
                detailSubject = nil
                return
            }
            detailSubject = NetworkDetailSubject(
                entry: entry,
                intentID: previousSubject.intentID
            )
        case .request:
            let previousRequest = previousSubject.activeRequest
            guard let registration = registrationsByRequestID[previousRequest.id],
                  registration.request === previousRequest else {
                detailSubject = nil
                return
            }
            detailSubject = NetworkDetailSubject(
                entry: registration.entry,
                request: registration.request,
                intentID: previousSubject.intentID
            )
        }
    }

    private func reapplyDisplayCriteria() {
        let previousVisibleEntryIDs = visibleEntryIDs
        let newVisibleEntryIDs = orderedEntryIDs.filter { entryID in
            guard let entry = entriesByID[entryID] else {
                preconditionFailure("Network entry visibility referenced an unregistered entry.")
            }
            return entryMatchesDisplayCriteria(entry)
        }
        guard newVisibleEntryIDs != visibleEntryIDs else {
            return
        }
        visibleEntryIDs = newVisibleEntryIDs
        visibleEntryIDSet = Set(newVisibleEntryIDs)
        publishListTransaction(
            topologyChangedEntryIDs: Set(previousVisibleEntryIDs)
                .symmetricDifference(newVisibleEntryIDs),
            rebindsStableEntries: false
        )
    }

    private func reconcileVisibility(
        of entryID: NetworkListEntry.ID,
        topologyChangedEntryIDs: inout Set<NetworkListEntry.ID>
    ) {
        let wasVisible = visibleEntryIDSet.contains(entryID)
        let shouldBeVisible = entriesByID[entryID].map(entryMatchesDisplayCriteria) ?? false
        guard wasVisible != shouldBeVisible else {
            return
        }
        topologyChangedEntryIDs.insert(entryID)
        if shouldBeVisible {
            insertVisibleEntryID(entryID)
        } else {
            visibleEntryIDSet.remove(entryID)
            visibleEntryIDs.removeAll { $0 == entryID }
        }
    }

    private func entryMatchesDisplayCriteria(_ entry: NetworkListEntry) -> Bool {
#if DEBUG
        filterEvaluationCountStorageForTesting &+= 1
#endif
        let searchText = normalizedSearchText
        let categories = NetworkRequest.ResourceCategory.networkCategories(
            for: effectiveResourceFilters
        )
        guard searchText.isEmpty == false || categories.isEmpty == false else {
            return true
        }
        for request in entry.requests {
#if DEBUG
            memberTraversalCountStorageForTesting &+= 1
#endif
            if (searchText.isEmpty || request.searchableText.localizedStandardContains(searchText))
                && (categories.isEmpty || categories.contains(request.resourceCategory)) {
                return true
            }
        }
        return false
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasActiveDisplayCriteria: Bool {
        normalizedSearchText.isEmpty == false || effectiveResourceFilters.isEmpty == false
    }

    private func listEntryID(for request: NetworkRequest) -> NetworkListEntry.ID {
        guard let visit = request.navigationVisit,
              let nodeID = request.initiator?.nodeID else {
            return .singleton(request.id)
        }
        return .group(visit: visit, initiatorNodeID: nodeID.rawValue)
    }

    private func sortedRequests(_ requests: [NetworkRequest]) -> [NetworkRequest] {
        requests.sorted { lhs, rhs in
            requestOrdersBefore(lhs, rhs)
        }
    }

    private func insertRequest(_ request: NetworkRequest, into entry: NetworkListEntry) {
        guard let lastRequest = entry.requests.last else {
            preconditionFailure("A registered Network entry must contain at least one request.")
        }
        if requestOrdersBefore(request, lastRequest) == false {
            entry.appendRequest(request)
            return
        }

        var lowerBound = 0
        var upperBound = entry.requests.count
        while lowerBound < upperBound {
            let index = lowerBound + (upperBound - lowerBound) / 2
            if requestOrdersBefore(request, entry.requests[index]) {
                upperBound = index
            } else {
                lowerBound = index + 1
            }
        }
        entry.insertRequest(request, at: lowerBound)
    }

    private func repositionRequest(at index: Int, in entry: NetworkListEntry) {
        var requests = entry.requests
        let request = requests.remove(at: index)
        var lowerBound = 0
        var upperBound = requests.count
        while lowerBound < upperBound {
            let candidateIndex = lowerBound + (upperBound - lowerBound) / 2
            if requestOrdersBefore(request, requests[candidateIndex]) {
                upperBound = candidateIndex
            } else {
                lowerBound = candidateIndex + 1
            }
        }
        requests.insert(request, at: lowerBound)
        entry.replaceRequests(requests)
    }

    private func replaceEntryChronologyFromRequests(_ entry: NetworkListEntry) {
        let chronology = entryChronology(for: entry)
        entry.replaceChronology(timestamp: chronology.timestamp, sequence: chronology.sequence)
    }

    private func refreshEntryChronologyAndOrdering(
        _ entry: NetworkListEntry,
        topologyChangedEntryIDs: inout Set<NetworkListEntry.ID>
    ) {
        let chronology = entryChronology(for: entry)
        guard entry.chronologyTimestamp != chronology.timestamp
                || entry.chronologySequence != chronology.sequence else {
            return
        }
        entry.replaceChronology(timestamp: chronology.timestamp, sequence: chronology.sequence)

        orderedEntryIDs.removeAll { $0 == entry.id }
        insertOrderedEntryID(entry.id)

        guard visibleEntryIDSet.contains(entry.id) else {
            return
        }
        let previousVisibleEntryIDs = visibleEntryIDs
        visibleEntryIDs.removeAll { $0 == entry.id }
        insertVisibleEntryID(entry.id)
        if visibleEntryIDs != previousVisibleEntryIDs {
            topologyChangedEntryIDs.insert(entry.id)
        }
    }

    private func entryChronology(
        for entry: NetworkListEntry
    ) -> (timestamp: Double?, sequence: UInt64) {
        guard let representativeMetadata = registrationsByRequestID[entry.representativeRequest.id]?.creation else {
            preconditionFailure("A Network entry representative must have creation metadata.")
        }
        var sequence = representativeMetadata.sequence
        for request in entry.requests.dropFirst() {
            guard let metadata = registrationsByRequestID[request.id]?.creation else {
                preconditionFailure("A Network entry member must have creation metadata.")
            }
            sequence = min(sequence, metadata.sequence)
        }
        return (representativeMetadata.timestamp, sequence)
    }

    private func requestOrdersBefore(_ lhs: NetworkRequest, _ rhs: NetworkRequest) -> Bool {
#if DEBUG
        requestOrderComparisonCountStorageForTesting &+= 1
#endif
        guard let lhsMetadata = registrationsByRequestID[lhs.id]?.creation,
              let rhsMetadata = registrationsByRequestID[rhs.id]?.creation else {
            preconditionFailure("A Network request must have creation metadata before sorting.")
        }
        return chronologyOrdersBefore(
            lhsTimestamp: lhsMetadata.timestamp,
            lhsSequence: lhsMetadata.sequence,
            rhsTimestamp: rhsMetadata.timestamp,
            rhsSequence: rhsMetadata.sequence
        )
    }

    private func chronologyOrdersBefore(
        lhsTimestamp: Double?,
        lhsSequence: UInt64,
        rhsTimestamp: Double?,
        rhsSequence: UInt64
    ) -> Bool {
        switch (lhsTimestamp, rhsTimestamp) {
        case let (.some(lhsTimestamp), .some(rhsTimestamp)) where lhsTimestamp != rhsTimestamp:
            return lhsTimestamp < rhsTimestamp
        case (.none, .some):
            return true
        case (.some, .none):
            return false
        case (.some, .some), (.none, .none):
            return lhsSequence < rhsSequence
        }
    }

    private func entryOrdersBefore(_ lhs: NetworkListEntry, _ rhs: NetworkListEntry) -> Bool {
        if lhs.chronologySequence != rhs.chronologySequence {
            return lhs.chronologySequence > rhs.chronologySequence
        }
        return chronologyOrdersBefore(
            lhsTimestamp: rhs.chronologyTimestamp,
            lhsSequence: rhs.chronologySequence,
            rhsTimestamp: lhs.chronologyTimestamp,
            rhsSequence: lhs.chronologySequence
        )
    }

    private func insertOrderedEntryID(_ entryID: NetworkListEntry.ID) {
        guard let entry = entriesByID[entryID] else {
            preconditionFailure("Cannot order an unregistered Network entry.")
        }
        let index = orderedEntryIDs.firstIndex { existingID in
            guard let existingEntry = entriesByID[existingID] else {
                preconditionFailure("Network entry ordering referenced an unregistered entry.")
            }
            return entryOrdersBefore(entry, existingEntry)
        } ?? orderedEntryIDs.endIndex
        orderedEntryIDs.insert(entryID, at: index)
    }

    private func insertVisibleEntryID(_ entryID: NetworkListEntry.ID) {
        guard let entry = entriesByID[entryID] else {
            preconditionFailure("Cannot display an unregistered Network entry.")
        }
        let insertionIndex = visibleEntryIDs.firstIndex { visibleID in
            guard let visibleEntry = entriesByID[visibleID] else {
                preconditionFailure("A visible Network entry must be registered.")
            }
            return entryOrdersBefore(entry, visibleEntry)
        } ?? visibleEntryIDs.endIndex
        visibleEntryIDs.insert(entryID, at: insertionIndex)
        visibleEntryIDSet.insert(entryID)
    }

    private func publishListTransaction(
        topologyChangedEntryIDs: Set<NetworkListEntry.ID>,
        rebindsStableEntries: Bool
    ) {
        guard rebindsStableEntries || topologyChangedEntryIDs.isEmpty == false else {
            return
        }
        precondition(
            nextListTransactionRevision < UInt64.max,
            "Network list transaction revision overflowed."
        )
        nextListTransactionRevision += 1
        if rebindsStableEntries {
            precondition(
                listEntryIdentityGeneration < UInt64.max,
                "Network list entry identity generation overflowed."
            )
            listEntryIdentityGeneration += 1
        }
#if DEBUG
        listTransactionPublicationCountStorageForTesting &+= 1
#endif
        let invalidation = NetworkPanelListInvalidation(version: listProjectionVersion)
#if DEBUG
        lastListInvalidationStorageForTesting = invalidation
#endif
        listInvalidationRelay.yield(invalidation)
    }

    private func takeSelectionIntentID() -> NetworkPanelSelectionIntent.ID {
        precondition(
            nextSelectionIntentID < UInt64.max,
            "Network panel selection intent identity exhausted."
        )
        defer { nextSelectionIntentID += 1 }
        return NetworkPanelSelectionIntent.ID(rawValue: nextSelectionIntentID)
    }
}

#if DEBUG
extension NetworkPanelModel {
    package func upsertRequestForTesting(_ request: NetworkRequest) {
        let subjectBeforeTransaction = detailSubject
        var affectedEntryIDs: Set<NetworkListEntry.ID> = []
        var topologyChangedEntryIDs: Set<NetworkListEntry.ID> = []
        upsertRequest(
            request,
            affectedEntryIDs: &affectedEntryIDs,
            topologyChangedEntryIDs: &topologyChangedEntryIDs
        )
        for entryID in affectedEntryIDs {
            reconcileVisibility(
                of: entryID,
                topologyChangedEntryIDs: &topologyChangedEntryIDs
            )
        }
        reconcileSubjectAfterIncrementalChange(subjectBeforeTransaction)
        publishListTransaction(
            topologyChangedEntryIDs: topologyChangedEntryIDs,
            rebindsStableEntries: false
        )
    }

    package func rebuildEntriesForTesting() {
        let subjectBeforeRebuild = detailSubject
        rebuildEntries(from: requests.items)
        reconcileSubjectAfterReset(subjectBeforeRebuild)
        publishListTransaction(
            topologyChangedEntryIDs: Set(visibleEntryIDs),
            rebindsStableEntries: true
        )
    }

    package var rawTransactionDeliveryCountForTesting: Int {
        rawTransactionDeliveryCountStorageForTesting
    }

    package var fullEntryRebuildCountForTesting: Int {
        fullEntryRebuildCountStorageForTesting
    }

    package var filterEvaluationCountForTesting: Int {
        filterEvaluationCountStorageForTesting
    }

    package var memberTraversalCountForTesting: Int {
        memberTraversalCountStorageForTesting
    }

    package var requestOrderComparisonCountForTesting: Int {
        requestOrderComparisonCountStorageForTesting
    }

    package var listTransactionPublicationCountForTesting: Int {
        listTransactionPublicationCountStorageForTesting
    }

    package var lastListInvalidationForTesting: NetworkPanelListInvalidation? {
        lastListInvalidationStorageForTesting
    }

    package func waitForRawTransactionDeliveryForTesting(
        after baselineCount: Int,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        guard rawTransactionDeliveryCountStorageForTesting <= baselineCount else {
            return true
        }
        return await withCheckedContinuation { continuation in
            let waiterID = rawTransactionDeliveryWaiterIDStorageForTesting
            rawTransactionDeliveryWaiterIDStorageForTesting &+= 1
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveRawTransactionDeliveryWaiterForTesting(
                    id: waiterID,
                    result: false
                )
            }
            rawTransactionDeliveryWaitersForTesting.append(RawTransactionDeliveryWaiter(
                id: waiterID,
                baselineCount: baselineCount,
                continuation: continuation,
                timeoutTask: timeoutTask
            ))
        }
    }

    private func resolveRawTransactionDeliveryWaitersForTesting(result: Bool) {
        let waiterIDs = rawTransactionDeliveryWaitersForTesting.compactMap { waiter in
            if result == false || rawTransactionDeliveryCountStorageForTesting > waiter.baselineCount {
                return waiter.id
            }
            return nil
        }
        for waiterID in waiterIDs {
            resolveRawTransactionDeliveryWaiterForTesting(id: waiterID, result: result)
        }
    }

    private func resolveRawTransactionDeliveryWaiterForTesting(id: Int, result: Bool) {
        guard let index = rawTransactionDeliveryWaitersForTesting.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = rawTransactionDeliveryWaitersForTesting.remove(at: index)
        waiter.timeoutTask.cancel()
        waiter.continuation.resume(returning: result)
    }
}
#endif

private extension NetworkRequest.ResourceCategory {
    static func networkCategories(
        for filters: Set<NetworkDisplay.ResourceFilter>
    ) -> Set<NetworkRequest.ResourceCategory> {
        var categories: Set<NetworkRequest.ResourceCategory> = []
        for filter in NetworkDisplay.ResourceFilter.pickerCases where filters.contains(filter) {
            categories.formUnion(filter.networkResourceCategories)
        }
        return categories
    }
}

private extension NetworkDisplay.ResourceFilter {
    var networkResourceCategories: [NetworkRequest.ResourceCategory] {
        switch self {
        case .all:
            []
        case .document:
            [.document]
        case .stylesheet:
            [.stylesheet]
        case .media:
            [.image, .media]
        case .font:
            [.font]
        case .script:
            [.script]
        case .xhrFetch:
            [.xhrFetch]
        case .other:
            [.webSocket, .other]
        }
    }
}
