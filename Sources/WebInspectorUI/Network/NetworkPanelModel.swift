import WebInspectorCore
import Observation

@MainActor
@Observable
package final class NetworkPanelModel {
    package typealias ResponseBodyFetchAction = @MainActor (NetworkRequest.ID) async -> Void

    package let network: NetworkSession
    package var selectedRequestID: NetworkRequest.ID?
    package var searchText: String = ""
    package var activeResourceFilters: Set<NetworkResourceFilter> = [] {
        didSet {
            let normalized = NetworkResourceFilter.normalizedSelection(activeResourceFilters)
            if effectiveResourceFilters != normalized {
                effectiveResourceFilters = normalized
            }
        }
    }
    package private(set) var effectiveResourceFilters: Set<NetworkResourceFilter> = []
    @ObservationIgnored private let responseBodyFetchAction: ResponseBodyFetchAction?
    @ObservationIgnored private var responseBodyFetchesInFlight: Set<NetworkRequest.ID> = []
    @ObservationIgnored private let displayProjectionCache: NetworkRequestDisplayProjectionCache

    package init(
        network: NetworkSession,
        responseBodyFetchAction: ResponseBodyFetchAction? = nil,
        mediaPreviewClassifier: @escaping NetworkMediaPreviewClassifier = { mimeType, url in
            NetworkMediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    ) {
        self.network = network
        self.responseBodyFetchAction = responseBodyFetchAction
        self.displayProjectionCache = NetworkRequestDisplayProjectionCache(
            mediaPreviewClassifier: mediaPreviewClassifier
        )
    }

    package var displayRows: [NetworkRequestDisplayProjection] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let requests = network.requests
        let effectiveResourceFilters = effectiveResourceFilters
        displayProjectionCache.prune(keeping: Set(requests.map(\.id)))
        let rows = requests.compactMap { request -> NetworkRequestDisplayProjection? in
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

    package func displayProjection(for id: NetworkRequest.ID) -> NetworkRequestDisplayProjection? {
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

    package func setResourceFilter(_ filter: NetworkResourceFilter, enabled: Bool) {
        var nextFilters = activeResourceFilters
        if enabled {
            nextFilters.insert(filter)
        } else {
            nextFilters.remove(filter)
        }
        nextFilters = NetworkResourceFilter.normalizedSelection(nextFilters)
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
        guard request.canFetchResponseBody,
              responseBodyFetchesInFlight.contains(request.id) == false,
              let responseBodyFetchAction else {
            return
        }
        responseBodyFetchesInFlight.insert(request.id)
        Task { @MainActor in
            defer {
                responseBodyFetchesInFlight.remove(request.id)
            }
            await responseBodyFetchAction(request.id)
        }
    }
}
