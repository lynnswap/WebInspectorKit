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

    package let context: WebInspectorContext
    package let requests: WebInspectorFetchedResults<NetworkRequest>
    private let fetchedResultsController: WebInspectorFetchedResultsController<NetworkRequest>
    private let collectionState: NetworkRequestCollectionState

    package private(set) var selectedEntryID: NetworkListEntry.ID?
    package private(set) var searchText = ""
    package private(set) var activeResourceFilters: Set<NetworkDisplay.ResourceFilter> = []

    @ObservationIgnored private let listInvalidationRelay = NetworkPanelListInvalidationRelay()
    @ObservationIgnored private var fetchedResultsTransactionTask: Task<Void, Never>?
    @ObservationIgnored private var entriesByID: [NetworkListEntry.ID: NetworkListEntry] = [:]
    @ObservationIgnored private var entryIDByRequestID: [NetworkRequest.ID: NetworkListEntry.ID] = [:]
    @ObservationIgnored private var requestsByID: [NetworkRequest.ID: NetworkRequest] = [:]
    @ObservationIgnored private var requestStatusSeverityByID: [NetworkRequest.ID: NetworkDisplay.StatusSeverity] = [:]
    @ObservationIgnored private var requestCreationMetadataByID: [NetworkRequest.ID: RequestCreationMetadata] = [:]
    @ObservationIgnored private var orderedEntryIDs: [NetworkListEntry.ID] = []
    @ObservationIgnored private var visibleEntryIDs: [NetworkListEntry.ID] = []
    @ObservationIgnored private var visibleEntryIDSet: Set<NetworkListEntry.ID> = []
    @ObservationIgnored private var nextCreationSequence: UInt64 = 0
    @ObservationIgnored private var nextListTransactionRevision: UInt64 = 0
    @ObservationIgnored private var listEntryIdentityGeneration: UInt64 = 0
    @ObservationIgnored private var selectedRequestAnchorID: NetworkRequest.ID?
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

    package var selectedEntry: NetworkListEntry? {
        guard let selectedEntryID else {
            return nil
        }
        return entriesByID[selectedEntryID]
    }

    package var selectedRequest: NetworkRequest? {
        selectedEntry?.representativeRequest
    }

    package var selectedRequests: [NetworkRequest] {
        selectedEntry?.requests ?? []
    }

    package var selectedRequestID: NetworkRequest.ID? {
        selectedRequestAnchorID
    }

    package func entry(for id: NetworkListEntry.ID) -> NetworkListEntry? {
        entriesByID[id]
    }

    package func entryID(containing requestID: NetworkRequest.ID) -> NetworkListEntry.ID? {
        entryIDByRequestID[requestID]
    }

    package func request(for id: NetworkRequest.ID) -> NetworkRequest? {
        requestsByID[id] ?? context.registeredRequest(for: id)
    }

    package func selectEntry(_ id: NetworkListEntry.ID?) {
        guard let id else {
            selectedEntryID = nil
            selectedRequestAnchorID = nil
            return
        }
        guard let entry = entriesByID[id] else {
            selectedEntryID = nil
            selectedRequestAnchorID = nil
            return
        }
        selectedEntryID = id
        selectedRequestAnchorID = entry.representativeRequest.id
    }

    package func selectRequest(_ request: NetworkRequest?) {
        guard let request,
              let entryID = entryIDByRequestID[request.id] else {
            selectedEntryID = nil
            selectedRequestAnchorID = nil
            return
        }
        selectedEntryID = entryID
        selectedRequestAnchorID = request.id
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
        selectedEntryID = nil
        selectedRequestAnchorID = nil
        context.network.clearRequests()
    }

    package func fetchResponseBodyIfNeeded(for request: NetworkRequest) {
        guard request.canFetchResponseBody else {
            return
        }
        Task { @MainActor in
            await request.fetchResponseBody()
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
        if transaction.isReset {
            rebuildEntries(from: requests.items)
            if let selectedRequestAnchorID,
               let entryID = entryIDByRequestID[selectedRequestAnchorID] {
                selectedEntryID = entryID
            } else {
                selectedEntryID = nil
                selectedRequestAnchorID = nil
            }
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
                guard let request = context.registeredRequest(for: requestID) else {
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
        entryIDByRequestID.removeAll(keepingCapacity: true)
        requestsByID.removeAll(keepingCapacity: true)
        requestStatusSeverityByID.removeAll(keepingCapacity: true)
        requestCreationMetadataByID.removeAll(keepingCapacity: true)
        orderedEntryIDs.removeAll(keepingCapacity: true)
        visibleEntryIDs.removeAll(keepingCapacity: true)
        visibleEntryIDSet.removeAll(keepingCapacity: true)
        nextCreationSequence = 0

        for request in requests {
            insertRequestWithoutPublishing(request)
        }
        for entry in entriesByID.values where entry.requests.count > 1 {
            entry.replaceRequests(sortedRequests(entry.requests))
            replaceEntryChronologyFromRepresentative(entry)
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
        let sequence = takeCreationSequence()
        requestCreationMetadataByID[request.id] = RequestCreationMetadata(
            timestamp: request.logicalStartTimestamp,
            sequence: sequence,
            lifecycleRevision: request.lifecycleRevision
        )
        requestsByID[request.id] = request
        requestStatusSeverityByID[request.id] = request.statusSeverity
        let entryID = listEntryID(for: request)
        entryIDByRequestID[request.id] = entryID
        if let entry = entriesByID[entryID] {
            entry.appendRequest(request)
        } else {
            entriesByID[entryID] = NetworkListEntry(
                id: entryID,
                request: request,
                chronologyTimestamp: request.logicalStartTimestamp,
                chronologySequence: sequence
            )
            orderedEntryIDs.append(entryID)
        }
    }

    private func upsertRequest(
        _ request: NetworkRequest,
        affectedEntryIDs: inout Set<NetworkListEntry.ID>,
        topologyChangedEntryIDs: inout Set<NetworkListEntry.ID>
    ) {
        let wasSelectedRequest = selectedRequestAnchorID == request.id
        let previousRequest = requestsByID[request.id]
        let previousStatusSeverity = requestStatusSeverityByID[request.id]
        let lifecycleRestarted: Bool
        let chronologyTimestampChanged: Bool
        if var metadata = requestCreationMetadataByID[request.id] {
            lifecycleRestarted = metadata.lifecycleRevision != request.lifecycleRevision
            chronologyTimestampChanged = metadata.timestamp != request.logicalStartTimestamp
            if lifecycleRestarted {
                metadata = RequestCreationMetadata(
                    timestamp: request.logicalStartTimestamp,
                    sequence: takeCreationSequence(),
                    lifecycleRevision: request.lifecycleRevision
                )
            } else if chronologyTimestampChanged {
                metadata.timestamp = request.logicalStartTimestamp
            }
            if lifecycleRestarted || chronologyTimestampChanged {
                requestCreationMetadataByID[request.id] = metadata
            }
        } else {
            lifecycleRestarted = false
            chronologyTimestampChanged = false
            requestCreationMetadataByID[request.id] = RequestCreationMetadata(
                timestamp: request.logicalStartTimestamp,
                sequence: takeCreationSequence(),
                lifecycleRevision: request.lifecycleRevision
            )
        }
        requestsByID[request.id] = request
        requestStatusSeverityByID[request.id] = request.statusSeverity
        let nextEntryID = listEntryID(for: request)
        if let currentEntryID = entryIDByRequestID[request.id],
           currentEntryID == nextEntryID {
            guard let previousRequest,
                  let previousStatusSeverity,
                  let entry = entriesByID[currentEntryID] else {
                preconditionFailure("A registered Network request must belong to a registered entry.")
            }
            entry.updateStatusSeverity(
                from: previousStatusSeverity,
                to: request.statusSeverity
            )
            if previousRequest !== request || lifecycleRestarted || chronologyTimestampChanged {
#if DEBUG
                memberTraversalCountStorageForTesting += entry.requests.count
#endif
                guard let index = entry.requests.firstIndex(where: { $0.id == request.id }) else {
                    preconditionFailure("A registered Network request must be present in its entry.")
                }
                if previousRequest !== request {
                    entry.replaceRequest(at: index, with: request)
                }
                if lifecycleRestarted || chronologyTimestampChanged {
                    repositionRequest(at: index, in: entry)
                    refreshEntryChronologyAndOrdering(
                        entry,
                        topologyChangedEntryIDs: &topologyChangedEntryIDs
                    )
                }
            }
            if hasActiveDisplayCriteria {
                affectedEntryIDs.insert(currentEntryID)
            }
            if selectedRequestAnchorID == request.id {
                selectedEntryID = currentEntryID
            }
            return
        }

        if let currentEntryID = entryIDByRequestID[request.id] {
            guard let previousStatusSeverity else {
                preconditionFailure("A registered Network request must have cached status severity.")
            }
            removeRequestFromEntry(
                request.id,
                entryID: currentEntryID,
                statusSeverity: previousStatusSeverity,
                affectedEntryIDs: &affectedEntryIDs,
                topologyChangedEntryIDs: &topologyChangedEntryIDs
            )
        }

        entryIDByRequestID[request.id] = nextEntryID
        if let entry = entriesByID[nextEntryID] {
            insertRequest(request, into: entry)
            refreshEntryChronologyAndOrdering(
                entry,
                topologyChangedEntryIDs: &topologyChangedEntryIDs
            )
            if hasActiveDisplayCriteria {
                affectedEntryIDs.insert(nextEntryID)
            }
        } else {
            guard let metadata = requestCreationMetadataByID[request.id] else {
                preconditionFailure("A Network request must have creation metadata before entry insertion.")
            }
            let entry = NetworkListEntry(
                id: nextEntryID,
                request: request,
                chronologyTimestamp: metadata.timestamp,
                chronologySequence: metadata.sequence
            )
            entriesByID[nextEntryID] = entry
            insertOrderedEntryID(nextEntryID)
            topologyChangedEntryIDs.insert(nextEntryID)
            affectedEntryIDs.insert(nextEntryID)
        }

        if wasSelectedRequest {
            selectedEntryID = nextEntryID
            selectedRequestAnchorID = request.id
        }
    }

    private func removeRequest(
        _ requestID: NetworkRequest.ID,
        affectedEntryIDs: inout Set<NetworkListEntry.ID>,
        topologyChangedEntryIDs: inout Set<NetworkListEntry.ID>
    ) {
        guard let entryID = entryIDByRequestID.removeValue(forKey: requestID) else {
            return
        }
        requestsByID.removeValue(forKey: requestID)
        guard let statusSeverity = requestStatusSeverityByID.removeValue(forKey: requestID) else {
            preconditionFailure("A registered Network request must have cached status severity.")
        }
        requestCreationMetadataByID.removeValue(forKey: requestID)
        removeRequestFromEntry(
            requestID,
            entryID: entryID,
            statusSeverity: statusSeverity,
            affectedEntryIDs: &affectedEntryIDs,
            topologyChangedEntryIDs: &topologyChangedEntryIDs
        )

        if selectedRequestAnchorID == requestID {
            if let entry = entriesByID[entryID] {
                selectedRequestAnchorID = entry.representativeRequest.id
            } else {
                selectedRequestAnchorID = nil
            }
        }
    }

    private func removeRequestFromEntry(
        _ requestID: NetworkRequest.ID,
        entryID: NetworkListEntry.ID,
        statusSeverity: NetworkDisplay.StatusSeverity,
        affectedEntryIDs: inout Set<NetworkListEntry.ID>,
        topologyChangedEntryIDs: inout Set<NetworkListEntry.ID>
    ) {
        guard let entry = entriesByID[entryID] else {
            preconditionFailure("A Network request referenced an unregistered entry.")
        }
        let remainingRequests = entry.requests.filter { $0.id != requestID }
        if remainingRequests.isEmpty {
            entriesByID.removeValue(forKey: entryID)
            orderedEntryIDs.removeAll { $0 == entryID }
            if visibleEntryIDSet.remove(entryID) != nil {
                visibleEntryIDs.removeAll { $0 == entryID }
                topologyChangedEntryIDs.insert(entryID)
            }
            if selectedEntryID == entryID {
                selectedEntryID = nil
                selectedRequestAnchorID = nil
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
                affectedEntryIDs.insert(entryID)
            }
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

    private func replaceEntryChronologyFromRepresentative(_ entry: NetworkListEntry) {
        guard let metadata = requestCreationMetadataByID[entry.representativeRequest.id] else {
            preconditionFailure("A Network entry representative must have creation metadata.")
        }
        entry.replaceChronology(timestamp: metadata.timestamp, sequence: metadata.sequence)
    }

    private func refreshEntryChronologyAndOrdering(
        _ entry: NetworkListEntry,
        topologyChangedEntryIDs: inout Set<NetworkListEntry.ID>
    ) {
        guard let metadata = requestCreationMetadataByID[entry.representativeRequest.id] else {
            preconditionFailure("A Network entry representative must have creation metadata.")
        }
        guard entry.chronologyTimestamp != metadata.timestamp
                || entry.chronologySequence != metadata.sequence else {
            return
        }
        entry.replaceChronology(timestamp: metadata.timestamp, sequence: metadata.sequence)

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

    private func requestOrdersBefore(_ lhs: NetworkRequest, _ rhs: NetworkRequest) -> Bool {
#if DEBUG
        requestOrderComparisonCountStorageForTesting &+= 1
#endif
        guard let lhsMetadata = requestCreationMetadataByID[lhs.id],
              let rhsMetadata = requestCreationMetadataByID[rhs.id] else {
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
        chronologyOrdersBefore(
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

    private func takeCreationSequence() -> UInt64 {
        precondition(nextCreationSequence < UInt64.max, "Network entry creation sequence overflowed.")
        defer { nextCreationSequence += 1 }
        return nextCreationSequence
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
}

#if DEBUG
extension NetworkPanelModel {
    package func rebuildEntriesForTesting() {
        rebuildEntries(from: requests.items)
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
