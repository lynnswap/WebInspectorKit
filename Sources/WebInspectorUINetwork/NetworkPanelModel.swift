import Foundation
import Observation
import WebInspectorDataKit
import WebInspectorUIBase

package struct NetworkPanelSelectionToken: Hashable, Sendable {
    package let entryID: NetworkEntry.ID
}

@MainActor
private final class NetworkResponseBodyFetchCoordinator {
    private var fetchesInFlight: Set<NetworkRequest.ID> = []

    init() {}

    func fetchIfNeeded(for request: NetworkRequest) {
        guard request.canFetchResponseBody,
            fetchesInFlight.contains(request.id) == false
        else {
            return
        }
        fetchesInFlight.insert(request.id)
        let body = request.responseBody
        Task { @MainActor [weak self] in
            defer {
                self?.fetchesInFlight.remove(request.id)
            }
            do {
                _ = try await body.load()
            } catch WebInspectorModelError.staleModel {
                return
            } catch {
                guard case .failed = body.phase else {
                    preconditionFailure(
                        "A failed Network.getResponseBody operation must publish its failure on NetworkBody."
                    )
                }
            }
        }
    }
}

@MainActor
@Observable
package final class NetworkPanelModel {
    private struct QueryCriteria: Equatable {
        var searchText: String
        var resourceCategories: Set<NetworkRequest.ResourceCategory>
    }

    private enum Lifecycle {
        case active
        case retiring(Task<Void, Never>?)
        case retired
    }

    package let context: WebInspectorModelContext
    package let entries: WebInspectorFetchedResultsController<NetworkEntry, Never>
    package private(set) var selectionToken: NetworkPanelSelectionToken?
    package private(set) var searchText: String
    package private(set) var activeResourceFilters: Set<NetworkDisplay.ResourceFilter>
    package private(set) var queryRevision: UInt64
    package private(set) var appliedQueryRevision: UInt64
    @ObservationIgnored private let responseBodyFetchCoordinator: NetworkResponseBodyFetchCoordinator
    @ObservationIgnored private var queryUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var queryGeneration: UInt64
    @ObservationIgnored private var committedCriteria: QueryCriteria
    @ObservationIgnored private var lifecycle: Lifecycle

    private init(
        context: WebInspectorModelContext,
        entries: WebInspectorFetchedResultsController<NetworkEntry, Never>,
        criteria: QueryCriteria
    ) {
        self.context = context
        self.entries = entries
        searchText = criteria.searchText
        activeResourceFilters = []
        queryRevision = 0
        appliedQueryRevision = 0
        responseBodyFetchCoordinator = NetworkResponseBodyFetchCoordinator()
        queryGeneration = 0
        committedCriteria = criteria
        lifecycle = .active
    }

    /// Creates a ready Network panel after its atomic initial entry snapshot is available.
    package static func make(context: WebInspectorModelContext) async throws -> NetworkPanelModel {
        let criteria = QueryCriteria(searchText: "", resourceCategories: [])
        let entries = try await WebInspectorFetchedResultsController<NetworkEntry, Never>(
            fetchDescriptor: makeFetchDescriptor(for: criteria),
            modelContext: context,
            isolation: MainActor.shared
        )
        return NetworkPanelModel(
            context: context,
            entries: entries,
            criteria: criteria
        )
    }

    isolated deinit {
        synchronouslyCancelForOwnerDeinit()
    }

    package var selectedEntryID: NetworkEntry.ID? {
        liveSelectionToken?.entryID
    }

    package var hasAvailableSelection: Bool {
        liveSelectionToken != nil
    }

    package var isEmpty: Bool {
        entries.snapshot.itemIDs.isEmpty
    }

    package var hasClearableRequests: Bool {
        entries.snapshot.itemIDs.isEmpty == false
    }

    package var effectiveResourceFilters: Set<NetworkDisplay.ResourceFilter> {
        NetworkDisplay.ResourceFilter.normalizedSelection(activeResourceFilters)
    }

    package var selectedEntry: NetworkEntry? {
        guard let token = liveSelectionToken else {
            return nil
        }
        return context.model(for: token.entryID)
    }

    package var selectedRequest: NetworkRequest? {
        selectedRequests.first
    }

    package var selectedRequests: [NetworkRequest] {
        guard let entry = selectedEntry else {
            return []
        }
        return entry.requestIDs.map { requestID in
            guard let request = context.model(for: requestID) else {
                preconditionFailure(
                    "A current NetworkEntry member must resolve in the same ModelContext."
                )
            }
            return request
        }
    }

    package func selectEntry(_ id: NetworkEntry.ID?) {
        requireActive()
        guard let id,
            entries.snapshot.itemIDs.contains(id),
            context.model(for: id) != nil
        else {
            selectionToken = nil
            return
        }
        selectionToken = NetworkPanelSelectionToken(entryID: id)
    }

    package func selectRequest(_ request: NetworkRequest?) {
        requireActive()
        guard let request else {
            selectionToken = nil
            return
        }
        let entryID = entries.snapshot.itemIDs.first { entryID in
            context.model(for: entryID)?.requestIDs.contains(request.id) == true
        }
        selectEntry(entryID)
    }

    package func clearSelection(ifStillSelected token: NetworkPanelSelectionToken) {
        requireActive()
        guard selectionToken == token else {
            return
        }
        selectionToken = nil
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
        selectionToken = nil
        let context = context
        Task { @MainActor in
            do {
                try await context.clearNetworkRequests()
            } catch {
                preconditionFailure("Canonical Network clear failed: \(error)")
            }
        }
    }

    package func fetchResponseBodyIfNeeded(for request: NetworkRequest) {
        requireActive()
        responseBodyFetchCoordinator.fetchIfNeeded(for: request)
    }

    /// Cancels query replacement and closes its fetched-results owner.
    package func retire() async {
        switch lifecycle {
        case .active:
            let task = queryUpdateTask
            queryUpdateTask = nil
            task?.cancel()
            lifecycle = .retiring(task)
            await task?.value
            await entries.close()
            lifecycle = .retired
        case let .retiring(task):
            await task?.value
            lifecycle = .retired
        case .retired:
            return
        }
    }

    /// Synchronous backstop used only when the presentation resource owner is deinitializing.
    package func synchronouslyCancelForOwnerDeinit() {
        queryUpdateTask?.cancel()
        queryUpdateTask = nil
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
        let criteria = QueryCriteria(
            searchText: Self.normalizedSearchText(searchText),
            resourceCategories: NetworkRequest.ResourceCategory.networkCategories(
                for: effectiveResourceFilters
            )
        )
        guard committedCriteria != criteria else {
            return
        }

        precondition(queryGeneration < UInt64.max, "Network panel query generation overflowed.")
        precondition(queryRevision < UInt64.max, "Network panel query revision overflowed.")
        queryGeneration += 1
        queryRevision += 1

        let generation = queryGeneration
        let revision = queryRevision
        let previousTask = queryUpdateTask
        previousTask?.cancel()
        let entries = entries
        let descriptor = Self.makeFetchDescriptor(for: criteria)
        queryUpdateTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard self?.isActiveQueryGeneration(generation) == true else {
                return
            }
            do {
                try await entries.update(descriptor)
            } catch is CancellationError {
                return
            } catch {
                preconditionFailure("Network entry query replacement failed: \(error)")
            }
            guard let self,
                isActiveQueryGeneration(generation)
            else {
                return
            }
            committedCriteria = criteria
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

    private var liveSelectionToken: NetworkPanelSelectionToken? {
        guard let selectionToken,
            entries.snapshot.itemIDs.contains(selectionToken.entryID),
            context.model(for: selectionToken.entryID) != nil
        else {
            return nil
        }
        return selectionToken
    }

    #if DEBUG
        package var isRetiredForTesting: Bool {
            if case .retired = lifecycle {
                return true
            }
            return false
        }
    #endif

    private static func normalizedSearchText(_ searchText: String) -> String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeFetchDescriptor(
        for criteria: QueryCriteria
    ) -> WebInspectorFetchDescriptor<NetworkEntry> {
        let searchText = normalizedSearchText(criteria.searchText)
        let categories = criteria.resourceCategories
        let predicate: Predicate<NetworkEntry.QueryValue>?
        switch (searchText.isEmpty, categories.isEmpty) {
        case (true, true):
            predicate = nil
        case (false, true):
            predicate = #Predicate { entry in
                entry.searchTexts.contains { text in
                    text.localizedStandardContains(searchText)
                }
            }
        case (true, false):
            predicate = #Predicate { entry in
                entry.resourceCategories.contains { category in
                    categories.contains(category)
                }
            }
        case (false, false):
            predicate = #Predicate { entry in
                entry.searchTexts.contains { text in
                    text.localizedStandardContains(searchText)
                }
                    && entry.resourceCategories.contains { category in
                        categories.contains(category)
                    }
            }
        }
        return WebInspectorFetchDescriptor(
            predicate: predicate,
            sortBy: [
                SortDescriptor(\.startedAt, order: .reverse),
                SortDescriptor(\.insertionOrdinal, order: .reverse),
            ]
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
