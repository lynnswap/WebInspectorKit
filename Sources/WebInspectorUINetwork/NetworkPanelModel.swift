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
                updateNetworkFetchDescriptor()
            }
        }
    }
    package private(set) var effectiveResourceFilters: Set<NetworkDisplay.ResourceFilter> = []
    @ObservationIgnored private let responseBodyFetchCoordinator: NetworkResponseBodyFetchCoordinator

    package init(context: WebInspectorContext) {
        self.context = context
        self.requests = context.fetchedResults(for: Self.makeNetworkFetchDescriptor(searchText: "", filters: []))
        self.responseBodyFetchCoordinator = NetworkResponseBodyFetchCoordinator()
    }

    package var displayRequestIDs: [NetworkRequest.ID] {
        requests.items.map(\.id)
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
        return DisplayRowsInvalidationRevision(
            searchText: query,
            resourceFilters: resourceFilters,
            topologyRevision: requests.topologyRevision,
            entries: []
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
        updateNetworkFetchDescriptor()
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

    private func updateNetworkFetchDescriptor() {
        requests.updateFetchDescriptor(
            Self.makeNetworkFetchDescriptor(
                searchText: normalizedSearchText,
                filters: effectiveResourceFilters
            )
        )
    }

    private static func makeNetworkFetchDescriptor(
        searchText: String,
        filters: Set<NetworkDisplay.ResourceFilter>
    ) -> WebInspectorFetchDescriptor<NetworkRequest> {
        let categories = NetworkRequest.ResourceCategory.networkCategories(for: filters)
        let normalizedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let predicate: Predicate<NetworkRequest>?
        if normalizedSearchText.isEmpty, categories.isEmpty {
            predicate = nil
        } else if categories.isEmpty {
            predicate = #Predicate { request in
                request.searchableText.localizedStandardContains(normalizedSearchText)
            }
        } else if normalizedSearchText.isEmpty {
            predicate = #Predicate { request in
                categories.contains(request.resourceCategory)
            }
        } else {
            predicate = #Predicate { request in
                categories.contains(request.resourceCategory)
                    && request.searchableText.localizedStandardContains(normalizedSearchText)
            }
        }
        return WebInspectorFetchDescriptor(
            predicate: predicate,
            sortBy: [SortDescriptor(\.requestSentTimestamp, order: .reverse)]
        )
    }
}

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

private extension NetworkRequest.ResourceCategory {
    static func networkCategories(
        for filters: Set<NetworkDisplay.ResourceFilter>
    ) -> [NetworkRequest.ResourceCategory] {
        var categories: [NetworkRequest.ResourceCategory] = []
        for filter in NetworkDisplay.ResourceFilter.pickerCases where filters.contains(filter) {
            categories.append(contentsOf: filter.networkResourceCategories)
        }
        return categories
    }
}

private extension NetworkDisplay.ResourceFilter {
    var networkResourceCategories: [NetworkRequest.ResourceCategory] {
        switch self {
        case .all:
            []
        case .document:
            [.document]
        case .stylesheet:
            [.stylesheet]
        case .media:
            [.image, .media]
        case .font:
            [.font]
        case .script:
            [.script]
        case .xhrFetch:
            [.xhrFetch]
        case .other:
            [.webSocket, .other]
        }
    }
}
