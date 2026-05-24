import Observation
import WebInspectorCore

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

    package init(
        network: NetworkSession,
        responseBodyFetchAction: ResponseBodyFetchAction? = nil
    ) {
        self.network = network
        self.responseBodyFetchAction = responseBodyFetchAction
    }

    package var displayRequests: [NetworkRequest] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return network.requests
            .filter { request in
                if effectiveResourceFilters.isEmpty == false,
                   effectiveResourceFilters.contains(request.resourceFilter) == false {
                    return false
                }
                return request.matchesSearchText(trimmedQuery)
            }
            .reversed()
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
    }

    package func fetchResponseBodyIfNeeded(for request: NetworkRequest) {
        guard request.responseBody?.needsFetch == true,
              let responseBodyFetchAction else {
            return
        }
        Task { @MainActor in
            await responseBodyFetchAction(request.id)
        }
    }
}
