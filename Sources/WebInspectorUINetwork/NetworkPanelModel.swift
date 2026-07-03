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
        network: NetworkSession,
        responseBodyFetchAction: ResponseBodyFetchAction? = nil,
        mediaPreviewClassifier: @escaping NetworkDisplay.MediaPreviewClassifier = { mimeType, url in
            NetworkDisplay.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    ) {
        self.network = network
        self.responseBodyFetchCoordinator = NetworkResponseBodyFetchCoordinator(action: responseBodyFetchAction)
        self.mediaPreviewClassifier = mediaPreviewClassifier
        self.displayIndex = NetworkPanelDisplayIndex()
    }

    package var displayRequestIDs: [NetworkRequest.ID] {
        let requestIDs = network.orderedRequestIDs
        let criteria = NetworkPanelDisplayCriteria(
            searchText: normalizedSearchText,
            resourceFilters: effectiveResourceFilters
        )
        return displayIndex.reconcile(
            network: network,
            orderedRequestIDs: requestIDs,
            criteria: criteria,
            topologyRevision: network.requestTopologyRevision,
            displayRevision: criteria.requiresEntries ? network.requestDisplayRevision : nil,
            mediaPreviewClassifier: mediaPreviewClassifier
        )
    }

    package var displayRequests: [NetworkRequest] {
        displayRequestIDs.compactMap { network.request(for: $0) }
    }

    package var isEmpty: Bool {
        network.orderedRequestIDs.isEmpty
    }

    package var displayRowsInvalidationRevision: DisplayRowsInvalidationRevision {
        let query = normalizedSearchText
        let resourceFilters = effectiveResourceFilters
        return DisplayRowsInvalidationRevision(
            searchText: query,
            resourceFilters: resourceFilters,
            topologyRevision: network.requestTopologyRevision,
            displayRevision: query.isEmpty && resourceFilters.isEmpty ? nil : network.requestDisplayRevision
        )
    }

    package var selectedRequest: NetworkRequest? {
        guard let selectedRequestID else {
            return nil
        }
        return network.request(for: selectedRequestID)
    }

    package func request(for id: NetworkRequest.ID) -> NetworkRequest? {
        network.request(for: id)
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
        network.reset()
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
    package struct DisplayRowsInvalidationRevision: Equatable {
        package var searchText: String
        package var resourceFilters: Set<NetworkDisplay.ResourceFilter>
        package var topologyRevision: Int
        package var displayRevision: Int?
    }
}
