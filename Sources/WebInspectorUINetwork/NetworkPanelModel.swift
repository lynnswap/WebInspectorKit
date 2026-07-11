import Foundation
import Observation
import WebInspectorDataKit
import WebInspectorUIBase

@MainActor
private final class NetworkResponseBodyFetchCoordinator {
    private var fetchesInFlight: Set<NetworkRequest.ID> = []

    init() {}

    func fetchIfNeeded(
        for request: NetworkRequest,
        context: WebInspectorModelContext
    ) {
        guard request.canFetchResponseBody,
              fetchesInFlight.contains(request.id) == false else {
            return
        }
        fetchesInFlight.insert(request.id)
        Task { @MainActor in
            defer {
                fetchesInFlight.remove(request.id)
            }
            do {
                _ = try await context.responseBody(for: request)
            } catch {
                return
            }
        }
    }
}

@MainActor
@Observable
package final class NetworkPanelModel {
    private enum Lifecycle {
        case active
        case retiring(Task<Void, Never>?)
        case retired
    }

    package let context: WebInspectorModelContext
    package let requests: WebInspectorFetchedResults<NetworkRequest>
    private let collectionState: NetworkRequestCollectionState
    package private(set) var selectedRequestID: NetworkRequest.ID?
    package private(set) var searchText: String
    package private(set) var activeResourceFilters: Set<NetworkDisplay.ResourceFilter>
    package private(set) var query: NetworkQuery
    package private(set) var queryRevision: UInt64
    package private(set) var appliedQueryRevision: UInt64
    @ObservationIgnored private let responseBodyFetchCoordinator: NetworkResponseBodyFetchCoordinator
    @ObservationIgnored private var queryUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var queryUpdateTaskIsCommittedClear: Bool
    @ObservationIgnored private var queryGeneration: UInt64
    @ObservationIgnored private var lifecycle: Lifecycle

    private init(
        context: WebInspectorModelContext,
        requests: WebInspectorFetchedResults<NetworkRequest>,
        query: NetworkQuery
    ) {
        self.context = context
        self.requests = requests
        self.collectionState = context.networkRequestsCollectionState
        self.searchText = query.search ?? ""
        self.activeResourceFilters = []
        self.query = query
        self.queryRevision = 0
        self.appliedQueryRevision = 0
        self.responseBodyFetchCoordinator = NetworkResponseBodyFetchCoordinator()
        self.queryGeneration = 0
        self.queryUpdateTaskIsCommittedClear = false
        self.lifecycle = .active
    }

    /// Creates a ready Network panel after its atomic initial query snapshot is available.
    package static func make(context: WebInspectorModelContext) async throws -> NetworkPanelModel {
        let query = NetworkQuery(sort: .requestTimeDescending)
        let requests = try await context.networkRequests(matching: query)
        return NetworkPanelModel(context: context, requests: requests, query: query)
    }

    isolated deinit {
        synchronouslyCancelForOwnerDeinit()
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

    package var hasClearableRequests: Bool {
        collectionState.hasRequests
    }

    package var effectiveResourceFilters: Set<NetworkDisplay.ResourceFilter> {
        NetworkDisplay.ResourceFilter.normalizedSelection(activeResourceFilters)
    }

    package var selectedRequest: NetworkRequest? {
        guard let selectedRequestID else {
            return nil
        }
        // Observe the unfiltered request topology so registry removals invalidate
        // the selection without tying selection lifetime to display filters.
        _ = collectionState.topologyRevision
        return request(for: selectedRequestID)
    }

    package func request(for id: NetworkRequest.ID) -> NetworkRequest? {
        try? context.networkRequest(id: id)
    }

    package func selectRequest(_ request: NetworkRequest?) {
        requireActive()
        selectedRequestID = request?.id
    }

    package func setSearchText(_ text: String) {
        requireActive()
        guard searchText != text else {
            return
        }
        searchText = text
        scheduleQueryUpdate()
    }

    package func setResourceFilter(_ filter: NetworkDisplay.ResourceFilter, enabled: Bool) {
        requireActive()
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
        scheduleQueryUpdate()
    }

    package func clearResourceFilters() {
        requireActive()
        guard activeResourceFilters.isEmpty == false else {
            return
        }
        activeResourceFilters = []
        scheduleQueryUpdate()
    }

    package func clearRequests() {
        requireActive()
        selectedRequestID = nil
        precondition(queryGeneration < UInt64.max, "Network panel operation generation overflowed.")
        queryGeneration += 1
        let generation = queryGeneration
        let revision = queryRevision
        let query = query
        let previousTask = queryUpdateTask
        if queryUpdateTaskIsCommittedClear == false {
            previousTask?.cancel()
        }
        queryUpdateTaskIsCommittedClear = true
        let context = context
        let requests = requests
        queryUpdateTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard Task.isCancelled == false else {
                return
            }
            // Clear is a committed user operation, not a query candidate. Once
            // scheduled it completes even if a later query supersedes this task.
            await context.clearNetworkRequests()
            guard self?.isActiveQueryGeneration(generation) == true else {
                return
            }
            guard self?.appliedQueryRevision != revision else {
                return
            }
            do {
                try await requests.update(query)
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("Network query restoration after clear failed: \(error)")
            }
            guard let self,
                  isActiveQueryGeneration(generation) else {
                return
            }
            appliedQueryRevision = revision
        }
    }

    package func fetchResponseBodyIfNeeded(for request: NetworkRequest) {
        requireActive()
        responseBodyFetchCoordinator.fetchIfNeeded(for: request, context: context)
    }

    /// Cancels and awaits the current query replacement before releasing this owner.
    package func retire() async {
        switch lifecycle {
        case .active:
            let task = queryUpdateTask
            queryUpdateTask = nil
            task?.cancel()
            lifecycle = .retiring(task)
            await task?.value
            lifecycle = .retired
        case let .retiring(task):
            await task?.value
            lifecycle = .retired
        case .retired:
            return
        }
    }

    /// Synchronous backstop used only when the presentation resource owner is
    /// itself deinitializing and can no longer await ``retire()``.
    package func synchronouslyCancelForOwnerDeinit() {
        queryUpdateTask?.cancel()
        queryUpdateTask = nil
        queryUpdateTaskIsCommittedClear = false
        if case let .retiring(task) = lifecycle {
            task?.cancel()
        }
        lifecycle = .retired
    }

    /// Waits until the latest scheduled query replacement reaches a terminal state.
    package func waitForQueryUpdates() async {
        while true {
            let generation = queryGeneration
            let task = queryUpdateTask
            await task?.value
            if generation == queryGeneration {
                return
            }
        }
    }

    private func scheduleQueryUpdate() {
        let nextQuery = Self.makeNetworkQuery(
            searchText: searchText,
            filters: effectiveResourceFilters
        )
        guard query != nextQuery else {
            return
        }

        precondition(queryGeneration < UInt64.max, "Network panel query generation overflowed.")
        precondition(queryRevision < UInt64.max, "Network panel query revision overflowed.")
        queryGeneration += 1
        queryRevision += 1
        query = nextQuery

        let generation = queryGeneration
        let revision = queryRevision
        let previousTask = queryUpdateTask
        if queryUpdateTaskIsCommittedClear == false {
            previousTask?.cancel()
        }
        queryUpdateTaskIsCommittedClear = false
        let requests = requests
        queryUpdateTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard self?.isActiveQueryGeneration(generation) == true else {
                return
            }
            do {
                try await requests.update(nextQuery)
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("Network query replacement failed: \(error)")
            }
            guard let self,
                  isActiveQueryGeneration(generation) else {
                return
            }
            appliedQueryRevision = revision
        }
    }

    private func requireActive() {
        guard case .active = lifecycle else {
            preconditionFailure("A retired NetworkPanelModel cannot accept new work.")
        }
    }

    private func isActiveQueryGeneration(_ generation: UInt64) -> Bool {
        guard case .active = lifecycle else {
            return false
        }
        return queryGeneration == generation
    }

    #if DEBUG
    package var isRetiredForTesting: Bool {
        if case .retired = lifecycle {
            return true
        }
        return false
    }
    #endif

    private static func makeNetworkQuery(
        searchText: String,
        filters: Set<NetworkDisplay.ResourceFilter>
    ) -> NetworkQuery {
        NetworkQuery(
            search: searchText,
            resourceCategories: NetworkRequest.ResourceCategory.networkCategories(for: filters),
            sort: .requestTimeDescending
        )
    }
}

private extension NetworkRequest.ResourceCategory {
    static func networkCategories(
        for filters: Set<NetworkDisplay.ResourceFilter>
    ) -> Set<NetworkRequest.ResourceCategory> {
        var categories: Set<NetworkRequest.ResourceCategory> = []
        for filter in NetworkDisplay.ResourceFilter.pickerCases where filters.contains(filter) {
            categories.formUnion(filter.networkResourceCategories)
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
