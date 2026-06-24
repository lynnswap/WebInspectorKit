import WebInspectorCore

@MainActor
struct NetworkPanelDisplayCriteria: Equatable {
    var searchText: String
    var resourceFilters: Set<NetworkRequest.Display.ResourceFilter>

    var requiresEntries: Bool {
        searchText.isEmpty == false || resourceFilters.isEmpty == false
    }

    var requiresResourceFilter: Bool {
        resourceFilters.isEmpty == false
    }
}

@MainActor
private struct NetworkPanelDisplayEntry {
    var requestID: NetworkRequest.ID
    var requestURLSummary: NetworkRequest.Display.URLSummary
    var responseURLSummary: NetworkRequest.Display.URLSummary?
    var fileTypeLabel: String
    var searchTokens: [String]
    var resourceFilter: NetworkRequest.Display.ResourceFilter?

    init(request: NetworkRequest) {
        let projection = request.displayProjection()
        requestID = request.id
        requestURLSummary = projection.requestURLSummary
        responseURLSummary = projection.responseURLSummary
        fileTypeLabel = projection.fileTypeLabel
        searchTokens = projection.searchTokens
        resourceFilter = nil
    }

    mutating func ensureResourceFilter(
        for request: NetworkRequest,
        mediaPreviewClassifier: NetworkRequest.Display.MediaPreviewClassifier
    ) -> NetworkRequest.Display.ResourceFilter {
        if let resourceFilter {
            return resourceFilter
        }
        let resourceFilter = NetworkRequest.Display.resourceFilter(
            resourceType: request.resourceType,
            response: request.response,
            requestURLSummary: requestURLSummary,
            responseURLSummary: responseURLSummary,
            hasRequestedByteRangeHeader: request.hasRequestedByteRangeHeader,
            mediaPreviewClassifier: mediaPreviewClassifier
        )
        self.resourceFilter = resourceFilter
        return resourceFilter
    }

    mutating func matches(
        criteria: NetworkPanelDisplayCriteria,
        request: NetworkRequest,
        mediaPreviewClassifier: NetworkRequest.Display.MediaPreviewClassifier
    ) -> Bool {
        if criteria.requiresResourceFilter {
            let resourceFilter = ensureResourceFilter(
                for: request,
                mediaPreviewClassifier: mediaPreviewClassifier
            )
            guard criteria.resourceFilters.contains(resourceFilter) else {
                return false
            }
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
    private var topologyRevision: Int?
    private var displayRevision: Int = 0

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
        network: NetworkSession,
        orderedRequestIDs currentOrderedRequestIDs: [NetworkRequest.ID],
        criteria currentCriteria: NetworkPanelDisplayCriteria,
        topologyRevision currentTopologyRevision: Int,
        displayRevision currentDisplayRevision: Int?,
        mediaPreviewClassifier: NetworkRequest.Display.MediaPreviewClassifier
    ) -> [NetworkRequest.ID] {
        let previousCriteria = criteria
        let criteriaChanged = previousCriteria != currentCriteria
        criteria = currentCriteria

        let topologyChange = reconcileTopology(
            orderedRequestIDs: currentOrderedRequestIDs,
            topologyRevision: currentTopologyRevision
        )

        guard currentCriteria.requiresEntries else {
            if criteriaChanged || topologyChange.isChanged {
                matchingRequestIDs.removeAll(keepingCapacity: true)
                filteredRequestIDs = Array(orderedRequestIDs.reversed())
            }
            return filteredRequestIDs
        }

        guard let currentDisplayRevision else {
            return filteredRequestIDs
        }

        var dirtyRequestIDs: Set<NetworkRequest.ID> = []
        var requiresFullEntryRebuild = false
        if displayRevision < currentDisplayRevision {
            let displayChanges = network.requestDisplayChanges(after: displayRevision)
            dirtyRequestIDs = displayChanges.changedRequestIDs
            requiresFullEntryRebuild = displayChanges.requiresFullReconcile
            displayRevision = displayChanges.revision
        }
        if case let .appended(appendedRequestIDs) = topologyChange {
            dirtyRequestIDs.formUnion(appendedRequestIDs)
        }

        if requiresFullEntryRebuild {
            rebuildAllEntriesAndMembership(
                network: network,
                criteria: currentCriteria,
                mediaPreviewClassifier: mediaPreviewClassifier
            )
            return filteredRequestIDs
        }

        if criteriaChanged || topologyChange == .rebuilt {
            rebuildDirtyEntries(dirtyRequestIDs, network: network)
            rebuildMembership(
                network: network,
                criteria: currentCriteria,
                mediaPreviewClassifier: mediaPreviewClassifier
            )
            return filteredRequestIDs
        }

        for requestID in dirtyRequestIDs {
            rebuildEntryAndUpdateMembership(
                requestID,
                network: network,
                criteria: currentCriteria,
                mediaPreviewClassifier: mediaPreviewClassifier
            )
        }

        return filteredRequestIDs
    }

    mutating func resourceFilter(
        for requestID: NetworkRequest.ID,
        network: NetworkSession,
        mediaPreviewClassifier: NetworkRequest.Display.MediaPreviewClassifier
    ) -> NetworkRequest.Display.ResourceFilter? {
        guard let request = network.request(for: requestID) else {
            removeRequestFromIndex(requestID)
            return nil
        }
        if entriesByID[requestID] == nil {
            entriesByID[requestID] = makeEntry(for: requestID, network: network)
        }
        guard var entry = entriesByID[requestID] else {
            return nil
        }
        let resourceFilter = entry.ensureResourceFilter(
            for: request,
            mediaPreviewClassifier: mediaPreviewClassifier
        )
        entriesByID[requestID] = entry
        return resourceFilter
    }

    private mutating func reconcileTopology(
        orderedRequestIDs currentOrderedRequestIDs: [NetworkRequest.ID],
        topologyRevision currentTopologyRevision: Int
    ) -> TopologyChange {
        guard topologyRevision != currentTopologyRevision || orderedRequestIDs != currentOrderedRequestIDs else {
            return .none
        }

        let appendedRequestIDs = appendedRequestIDs(from: orderedRequestIDs, to: currentOrderedRequestIDs)
        orderedRequestIDs = currentOrderedRequestIDs
        topologyRevision = currentTopologyRevision
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

    private mutating func rebuildDirtyEntries(
        _ requestIDs: Set<NetworkRequest.ID>,
        network: NetworkSession
    ) {
        for requestID in requestIDs {
            if network.request(for: requestID) == nil {
                removeRequestFromIndex(requestID)
            } else {
                entriesByID[requestID] = makeEntry(for: requestID, network: network)
            }
        }
    }

    private mutating func rebuildAllEntriesAndMembership(
        network: NetworkSession,
        criteria: NetworkPanelDisplayCriteria,
        mediaPreviewClassifier: NetworkRequest.Display.MediaPreviewClassifier
    ) {
        entriesByID.removeAll(keepingCapacity: true)
        rebuildMembership(
            network: network,
            criteria: criteria,
            mediaPreviewClassifier: mediaPreviewClassifier
        )
    }

    private mutating func rebuildMembership(
        network: NetworkSession,
        criteria: NetworkPanelDisplayCriteria,
        mediaPreviewClassifier: NetworkRequest.Display.MediaPreviewClassifier
    ) {
#if DEBUG
        fullMembershipEvaluationCount += 1
#endif
        matchingRequestIDs.removeAll(keepingCapacity: true)
        filteredRequestIDs.removeAll(keepingCapacity: true)
        filteredRequestIDs.reserveCapacity(orderedRequestIDs.count)

        for requestID in orderedRequestIDs.reversed() {
            guard matchesRequest(
                requestID,
                network: network,
                criteria: criteria,
                mediaPreviewClassifier: mediaPreviewClassifier
            ) else {
                continue
            }
            matchingRequestIDs.insert(requestID)
            filteredRequestIDs.append(requestID)
        }
    }

    private mutating func rebuildEntryAndUpdateMembership(
        _ requestID: NetworkRequest.ID,
        network: NetworkSession,
        criteria: NetworkPanelDisplayCriteria,
        mediaPreviewClassifier: NetworkRequest.Display.MediaPreviewClassifier
    ) {
        let wasMatching = matchingRequestIDs.contains(requestID)
        guard network.request(for: requestID) != nil else {
            removeRequestFromIndex(requestID)
            return
        }

        entriesByID[requestID] = makeEntry(for: requestID, network: network)
        let isMatching = matchesRequest(
            requestID,
            network: network,
            criteria: criteria,
            mediaPreviewClassifier: mediaPreviewClassifier
        )

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

    private mutating func matchesRequest(
        _ requestID: NetworkRequest.ID,
        network: NetworkSession,
        criteria: NetworkPanelDisplayCriteria,
        mediaPreviewClassifier: NetworkRequest.Display.MediaPreviewClassifier
    ) -> Bool {
        guard let request = network.request(for: requestID) else {
            removeRequestFromIndex(requestID)
            return false
        }
        if entriesByID[requestID] == nil {
            entriesByID[requestID] = makeEntry(for: requestID, network: network)
        }
        guard var entry = entriesByID[requestID] else {
            return false
        }
        let matches = entry.matches(
            criteria: criteria,
            request: request,
            mediaPreviewClassifier: mediaPreviewClassifier
        )
        entriesByID[requestID] = entry
        return matches
    }

    private mutating func makeEntry(
        for requestID: NetworkRequest.ID,
        network: NetworkSession
    ) -> NetworkPanelDisplayEntry? {
        guard let request = network.request(for: requestID) else {
            return nil
        }
#if DEBUG
        displayEntryBuildCount += 1
        rebuiltDisplayRequestIDs.append(requestID)
#endif
        return NetworkPanelDisplayEntry(request: request)
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
