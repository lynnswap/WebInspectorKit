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

    package init(
        network: NetworkSession,
        responseBodyFetchAction: ResponseBodyFetchAction? = nil,
        mediaPreviewClassifier: @escaping NetworkRequest.Display.MediaPreviewClassifier = { mimeType, url in
            NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    ) {
        self.network = network
        self.responseBodyFetchCoordinator = NetworkResponseBodyFetchCoordinator(action: responseBodyFetchAction)
        self.mediaPreviewClassifier = mediaPreviewClassifier
    }

    package var displayRequestIDs: [NetworkRequest.ID] {
        let requestIDs = network.orderedRequestIDs
        let query = normalizedSearchText
        let resourceFilters = effectiveResourceFilters
        guard query.isEmpty == false || resourceFilters.isEmpty == false else {
            return Array(requestIDs.reversed())
        }

        var filteredIDs: [NetworkRequest.ID] = []
        filteredIDs.reserveCapacity(requestIDs.count)
        for requestID in requestIDs {
            guard let request = network.request(for: requestID) else {
                continue
            }
            if resourceFilters.isEmpty == false,
               resourceFilters.contains(request.displayResourceFilter(mediaPreviewClassifier: mediaPreviewClassifier)) == false {
                continue
            }
            guard request.matchesDisplaySearchText(query) else {
                continue
            }
            filteredIDs.append(requestID)
        }
        return Array(filteredIDs.reversed())
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

extension NetworkPanelModel {
    package struct DisplayRowsInvalidationRevision: Equatable {
        package var searchText: String
        package var resourceFilters: Set<NetworkRequest.Display.ResourceFilter>
        package var topologyRevision: Int
        package var displayRevision: Int?
    }
}
