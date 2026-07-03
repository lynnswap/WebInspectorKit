import WebInspectorDataKit

@MainActor
struct NetworkPanelDisplayCriteria: Equatable {
    var searchText: String
    var resourceFilters: Set<NetworkDisplay.ResourceFilter>

    var requiresEntries: Bool {
        searchText.isEmpty == false || resourceFilters.isEmpty == false
    }

    var requiresResourceFilter: Bool {
        resourceFilters.isEmpty == false
    }
}

@MainActor
private struct NetworkPanelDisplayEntry: Equatable {
    var requestID: NetworkRequest.ID
    var requestURLSummary: NetworkDisplay.URLSummary
    var responseURLSummary: NetworkDisplay.URLSummary?
    var fileTypeLabel: String
    var searchTokens: [String]
    var resourceFilter: NetworkDisplay.ResourceFilter

    init(
        request: NetworkRequest,
        mediaPreviewClassifier: NetworkDisplay.MediaPreviewClassifier
    ) {
        let projection = request.displayProjection()
        requestID = request.id
        requestURLSummary = projection.requestURLSummary
        responseURLSummary = projection.responseURLSummary
        fileTypeLabel = projection.fileTypeLabel
        searchTokens = projection.searchTokens
        resourceFilter = request.displayResourceFilter(mediaPreviewClassifier: mediaPreviewClassifier)
    }

    func matches(criteria: NetworkPanelDisplayCriteria) -> Bool {
        if criteria.requiresResourceFilter,
           criteria.resourceFilters.contains(resourceFilter) == false {
            return false
        }

        if criteria.searchText.isEmpty == false {
            guard searchTokens.contains(where: { $0.localizedStandardContains(criteria.searchText) }) else {
                return false
            }
        }
        return true
    }
}

@MainActor
struct NetworkPanelDisplayIndex {
    private enum TopologyChange: Equatable {
        case none
        case appended([NetworkRequest.ID])
        case rebuilt

        var isChanged: Bool {
            switch self {
            case .none:
                false
            case .appended, .rebuilt:
                true
            }
        }
    }

    private var orderedRequestIDs: [NetworkRequest.ID] = []
    private var orderRanksByID: [NetworkRequest.ID: Int] = [:]
    private var entriesByID: [NetworkRequest.ID: NetworkPanelDisplayEntry] = [:]
    private var matchingRequestIDs: Set<NetworkRequest.ID> = []
    private var criteria: NetworkPanelDisplayCriteria?

    private(set) var filteredRequestIDs: [NetworkRequest.ID] = []

#if DEBUG
    private(set) var displayEntryBuildCount: Int = 0
    private(set) var rebuiltDisplayRequestIDs: [NetworkRequest.ID] = []
    private(set) var fullMembershipEvaluationCount: Int = 0

    mutating func resetTestingCounters() {
        displayEntryBuildCount = 0
        rebuiltDisplayRequestIDs = []
        fullMembershipEvaluationCount = 0
    }

    var displayEntryCacheCount: Int {
        entriesByID.count
    }
#endif

    mutating func reconcile(
        requests currentRequests: [NetworkRequest],
        criteria currentCriteria: NetworkPanelDisplayCriteria,
        mediaPreviewClassifier: NetworkDisplay.MediaPreviewClassifier
    ) -> [NetworkRequest.ID] {
        let previousCriteria = criteria
        let criteriaChanged = previousCriteria != currentCriteria
        criteria = currentCriteria

        let topologyChange = reconcileTopology(orderedRequestIDs: currentRequests.map(\.id))

        guard currentCriteria.requiresEntries else {
            if criteriaChanged || topologyChange.isChanged {
                matchingRequestIDs.removeAll(keepingCapacity: true)
                filteredRequestIDs = Array(orderedRequestIDs.reversed())
            }
            return filteredRequestIDs
        }

        let dirtyRequestIDs = refreshEntries(
            requests: currentRequests,
            mediaPreviewClassifier: mediaPreviewClassifier
        )

        if criteriaChanged || topologyChange == .rebuilt {
            rebuildMembership(criteria: currentCriteria)
            return filteredRequestIDs
        }

        for requestID in dirtyRequestIDs {
            updateMembership(requestID, criteria: currentCriteria)
        }

        return filteredRequestIDs
    }

    private mutating func reconcileTopology(
        orderedRequestIDs currentOrderedRequestIDs: [NetworkRequest.ID]
    ) -> TopologyChange {
        guard orderedRequestIDs != currentOrderedRequestIDs else {
            return .none
        }

        let appendedRequestIDs = appendedRequestIDs(from: orderedRequestIDs, to: currentOrderedRequestIDs)
        orderedRequestIDs = currentOrderedRequestIDs
        rebuildOrderRanks()
        pruneEntriesToCurrentRequests()

        if let appendedRequestIDs {
            if appendedRequestIDs.isEmpty {
                return .none
            }
            return .appended(Array(appendedRequestIDs))
        }
        return .rebuilt
    }

    private func appendedRequestIDs(
        from previousRequestIDs: [NetworkRequest.ID],
        to currentRequestIDs: [NetworkRequest.ID]
    ) -> ArraySlice<NetworkRequest.ID>? {
        guard currentRequestIDs.count >= previousRequestIDs.count else {
            return nil
        }
        for index in previousRequestIDs.indices where previousRequestIDs[index] != currentRequestIDs[index] {
            return nil
        }
        return currentRequestIDs.dropFirst(previousRequestIDs.count)
    }

    private mutating func rebuildOrderRanks() {
        orderRanksByID.removeAll(keepingCapacity: true)
        orderRanksByID.reserveCapacity(orderedRequestIDs.count)
        for (rank, requestID) in orderedRequestIDs.enumerated() {
            orderRanksByID[requestID] = rank
        }
    }

    private mutating func pruneEntriesToCurrentRequests() {
        let currentRequestIDs = Set(orderedRequestIDs)
        entriesByID = entriesByID.filter { currentRequestIDs.contains($0.key) }
        matchingRequestIDs.formIntersection(currentRequestIDs)
        filteredRequestIDs.removeAll { currentRequestIDs.contains($0) == false }
    }

    private mutating func refreshEntries(
        requests: [NetworkRequest],
        mediaPreviewClassifier: NetworkDisplay.MediaPreviewClassifier
    ) -> Set<NetworkRequest.ID> {
        var dirtyRequestIDs: Set<NetworkRequest.ID> = []
        for request in requests {
            let entry = makeEntry(for: request, mediaPreviewClassifier: mediaPreviewClassifier)
            if entriesByID[request.id] != entry {
                entriesByID[request.id] = entry
                dirtyRequestIDs.insert(request.id)
            }
        }
        return dirtyRequestIDs
    }

    private mutating func rebuildMembership(criteria: NetworkPanelDisplayCriteria) {
#if DEBUG
        fullMembershipEvaluationCount += 1
#endif
        matchingRequestIDs.removeAll(keepingCapacity: true)
        filteredRequestIDs.removeAll(keepingCapacity: true)
        filteredRequestIDs.reserveCapacity(orderedRequestIDs.count)

        for requestID in orderedRequestIDs.reversed() {
            guard let entry = entriesByID[requestID],
                  entry.matches(criteria: criteria) else {
                continue
            }
            matchingRequestIDs.insert(requestID)
            filteredRequestIDs.append(requestID)
        }
    }

    private mutating func updateMembership(
        _ requestID: NetworkRequest.ID,
        criteria: NetworkPanelDisplayCriteria
    ) {
        let wasMatching = matchingRequestIDs.contains(requestID)
        guard let entry = entriesByID[requestID] else {
            removeRequestFromIndex(requestID)
            return
        }

        let isMatching = entry.matches(criteria: criteria)
        switch (wasMatching, isMatching) {
        case (false, false):
            break
        case (false, true):
            matchingRequestIDs.insert(requestID)
            insertFilteredRequestIDInDisplayOrder(requestID)
        case (true, false):
            matchingRequestIDs.remove(requestID)
            filteredRequestIDs.removeAll { $0 == requestID }
        case (true, true):
            break
        }
    }

    private mutating func makeEntry(
        for request: NetworkRequest,
        mediaPreviewClassifier: NetworkDisplay.MediaPreviewClassifier
    ) -> NetworkPanelDisplayEntry {
#if DEBUG
        displayEntryBuildCount += 1
        rebuiltDisplayRequestIDs.append(request.id)
#endif
        return NetworkPanelDisplayEntry(
            request: request,
            mediaPreviewClassifier: mediaPreviewClassifier
        )
    }

    private mutating func removeRequestFromIndex(_ requestID: NetworkRequest.ID) {
        entriesByID.removeValue(forKey: requestID)
        matchingRequestIDs.remove(requestID)
        filteredRequestIDs.removeAll { $0 == requestID }
    }

    private mutating func insertFilteredRequestIDInDisplayOrder(_ requestID: NetworkRequest.ID) {
        guard filteredRequestIDs.contains(requestID) == false else {
            return
        }
        let requestRank = orderRanksByID[requestID] ?? Int.min
        var lowerBound = 0
        var upperBound = filteredRequestIDs.count
        while lowerBound < upperBound {
            let midpoint = (lowerBound + upperBound) / 2
            let midpointRank = orderRanksByID[filteredRequestIDs[midpoint]] ?? Int.min
            if midpointRank > requestRank {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        filteredRequestIDs.insert(requestID, at: lowerBound)
    }
}
