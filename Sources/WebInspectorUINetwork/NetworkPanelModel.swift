import WebInspectorUIBase
import WebInspectorDataKit
import Foundation
import Observation

@MainActor
private final class NetworkResponseBodyFetchCoordinator {
    private var fetchesInFlight: Set<NetworkRequest.ID> = []

    init() {}

    func fetchIfNeeded(for request: NetworkRequest) {
        guard request.canFetchResponseBody,
              fetchesInFlight.contains(request.id) == false else {
            return
        }
        fetchesInFlight.insert(request.id)
        Task { @MainActor in
            defer {
                fetchesInFlight.remove(request.id)
            }
            await request.fetchResponseBody()
        }
    }
}

@MainActor
@Observable
package final class NetworkPanelModel {
    package let context: WebInspectorContext
    package let requests: WebInspectorFetchedResults<NetworkRequest>
    package var selectedRequestID: NetworkRequest.ID?
    package var searchText: String = ""
    package var activeResourceFilters: Set<NetworkDisplay.ResourceFilter> = [] {
        didSet {
            let normalized = NetworkDisplay.ResourceFilter.normalizedSelection(activeResourceFilters)
            if effectiveResourceFilters != normalized {
                effectiveResourceFilters = normalized
            }
        }
    }
    package private(set) var effectiveResourceFilters: Set<NetworkDisplay.ResourceFilter> = []
    @ObservationIgnored private let responseBodyFetchCoordinator: NetworkResponseBodyFetchCoordinator
    @ObservationIgnored private let mediaPreviewClassifier: NetworkDisplay.MediaPreviewClassifier
    @ObservationIgnored private var displayIndex: NetworkPanelDisplayIndex

    package init(
        context: WebInspectorContext,
        mediaPreviewClassifier: @escaping NetworkDisplay.MediaPreviewClassifier = { mimeType, url in
            NetworkDisplay.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    ) {
        self.context = context
        self.requests = context.fetchedResults()
        self.responseBodyFetchCoordinator = NetworkResponseBodyFetchCoordinator()
        self.mediaPreviewClassifier = mediaPreviewClassifier
        self.displayIndex = NetworkPanelDisplayIndex()
    }

    package var displayRequestIDs: [NetworkRequest.ID] {
        let currentRequests = requests.items
        let criteria = NetworkPanelDisplayCriteria(
            searchText: normalizedSearchText,
            resourceFilters: effectiveResourceFilters
        )
        return displayIndex.reconcile(
            requests: currentRequests,
            criteria: criteria,
            mediaPreviewClassifier: mediaPreviewClassifier
        )
    }

    package var displayRequests: [NetworkRequest] {
        displayRequestIDs.compactMap { request(for: $0) }
    }

    package var isEmpty: Bool {
        requests.items.isEmpty
    }

    package var displayRowsInvalidationRevision: DisplayRowsInvalidationRevision {
        let query = normalizedSearchText
        let resourceFilters = effectiveResourceFilters
        let criteria = NetworkPanelDisplayCriteria(
            searchText: query,
            resourceFilters: resourceFilters
        )
        let entries: [DisplayRowsInvalidationEntry] = if criteria.requiresEntries {
            requests.items.map { request in
                DisplayRowsInvalidationEntry(
                    requestID: request.id,
                    signature: request.displayInvalidationSignature
                )
            }
        } else {
            []
        }
        return DisplayRowsInvalidationRevision(
            searchText: query,
            resourceFilters: resourceFilters,
            topologyRevision: requests.topologyRevision,
            entries: entries
        )
    }

    package var selectedRequest: NetworkRequest? {
        guard let selectedRequestID else {
            return nil
        }
        return requests.items.first { $0.id == selectedRequestID }
    }

    package func request(for id: NetworkRequest.ID) -> NetworkRequest? {
        context.registeredRequest(for: id)
    }

    package func selectRequest(_ request: NetworkRequest?) {
        selectedRequestID = request?.id
    }

    package func setSearchText(_ text: String) {
        guard searchText != text else {
            return
        }
        searchText = text
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
    }

    package func clearResourceFilters() {
        guard activeResourceFilters.isEmpty == false else {
            return
        }
        activeResourceFilters = []
    }

    package func clearRequests() {
        selectedRequestID = nil
        context.clearNetworkRequests()
    }

    package func fetchResponseBodyIfNeeded(for request: NetworkRequest) {
        responseBodyFetchCoordinator.fetchIfNeeded(for: request)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if DEBUG
extension NetworkPanelModel {
    package var displayEntryBuildCountForTesting: Int {
        displayIndex.displayEntryBuildCount
    }

    package var rebuiltDisplayRequestIDsForTesting: [NetworkRequest.ID] {
        displayIndex.rebuiltDisplayRequestIDs
    }

    package var displayEntryCacheCountForTesting: Int {
        displayIndex.displayEntryCacheCount
    }

    package var fullMembershipEvaluationCountForTesting: Int {
        displayIndex.fullMembershipEvaluationCount
    }

    package func resetDisplayIndexTestingCounters() {
        displayIndex.resetTestingCounters()
    }
}
#endif

extension NetworkPanelModel {
    package struct DisplayRowsInvalidationEntry: Equatable {
        package var requestID: NetworkRequest.ID
        package var signature: NetworkRequest.DisplayInvalidationSignature
    }

    package struct DisplayRowsInvalidationRevision: Equatable {
        package var searchText: String
        package var resourceFilters: Set<NetworkDisplay.ResourceFilter>
        package var topologyRevision: Int
        package var entries: [DisplayRowsInvalidationEntry]
    }
}
