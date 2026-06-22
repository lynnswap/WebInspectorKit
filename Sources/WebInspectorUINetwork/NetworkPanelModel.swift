import WebInspectorUIBase
import WebInspectorCore
import Foundation
import Observation

@MainActor
private final class NetworkResponseBodyFetchCoordinator {
    private let action: NetworkPanelModel.ResponseBodyFetchAction?
    private var fetchesInFlight: Set<NetworkRequest.ID> = []

    init(action: NetworkPanelModel.ResponseBodyFetchAction?) {
        self.action = action
    }

    func fetchIfNeeded(for request: NetworkRequest) {
        guard request.canFetchResponseBody,
              fetchesInFlight.contains(request.id) == false,
              let action else {
            return
        }
        fetchesInFlight.insert(request.id)
        Task { @MainActor in
            defer {
                fetchesInFlight.remove(request.id)
            }
            await action(request.id)
        }
    }
}

@MainActor
@Observable
package final class NetworkPanelModel {
    package typealias ResponseBodyFetchAction = @MainActor (NetworkRequest.ID) async -> Void

    package let network: NetworkSession
    package var selectedEntryID: NetworkDisplayEntry.ID?
    package var searchText: String = ""
    package var groupMediaRequestsByDOMNode = false {
        didSet {
            guard groupMediaRequestsByDOMNode != oldValue else {
                return
            }
            reconcileSelectionAfterGroupingChange()
        }
    }
    package var activeResourceFilters: Set<NetworkRequest.Display.ResourceFilter> = [] {
        didSet {
            let normalized = NetworkRequest.Display.ResourceFilter.normalizedSelection(activeResourceFilters)
            if effectiveResourceFilters != normalized {
                effectiveResourceFilters = normalized
            }
        }
    }
    package private(set) var effectiveResourceFilters: Set<NetworkRequest.Display.ResourceFilter> = []
    @ObservationIgnored private let responseBodyFetchCoordinator: NetworkResponseBodyFetchCoordinator
    @ObservationIgnored private let mediaPreviewClassifier: NetworkRequest.Display.MediaPreviewClassifier
    @ObservationIgnored private weak var domNodeResolver: (any NetworkDOMNodeResolving)?
    @ObservationIgnored private var projectionCache = NetworkDisplayProjectionCache()
    @ObservationIgnored private var displayFactsByRequestID: [NetworkRequest.ID: NetworkRequestDisplayFacts] = [:]
    @ObservationIgnored private var displayProjectionBuildCountStorageForTesting = 0
    private var expandedRedirectResourceIDs: Set<NetworkRequest.ID> = []
    private var collapsedDOMNodeGroupIDs: Set<NetworkDOMNodeGroup.ID> = []

    package init(
        network: NetworkSession,
        domNodeResolver: (any NetworkDOMNodeResolving)? = nil,
        responseBodyFetchAction: ResponseBodyFetchAction? = nil,
        mediaPreviewClassifier: @escaping NetworkRequest.Display.MediaPreviewClassifier = { mimeType, url in
            NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    ) {
        self.network = network
        self.domNodeResolver = domNodeResolver
        self.responseBodyFetchCoordinator = NetworkResponseBodyFetchCoordinator(action: responseBodyFetchAction)
        self.mediaPreviewClassifier = mediaPreviewClassifier
    }

    package var selectedRequestID: NetworkRequest.ID? {
        get {
            guard case .resource(let requestID) = selectedEntryID else {
                return nil
            }
            return requestID
        }
        set {
            selectedEntryID = newValue.map(NetworkDisplayEntry.ID.resource)
        }
    }

    package var displayRequestIDs: [NetworkRequest.ID] {
        ensureProjection().requestIDs
    }

    package var displayEntryIDs: [NetworkDisplayEntry.ID] {
        ensureProjection().entryIDs
    }

    package var displayEntries: [NetworkDisplayEntry] {
        ensureProjection().rows.map(\.entry)
    }

    package var displayRows: [NetworkDisplayRow] {
        ensureProjection().rows
    }

    package var displayRequests: [NetworkRequest] {
        displayRequestIDs.compactMap { network.request(for: $0) }
    }

    package var isEmpty: Bool {
        network.orderedRequestIDs.isEmpty
    }

    package var displayRowsInvalidationRevision: DisplayRowsInvalidationRevision {
        makeTopologyKey()
    }

    package var displayRowsPresentationRevision: DisplayRowsPresentationRevision {
        DisplayRowsPresentationRevision(
            requestPresentationRevision: network.requestPresentationRevision,
            domRevision: domNodeResolver?.networkDOMRevision
        )
    }

    package var displayProjectionBuildCountForTesting: Int {
        displayProjectionBuildCountStorageForTesting
    }

    package var selectedRequest: NetworkRequest? {
        guard let selectedRequestID else {
            return nil
        }
        return network.request(for: selectedRequestID)
    }

    package var selectedEntry: SelectedEntry? {
        guard let selectedEntryID else {
            return nil
        }
        switch selectedEntryID {
        case .resource(let requestID):
            guard let request = network.request(for: requestID) else {
                return nil
            }
            return .resource(request)
        case .redirect(let redirectID):
            guard let request = network.request(for: redirectID.requestKey),
                  request.redirects.indices.contains(redirectID.redirectIndex) else {
                return nil
            }
            return .redirect(parent: request, hop: request.redirects[redirectID.redirectIndex])
        case .domNodeGroup(let groupID):
            guard let group = displayDOMNodeGroup(for: groupID) else {
                return nil
            }
            return .domNodeGroup(group)
        }
    }

    package func request(for id: NetworkRequest.ID) -> NetworkRequest? {
        network.request(for: id)
    }

    package func selectRequest(_ request: NetworkRequest?) {
        selectedEntryID = request.map { .resource($0.id) }
    }

    package func selectEntry(_ entryID: NetworkDisplayEntry.ID?) {
        selectedEntryID = entryID
    }

    package func displayEntryPresentation(for entryID: NetworkDisplayEntry.ID) -> NetworkDisplayEntryPresentation? {
        ensureProjection().presentationsByEntryID[entryID]
    }

    package func toggleExpansion(for entryID: NetworkDisplayEntry.ID) {
        switch entryID {
        case .resource(let requestID):
            setRedirectsExpanded(!expandedRedirectResourceIDs.contains(requestID), for: requestID)
        case .domNodeGroup(let groupID):
            setDOMNodeGroupExpanded(!isDOMNodeGroupExpanded(for: groupID), for: groupID)
        case .redirect:
            return
        }
    }

    package func setRedirectsExpanded(_ isExpanded: Bool, for requestID: NetworkRequest.ID) {
        if isExpanded {
            expandedRedirectResourceIDs.insert(requestID)
        } else {
            expandedRedirectResourceIDs.remove(requestID)
            if case .redirect(let redirectID) = selectedEntryID,
               redirectID.requestKey == requestID {
                selectedEntryID = .resource(requestID)
            }
        }
    }

    package func setDOMNodeGroupExpanded(_ isExpanded: Bool, for groupID: NetworkDOMNodeGroup.ID) {
        if isExpanded {
            collapsedDOMNodeGroupIDs.remove(groupID)
        } else {
            collapsedDOMNodeGroupIDs.insert(groupID)
            if selectedEntryBelongsToDOMNodeGroup(groupID) {
                selectedEntryID = .domNodeGroup(groupID)
            }
        }
    }

    package func isRedirectsExpanded(for requestID: NetworkRequest.ID) -> Bool {
        expandedRedirectResourceIDs.contains(requestID)
    }

    package func isDOMNodeGroupExpanded(for groupID: NetworkDOMNodeGroup.ID) -> Bool {
        collapsedDOMNodeGroupIDs.contains(groupID) == false
    }

    package func nodeDisplayName(for nodeID: DOMNode.ID) -> String {
        domNodeDisplayName(for: nodeID)
    }

    package func nodeDisplayName(for groupID: NetworkDOMNodeGroup.ID) -> String {
        domNodeDisplayName(for: resolvedNodeID(for: groupID), fallbackRawNodeID: groupID.rawNodeID)
    }

    package func setSearchText(_ text: String) {
        guard searchText != text else {
            return
        }
        searchText = text
    }

    package func setResourceFilter(_ filter: NetworkRequest.Display.ResourceFilter, enabled: Bool) {
        var nextFilters = activeResourceFilters
        if enabled {
            nextFilters.insert(filter)
        } else {
            nextFilters.remove(filter)
        }
        nextFilters = NetworkRequest.Display.ResourceFilter.normalizedSelection(nextFilters)
        guard nextFilters != activeResourceFilters else {
            return
        }
        activeResourceFilters = nextFilters
    }

    package func clearResourceFilters() {
        guard activeResourceFilters.isEmpty == false else {
            return
        }
        activeResourceFilters = []
    }

    package func clearRequests() {
        selectedEntryID = nil
        expandedRedirectResourceIDs.removeAll()
        collapsedDOMNodeGroupIDs.removeAll()
        projectionCache = NetworkDisplayProjectionCache()
        displayFactsByRequestID.removeAll()
        network.reset()
    }

    package func fetchResponseBodyIfNeeded(for request: NetworkRequest) {
        responseBodyFetchCoordinator.fetchIfNeeded(for: request)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureProjection() -> NetworkDisplayProjection {
        let topologyKey = makeTopologyKey()
        let presentationRevision = NetworkDisplayPresentationRevision(
            requestPresentationRevision: network.requestPresentationRevision,
            domRevision: domNodeResolver?.networkDOMRevision
        )
        if var projection = projectionCache.projection,
           projection.topologyKey == topologyKey {
            if projection.presentationRevision != presentationRevision {
                refreshPresentations(in: &projection, presentationRevision: presentationRevision)
                projectionCache.projection = projection
            }
            return projection
        }

        let projection = makeProjection(
            topologyKey: topologyKey,
            presentationRevision: presentationRevision
        )
        projectionCache.projection = projection
        displayProjectionBuildCountStorageForTesting += 1
        return projection
    }

    private func makeTopologyKey() -> DisplayRowsInvalidationRevision {
        let query = normalizedSearchText
        let resourceFilters = effectiveResourceFilters
        let topologyDependsOnDisplayFacts = query.isEmpty == false
            || resourceFilters.isEmpty == false
            || groupMediaRequestsByDOMNode
            || expandedRedirectResourceIDs.isEmpty == false
        return DisplayRowsInvalidationRevision(
            searchText: query,
            resourceFilters: resourceFilters,
            requestOrderRevision: network.requestTopologyRevision,
            requestFactsRevision: topologyDependsOnDisplayFacts ? network.requestDisplayRevision : nil,
            groupMediaRequestsByDOMNode: groupMediaRequestsByDOMNode,
            redirectExpansion: expandedRedirectResourceIDs,
            collapsedDOMNodeGroups: collapsedDOMNodeGroupIDs
        )
    }

    private func makeProjection(
        topologyKey: DisplayRowsInvalidationRevision,
        presentationRevision: NetworkDisplayPresentationRevision
    ) -> NetworkDisplayProjection {
        let query = topologyKey.searchText
        let resourceFilters = topologyKey.resourceFilters
        let needsResourceFilter = resourceFilters.isEmpty == false
        let allowsMediaGrouping = groupMediaRequestsByDOMNode
            && (needsResourceFilter == false || resourceFilters.contains(.media))
        var filteredIDs: [NetworkRequest.ID] = []
        var groupCandidatesByID: [NetworkDOMNodeGroup.ID: [NetworkRequest.ID]] = [:]
        filteredIDs.reserveCapacity(network.orderedRequestIDs.count)

        for requestID in network.orderedRequestIDs {
            guard let request = network.request(for: requestID) else {
                continue
            }
            let facts = displayFacts(for: request, requiresResourceFilter: needsResourceFilter)
            if needsResourceFilter,
               let resourceFilter = facts.resourceFilter,
               resourceFilters.contains(resourceFilter) == false {
                continue
            }
            guard facts.matchesSearch(query) else {
                continue
            }

            filteredIDs.append(requestID)
            guard allowsMediaGrouping,
                  let groupID = facts.domNodeGroupID else {
                continue
            }
            let isGroupCandidate = needsResourceFilter && resourceFilters.contains(.media)
                ? facts.resourceFilter == .media
                : facts.isCheapMediaGroupingCandidate
            if isGroupCandidate {
                groupCandidatesByID[groupID, default: []].append(requestID)
            }
        }

        let mediaGroups = NetworkMediaRequestGroups(groupedRequestIDsByGroupID: groupCandidatesByID)
        let rows = makeRows(filteredRequestIDs: filteredIDs, mediaGroups: mediaGroups)
        return NetworkDisplayProjection(
            topologyKey: topologyKey,
            presentationRevision: presentationRevision,
            rows: rows,
            groupRequestIDsByID: mediaGroups.requestIDsByGroupID,
            groupIDByRequestID: mediaGroups.groupIDByRequestID
        )
    }

    private func makeRows(
        filteredRequestIDs: [NetworkRequest.ID],
        mediaGroups: NetworkMediaRequestGroups
    ) -> [NetworkDisplayRow] {
        let requestIDs = Array(filteredRequestIDs.reversed())
        var emittedGroupIDs: Set<NetworkDOMNodeGroup.ID> = []
        var emittedGroupedRequestIDs: Set<NetworkRequest.ID> = []
        var rows: [NetworkDisplayRow] = []
        rows.reserveCapacity(requestIDs.count)

        for requestID in requestIDs {
            if emittedGroupedRequestIDs.contains(requestID) {
                continue
            }
            if let groupID = mediaGroups.groupIDByRequestID[requestID] {
                let groupRequestIDs = Array((mediaGroups.requestIDsByGroupID[groupID] ?? []).reversed())
                emittedGroupedRequestIDs.formUnion(groupRequestIDs)
                if emittedGroupIDs.insert(groupID).inserted {
                    let group = NetworkDOMNodeGroup(
                        id: groupID,
                        nodeID: resolvedNodeID(for: groupID),
                        requestIDs: groupRequestIDs
                    )
                    appendDOMNodeGroupRow(group: group, to: &rows)
                    if isDOMNodeGroupExpanded(for: groupID) {
                        for groupedRequestID in groupRequestIDs {
                            appendResourceRows(
                                requestID: groupedRequestID,
                                indentLevel: 1,
                                to: &rows
                            )
                        }
                    }
                }
                continue
            }

            appendResourceRows(requestID: requestID, indentLevel: 0, to: &rows)
        }

        return rows
    }

    private func refreshPresentations(
        in projection: inout NetworkDisplayProjection,
        presentationRevision: NetworkDisplayPresentationRevision
    ) {
        projection.rows = projection.rows.map { row in
            NetworkDisplayRow(
                entry: row.entry,
                presentation: presentation(for: row.entry)
            )
        }
        projection.presentationRevision = presentationRevision
    }

    private func appendResourceRows(
        requestID: NetworkRequest.ID,
        indentLevel: Int,
        to rows: inout [NetworkDisplayRow]
    ) {
        let entry = NetworkDisplayEntry(kind: .resource(requestID, indentLevel: indentLevel))
        rows.append(NetworkDisplayRow(entry: entry, presentation: presentation(for: entry)))
        guard expandedRedirectResourceIDs.contains(requestID),
              let request = network.request(for: requestID),
              request.redirects.isEmpty == false else {
            return
        }
        for hop in request.redirects {
            let entry = NetworkDisplayEntry(kind: .redirect(hop.id, indentLevel: indentLevel + 1))
            rows.append(NetworkDisplayRow(entry: entry, presentation: presentation(for: entry)))
        }
    }

    private func appendDOMNodeGroupRow(
        group: NetworkDOMNodeGroup,
        to rows: inout [NetworkDisplayRow]
    ) {
        let entry = NetworkDisplayEntry(kind: .domNodeGroup(group))
        rows.append(NetworkDisplayRow(entry: entry, presentation: presentation(for: entry)))
    }

    private func presentation(for entry: NetworkDisplayEntry) -> NetworkDisplayEntryPresentation {
        switch entry.kind {
        case .resource(let requestID, let indentLevel):
            guard let request = network.request(for: requestID) else {
                return missingResourcePresentation(indentLevel: indentLevel)
            }
            return resourcePresentation(for: request, indentLevel: indentLevel)
        case .redirect(let redirectID, let indentLevel):
            guard let request = network.request(for: redirectID.requestKey),
                  request.redirects.indices.contains(redirectID.redirectIndex) else {
                return missingResourcePresentation(indentLevel: indentLevel)
            }
            return redirectPresentation(for: request.redirects[redirectID.redirectIndex], indentLevel: indentLevel)
        case .domNodeGroup(let group):
            var resolvedGroup = group
            resolvedGroup.nodeID = resolvedNodeID(for: group.id)
            return domNodeGroupPresentation(for: resolvedGroup)
        }
    }

    private func resourcePresentation(
        for request: NetworkRequest,
        indentLevel: Int
    ) -> NetworkDisplayEntryPresentation {
        let facts = displayFacts(for: request, requiresResourceFilter: false)
        return NetworkDisplayEntryPresentation(
            displayName: facts.displayName,
            secondaryText: facts.byteRangeDisplayLabel,
            statusSeverity: request.statusSeverity,
            fileTypeLabel: facts.byteRangeDisplayLabel == nil ? facts.fileTypeLabel : "range",
            indentLevel: indentLevel,
            isExpandable: request.redirects.isEmpty == false,
            isExpanded: expandedRedirectResourceIDs.contains(request.id),
            style: .resource
        )
    }

    private func redirectPresentation(
        for hop: NetworkRequest.RedirectHop,
        indentLevel: Int
    ) -> NetworkDisplayEntryPresentation {
        NetworkDisplayEntryPresentation(
            displayName: "Redirect: \(NetworkRequest.Display.URLSummary(url: hop.request.url).displayName)",
            secondaryText: redirectStatusText(hop.response),
            statusSeverity: redirectStatusSeverity(hop.response),
            fileTypeLabel: String(hop.response.status),
            indentLevel: indentLevel,
            style: .redirect
        )
    }

    private func domNodeGroupPresentation(
        for group: NetworkDOMNodeGroup
    ) -> NetworkDisplayEntryPresentation {
        NetworkDisplayEntryPresentation(
            displayName: domNodeDisplayName(for: group.nodeID, fallbackRawNodeID: group.id.rawNodeID),
            secondaryText: "\(group.requestIDs.count) requests",
            statusSeverity: .neutral,
            fileTypeLabel: "group",
            isExpandable: true,
            isExpanded: isDOMNodeGroupExpanded(for: group.id),
            style: .domNodeGroup
        )
    }

    private func missingResourcePresentation(indentLevel: Int) -> NetworkDisplayEntryPresentation {
        NetworkDisplayEntryPresentation(
            displayName: "Missing request",
            statusSeverity: .neutral,
            fileTypeLabel: "-",
            indentLevel: indentLevel,
            style: .resource
        )
    }

    private func displayDOMNodeGroup(for groupID: NetworkDOMNodeGroup.ID) -> NetworkDOMNodeGroup? {
        ensureProjection().groupRequestIDsByID[groupID].map {
            NetworkDOMNodeGroup(
                id: groupID,
                nodeID: resolvedNodeID(for: groupID),
                requestIDs: Array($0.reversed())
            )
        }
    }

    private func displayFacts(
        for request: NetworkRequest,
        requiresResourceFilter: Bool
    ) -> NetworkRequestDisplayFacts {
        let revision = network.requestDisplayRevision(for: request.id)
        var facts: NetworkRequestDisplayFacts
        if let cached = displayFactsByRequestID[request.id],
           cached.requestDisplayRevision == revision {
            facts = cached
        } else {
            facts = NetworkRequestDisplayFacts(request: request, requestDisplayRevision: revision)
        }
        if requiresResourceFilter && facts.resourceFilter == nil {
            facts.resourceFilter = request.displayResourceFilter(mediaPreviewClassifier: mediaPreviewClassifier)
        }
        displayFactsByRequestID[request.id] = facts
        return facts
    }

    private func resolvedNodeID(for groupID: NetworkDOMNodeGroup.ID) -> DOMNode.ID? {
        domNodeResolver?.networkCurrentNodeID(
            targetID: groupID.targetID,
            rawNodeID: groupID.rawNodeID
        )
    }

    private func selectedEntryBelongsToDOMNodeGroup(_ groupID: NetworkDOMNodeGroup.ID) -> Bool {
        guard let selectedEntryID else {
            return false
        }
        switch selectedEntryID {
        case .domNodeGroup(let selectedGroupID):
            return selectedGroupID == groupID
        case .resource(let requestID):
            return requestIDBelongsToDOMNodeGroup(requestID, groupID: groupID)
        case .redirect(let redirectID):
            return requestIDBelongsToDOMNodeGroup(redirectID.requestKey, groupID: groupID)
        }
    }

    private func requestIDBelongsToDOMNodeGroup(
        _ requestID: NetworkRequest.ID,
        groupID: NetworkDOMNodeGroup.ID
    ) -> Bool {
        ensureProjection().groupIDByRequestID[requestID] == groupID
    }

    private func groupedDOMNodeGroupID(containing requestID: NetworkRequest.ID) -> NetworkDOMNodeGroup.ID? {
        ensureProjection().groupIDByRequestID[requestID]
    }

    private func reconcileSelectionAfterGroupingChange() {
        guard let selectedEntryID else {
            return
        }
        guard groupMediaRequestsByDOMNode else {
            if case .domNodeGroup = selectedEntryID {
                self.selectedEntryID = nil
            }
            return
        }

        switch selectedEntryID {
        case .domNodeGroup:
            return
        case .resource(let requestID):
            selectCollapsedDOMNodeGroupIfNeeded(containing: requestID)
        case .redirect(let redirectID):
            selectCollapsedDOMNodeGroupIfNeeded(containing: redirectID.requestKey)
        }
    }

    private func selectCollapsedDOMNodeGroupIfNeeded(containing requestID: NetworkRequest.ID) {
        guard let groupID = groupedDOMNodeGroupID(containing: requestID),
              isDOMNodeGroupExpanded(for: groupID) == false else {
            return
        }
        selectedEntryID = .domNodeGroup(groupID)
    }

    private func domNodeDisplayName(for nodeID: DOMNode.ID) -> String {
        domNodeDisplayName(for: nodeID, fallbackRawNodeID: nodeID.nodeID)
    }

    private func domNodeDisplayName(
        for nodeID: DOMNode.ID?,
        fallbackRawNodeID: DOMNode.ProtocolID
    ) -> String {
        guard let nodeID,
              let node = domNodeResolver?.networkNode(for: nodeID) else {
            return "DOM node \(fallbackRawNodeID.rawValue)"
        }
        let elementName = node.localName.isEmpty ? node.nodeName.lowercased() : node.localName
        var suffix = ""
        if let idAttribute = node.attributes.first(where: { $0.name.caseInsensitiveCompare("id") == .orderedSame }),
           idAttribute.value.isEmpty == false {
            suffix += "#\(idAttribute.value)"
        }
        if let classAttribute = node.attributes.first(where: { $0.name.caseInsensitiveCompare("class") == .orderedSame }),
           let firstClass = classAttribute.value
            .split(whereSeparator: \.isWhitespace)
            .first {
            suffix += ".\(firstClass)"
        }
        return "<\(elementName)\(suffix)>"
    }

    private func redirectStatusText(_ response: NetworkRequest.Response.Payload) -> String {
        let suffix = response.statusText.isEmpty ? "" : " \(response.statusText)"
        return "\(response.status)\(suffix)"
    }

    private func redirectStatusSeverity(_ response: NetworkRequest.Response.Payload) -> NetworkRequest.Display.StatusSeverity {
        if response.status >= 500 {
            return .error
        }
        if response.status >= 400 {
            return .warning
        }
        return .notice
    }
}

extension NetworkPanelModel {
    package enum SelectedEntry {
        case resource(NetworkRequest)
        case redirect(parent: NetworkRequest, hop: NetworkRequest.RedirectHop)
        case domNodeGroup(NetworkDOMNodeGroup)

        @MainActor
        package var id: NetworkDisplayEntry.ID {
            switch self {
            case .resource(let request):
                return .resource(request.id)
            case .redirect(_, let hop):
                return .redirect(hop.id)
            case .domNodeGroup(let group):
                return .domNodeGroup(group.id)
            }
        }

        package var resource: NetworkRequest? {
            switch self {
            case .resource(let request):
                return request
            case .redirect(let parent, _):
                return parent
            case .domNodeGroup:
                return nil
            }
        }

        package var supportsPreview: Bool {
            switch self {
            case .resource:
                return true
            case .redirect, .domNodeGroup:
                return false
            }
        }
    }

    package struct DisplayRowsInvalidationRevision: Equatable {
        package var searchText: String
        package var resourceFilters: Set<NetworkRequest.Display.ResourceFilter>
        package var requestOrderRevision: Int
        // This is included only when filters/search/grouping/expanded redirects can change row IDs.
        package var requestFactsRevision: Int?
        package var groupMediaRequestsByDOMNode: Bool
        package var redirectExpansion: Set<NetworkRequest.ID>
        package var collapsedDOMNodeGroups: Set<NetworkDOMNodeGroup.ID>
    }

    package struct DisplayRowsPresentationRevision: Equatable {
        package var requestPresentationRevision: Int
        package var domRevision: UInt64?
    }
}

private struct NetworkDisplayPresentationRevision: Equatable {
    var requestPresentationRevision: Int
    var domRevision: UInt64?
}

private struct NetworkDisplayProjectionCache {
    var projection: NetworkDisplayProjection?
}

private struct NetworkDisplayProjection {
    var topologyKey: NetworkPanelModel.DisplayRowsInvalidationRevision
    var presentationRevision: NetworkDisplayPresentationRevision
    var rows: [NetworkDisplayRow]
    var groupRequestIDsByID: [NetworkDOMNodeGroup.ID: [NetworkRequest.ID]]
    var groupIDByRequestID: [NetworkRequest.ID: NetworkDOMNodeGroup.ID]

    var entryIDs: [NetworkDisplayEntry.ID] {
        rows.map(\.id)
    }

    var requestIDs: [NetworkRequest.ID] {
        rows.compactMap { row in
            guard case .resource(let requestID, _) = row.entry.kind else {
                return nil
            }
            return requestID
        }
    }

    var presentationsByEntryID: [NetworkDisplayEntry.ID: NetworkDisplayEntryPresentation] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.presentation) })
    }
}

private struct NetworkMediaRequestGroups {
    var requestIDsByGroupID: [NetworkDOMNodeGroup.ID: [NetworkRequest.ID]]
    var groupIDByRequestID: [NetworkRequest.ID: NetworkDOMNodeGroup.ID]

    init(groupedRequestIDsByGroupID: [NetworkDOMNodeGroup.ID: [NetworkRequest.ID]]) {
        requestIDsByGroupID = groupedRequestIDsByGroupID.filter { $0.value.count > 1 }
        var groupIDByRequestID: [NetworkRequest.ID: NetworkDOMNodeGroup.ID] = [:]
        for (groupID, requestIDs) in requestIDsByGroupID {
            for requestID in requestIDs {
                groupIDByRequestID[requestID] = groupID
            }
        }
        self.groupIDByRequestID = groupIDByRequestID
    }
}

private struct NetworkRequestDisplayFacts {
    var requestID: NetworkRequest.ID
    var requestDisplayRevision: Int
    var displayName: String
    var searchTokens: [String]
    var fileTypeLabel: String
    var statusSeverity: NetworkRequest.Display.StatusSeverity
    var byteRangeDisplayLabel: String?
    var domNodeGroupID: NetworkDOMNodeGroup.ID?
    var isCheapMediaGroupingCandidate: Bool
    var resourceFilter: NetworkRequest.Display.ResourceFilter?

    @MainActor
    init(request: NetworkRequest, requestDisplayRevision: Int) {
        self.requestID = request.id
        self.requestDisplayRevision = requestDisplayRevision
        self.displayName = request.displayName
        self.searchTokens = request.displaySearchTokens
        self.fileTypeLabel = request.fileTypeLabel
        self.statusSeverity = request.statusSeverity
        self.byteRangeDisplayLabel = request.requestedByteRange?.displayLabel
        if let rawNodeID = request.initiator?.nodeID {
            self.domNodeGroupID = NetworkDOMNodeGroup.ID(
                targetID: request.id.targetID,
                rawNodeID: rawNodeID
            )
        } else {
            self.domNodeGroupID = nil
        }
        self.isCheapMediaGroupingCandidate = NetworkRequestDisplayFacts.isCheapMediaGroupingCandidate(request)
        self.resourceFilter = nil
    }

    func matchesSearch(_ query: String) -> Bool {
        guard query.isEmpty == false else {
            return true
        }
        return searchTokens.contains { $0.localizedStandardContains(query) }
    }

    @MainActor
    private static func isCheapMediaGroupingCandidate(_ request: NetworkRequest) -> Bool {
        if request.hasRequestedByteRangeHeader {
            return true
        }
        if request.resourceType?.rawValue == "Media" || request.resourceType == .image {
            return true
        }
        let requestMIMEType = NetworkRequest.Display.displayMIMEType(
            mimeType: nil,
            headers: request.request.headers
        )
        let responseMIMEType = request.response.map {
            NetworkRequest.Display.displayMIMEType(mimeType: $0.mimeType, headers: $0.headers)
        } ?? nil
        if isCheapMediaMIMEType(requestMIMEType) || isCheapMediaMIMEType(responseMIMEType) {
            return true
        }
        let requestURLSummary = NetworkRequest.Display.URLSummary(url: request.request.url)
        let responseURLSummary = request.response.map { NetworkRequest.Display.URLSummary(url: $0.url) }
        return isCheapMediaPathExtension(requestURLSummary.pathExtension)
            || isCheapMediaPathExtension(responseURLSummary?.pathExtension)
    }

    private static func isCheapMediaMIMEType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else {
            return false
        }
        return mimeType.hasPrefix("audio/")
            || mimeType.hasPrefix("video/")
            || mimeType.hasPrefix("image/")
            || mimeType == "application/vnd.apple.mpegurl"
            || mimeType == "application/x-mpegurl"
            || mimeType == "audio/mpegurl"
    }

    private static func isCheapMediaPathExtension(_ pathExtension: String?) -> Bool {
        guard let pathExtension = pathExtension?.lowercased() else {
            return false
        }
        return [
            "aac", "apng", "avif", "gif", "jpg", "jpeg", "m3u8", "m4a", "m4v",
            "mov", "mp3", "mp4", "ogg", "png", "wav", "webm", "webp",
        ].contains(pathExtension)
    }
}
