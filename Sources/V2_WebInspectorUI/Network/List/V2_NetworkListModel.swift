import Observation
import V2_WebInspectorCore

@MainActor
@Observable
package final class V2_NetworkListModel {
    package let network: NetworkSession
    package var selectedRequestID: NetworkRequest.ID?
    package var searchText: String = ""
    package var activeResourceFilters: Set<V2_NetworkResourceFilter> = [] {
        didSet {
            let normalized = V2_NetworkResourceFilter.normalizedSelection(activeResourceFilters)
            if effectiveResourceFilters != normalized {
                effectiveResourceFilters = normalized
            }
        }
    }
    package private(set) var effectiveResourceFilters: Set<V2_NetworkResourceFilter> = []

    package init(network: NetworkSession) {
        self.network = network
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

    package func setResourceFilter(_ filter: V2_NetworkResourceFilter, enabled: Bool) {
        var nextFilters = activeResourceFilters
        if enabled {
            nextFilters.insert(filter)
        } else {
            nextFilters.remove(filter)
        }
        nextFilters = V2_NetworkResourceFilter.normalizedSelection(nextFilters)
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
}
