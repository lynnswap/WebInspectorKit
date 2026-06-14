import WebInspectorCore
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
    @ObservationIgnored private let displayProjectionCache: NetworkRequest.Display.ProjectionCache

    package init(
        network: NetworkSession,
        responseBodyFetchAction: ResponseBodyFetchAction? = nil,
        mediaPreviewClassifier: @escaping NetworkRequest.Display.MediaPreviewClassifier = { mimeType, url in
            NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    ) {
        self.network = network
        self.responseBodyFetchCoordinator = NetworkResponseBodyFetchCoordinator(action: responseBodyFetchAction)
        self.displayProjectionCache = NetworkRequest.Display.ProjectionCache(
            mediaPreviewClassifier: mediaPreviewClassifier
        )
    }

    package var displayRows: [NetworkRequest.Display.Projection] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let requests = network.requests
        let effectiveResourceFilters = effectiveResourceFilters
        displayProjectionCache.prune(keeping: Set(requests.map(\.id)))
        let rows = requests.compactMap { request -> NetworkRequest.Display.Projection? in
            if effectiveResourceFilters.isEmpty == false {
                let resourceFilter = displayProjectionCache.resourceFilter(for: request)
                guard effectiveResourceFilters.contains(resourceFilter) else {
                    return nil
                }
            }
            let projection = displayProjectionCache.projection(for: request)
            guard projection.matchesSearchText(trimmedQuery) else {
                return nil
            }
            return projection
        }
        return Array(rows.reversed())
    }

    package var displayRequestIDs: [NetworkRequest.ID] {
        displayRows.map(\.id)
    }

    package var displayRequests: [NetworkRequest] {
        displayRequestIDs.compactMap { network.request(for: $0) }
    }

    package var isEmpty: Bool {
        network.requests.isEmpty
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

    package func displayProjection(for id: NetworkRequest.ID) -> NetworkRequest.Display.Projection? {
        guard let request = network.request(for: id) else {
            return nil
        }
        return displayProjectionCache.projection(for: request)
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
        displayProjectionCache.removeAll()
    }

    package func fetchResponseBodyIfNeeded(for request: NetworkRequest) {
        responseBodyFetchCoordinator.fetchIfNeeded(for: request)
    }
}
