import Foundation
import Observation
import ObservationBridge
import OSLog
import WebInspectorDataKit
import WebInspectorUIBase

private let networkPanelLogger = Logger(
    subsystem: "com.lynnswap.WebInspectorKit",
    category: "NetworkPanel"
)

package enum NetworkRoute: Equatable {
    case list
    case detail(NetworkEntry.ID)
}

@MainActor
private final class NetworkResponseBodyFetchCoordinator {
    private struct Fetch {
        let operationID: UUID
        let body: NetworkBody
        let revision: NetworkBody.ResponseFetchRevision
        let task: Task<Void, Never>
    }

    private let network: WebInspectorNetwork
    private var fetchesInFlight: [NetworkRequest.ID: Fetch] = [:]
    private var isActive = true

    init(network: WebInspectorNetwork) {
        self.network = network
    }

    func fetchIfNeeded(for request: NetworkRequest) {
        guard isActive,
              request.canFetchResponseBody else {
            return
        }
        let requestID = request.id
        let body = request.responseBody
        if let superseded = fetchesInFlight.removeValue(forKey: requestID) {
            superseded.task.cancel()
            superseded.body.cancelResponseFetch(for: superseded.revision)
        }
        guard let revision = body.beginResponseFetch() else { return }
        let operationID = UUID()
        let task = Task { @MainActor [weak self, network, body] in
            defer {
                self?.finish(requestID: requestID, operationID: operationID)
            }
            do {
                let response = try await network.responseBody(for: requestID)
                guard let self,
                      self.isCurrent(requestID: requestID, operationID: operationID)
                else { return }
                guard Task.isCancelled == false else {
                    body.cancelResponseFetch(for: revision)
                    return
                }
                _ = body.finishResponseFetch(response, for: revision)
            } catch {
                guard let self,
                      self.isCurrent(requestID: requestID, operationID: operationID)
                else { return }
                if Task.isCancelled {
                    body.cancelResponseFetch(for: revision)
                    return
                }
                let commandError = webInspectorCommandError(
                    error,
                    featureID: .network,
                    phase: "Network.responseBody"
                )
                _ = body.failResponseFetch(commandError, for: revision)
                networkPanelLogger.error(
                    "Response body request failed id=\(String(describing: requestID), privacy: .public) error=\(String(describing: commandError), privacy: .public)"
                )
            }
        }
        fetchesInFlight[requestID] = Fetch(
            operationID: operationID,
            body: body,
            revision: revision,
            task: task
        )
    }

    func close() async {
        guard isActive else { return }
        isActive = false
        let fetches = Array(fetchesInFlight.values)
        fetchesInFlight.removeAll(keepingCapacity: false)
        for fetch in fetches {
            fetch.body.cancelResponseFetch(for: fetch.revision)
            fetch.task.cancel()
        }
        for fetch in fetches {
            await fetch.task.value
        }
    }

    func synchronouslyCancel() {
        guard isActive else { return }
        isActive = false
        let fetches = Array(fetchesInFlight.values)
        fetchesInFlight.removeAll(keepingCapacity: false)
        for fetch in fetches {
            fetch.body.cancelResponseFetch(for: fetch.revision)
            fetch.task.cancel()
        }
    }

    private func isCurrent(
        requestID: NetworkRequest.ID,
        operationID: UUID
    ) -> Bool {
        isActive && fetchesInFlight[requestID]?.operationID == operationID
    }

    private func finish(
        requestID: NetworkRequest.ID,
        operationID: UUID
    ) {
        guard fetchesInFlight[requestID]?.operationID == operationID else {
            return
        }
        fetchesInFlight[requestID] = nil
    }
}

@MainActor
@Observable
package final class NetworkPanelModel {
    private struct QueryCriteria: Equatable {
        var searchText: String
        var resourceCategories: Set<NetworkRequest.ResourceCategory>
    }

    package let context: WebInspectorModelContext
    package let entries: WebInspectorFetchedResultsController<NetworkEntry>
    package private(set) var route: NetworkRoute = .list
    package private(set) var searchText = ""
    package private(set) var activeResourceFilters:
        Set<NetworkDisplay.ResourceFilter> = []
    package private(set) var queryError: (any Error)?
    package private(set) var commandError: (any Error)?

    @ObservationIgnored private let responseBodyFetchCoordinator:
        NetworkResponseBodyFetchCoordinator
    @ObservationIgnored private var routeObservation:
        PortableObservationTracking.Token?
    @ObservationIgnored private var queryUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var queryGeneration: UInt64 = 0
    @ObservationIgnored private var committedCriteria = QueryCriteria(
        searchText: "",
        resourceCategories: []
    )
    @ObservationIgnored private var retirementTask: Task<Void, Never>?
    @ObservationIgnored private var isActive = true

    private init(
        context: WebInspectorModelContext,
        entries: WebInspectorFetchedResultsController<NetworkEntry>
    ) {
        self.context = context
        self.entries = entries
        self.responseBodyFetchCoordinator = NetworkResponseBodyFetchCoordinator(
            network: context.container.network
        )
    }

    package static func make(
        context: WebInspectorModelContext
    ) async throws -> NetworkPanelModel {
        let entries = WebInspectorFetchedResultsController<NetworkEntry>(
            fetchDescriptor: makeFetchDescriptor(
                for: QueryCriteria(searchText: "", resourceCategories: [])
            ),
            modelContext: context
        )
        do {
            try await entries.performFetch()
        } catch {
            await entries.close()
            throw error
        }

        let model = NetworkPanelModel(
            context: context,
            entries: entries
        )
        model.startRouteObservation()
        return model
    }

    isolated deinit {
        responseBodyFetchCoordinator.synchronouslyCancel()
        routeObservation?.cancel()
        queryUpdateTask?.cancel()
        retirementTask?.cancel()
        entries.synchronouslyInvalidateRegistration()
    }

    package var selectedEntryID: NetworkEntry.ID? {
        guard case let .detail(id) = route,
              let entry = context.model(for: id),
              entry.isInvalidated == false else {
            return nil
        }
        return id
    }

    package var hasAvailableSelection: Bool { selectedEntryID != nil }
    package var isEmpty: Bool { entries.snapshot?.itemIDs.isEmpty ?? true }
    package var effectiveResourceFilters:
        Set<NetworkDisplay.ResourceFilter> {
        NetworkDisplay.ResourceFilter.normalizedSelection(activeResourceFilters)
    }

    package var selectedEntry: NetworkEntry? {
        selectedEntryID.flatMap { context.model(for: $0) }
    }

    package var selectedRequest: NetworkRequest? { selectedRequests.first }

    package var selectedRequests: [NetworkRequest] {
        guard let entry = selectedEntry else { return [] }
        let requests: [NetworkRequest] = entry.requestIDs.compactMap {
            context.model(for: $0)
        }
        if requests.count != entry.requestIDs.count {
            networkPanelLogger.fault(
                "Current NetworkEntry contains unresolved member IDs entry=\(String(describing: entry.id), privacy: .public)"
            )
        }
        return requests
    }

    package func selectEntry(_ id: NetworkEntry.ID?) {
        guard isActive else { return }
        guard let id,
              itemIDs.contains(id),
              let entry = context.model(for: id),
              entry.isInvalidated == false else {
            route = .list
            return
        }
        route = .detail(id)
    }

    package func showList() {
        guard isActive, route != .list else { return }
        route = .list
    }

    package func showDetail(_ id: NetworkEntry.ID) {
        selectEntry(id)
    }

    package func selectRequest(_ request: NetworkRequest?) {
        guard isActive else { return }
        guard let request else {
            showList()
            return
        }
        let entryID = itemIDs.first { entryID in
            context.model(for: entryID)?.requestIDs.contains(request.id) == true
        }
        selectEntry(entryID)
    }

    package func setSearchText(_ text: String) {
        guard isActive, searchText != text else { return }
        searchText = text
        scheduleQueryUpdate()
    }

    package func setResourceFilter(
        _ filter: NetworkDisplay.ResourceFilter,
        enabled: Bool
    ) {
        guard isActive else { return }
        var nextFilters = activeResourceFilters
        if enabled {
            nextFilters.insert(filter)
        } else {
            nextFilters.remove(filter)
        }
        nextFilters = NetworkDisplay.ResourceFilter.normalizedSelection(nextFilters)
        guard nextFilters != activeResourceFilters else { return }
        activeResourceFilters = nextFilters
        scheduleQueryUpdate()
    }

    package func clearResourceFilters() {
        guard isActive, activeResourceFilters.isEmpty == false else { return }
        activeResourceFilters = []
        scheduleQueryUpdate()
    }

    package func clearRequests() {
        guard isActive else { return }
        showList()
        let network = context.container.network
        Task { @MainActor [weak self, network] in
            do {
                try await network.clear()
                self?.commandError = nil
            } catch {
                self?.commandError = error
                networkPanelLogger.error(
                    "Network clear failed error=\(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    package func fetchResponseBodyIfNeeded(for request: NetworkRequest) {
        guard isActive else { return }
        responseBodyFetchCoordinator.fetchIfNeeded(for: request)
    }

    package func retire() async {
        if let retirementTask {
            await retirementTask.value
            return
        }
        guard isActive else { return }
        isActive = false
        routeObservation?.cancel()
        routeObservation = nil
        let queryTask = queryUpdateTask
        queryUpdateTask = nil
        queryTask?.cancel()
        let entries = entries
        let responseBodyFetchCoordinator = responseBodyFetchCoordinator
        let task = Task { @MainActor in
            await responseBodyFetchCoordinator.close()
            await queryTask?.value
            await entries.close()
        }
        retirementTask = task
        await task.value
        retirementTask = nil
    }

    package func synchronouslyCancelForOwnerDeinit() {
        isActive = false
        responseBodyFetchCoordinator.synchronouslyCancel()
        routeObservation?.cancel()
        routeObservation = nil
        queryUpdateTask?.cancel()
        queryUpdateTask = nil
        retirementTask?.cancel()
        entries.synchronouslyInvalidateRegistration()
    }

    package func waitForQueryUpdates() async {
        while true {
            let generation = queryGeneration
            let task = queryUpdateTask
            await task?.value
            if generation == queryGeneration { return }
        }
    }

    private func startRouteObservation() {
        routeObservation = withPortableContinuousObservation { [weak self] _ in
            self?.reconcileRoute()
        }
    }

    private func reconcileRoute() {
        guard case let .detail(id) = route,
              let entry = context.model(for: id),
              entry.isInvalidated == false else {
            if case .detail = route { route = .list }
            return
        }
    }

    private func scheduleQueryUpdate() {
        let criteria = QueryCriteria(
            searchText: Self.normalizedSearchText(searchText),
            resourceCategories: NetworkRequest.ResourceCategory.networkCategories(
                for: effectiveResourceFilters
            )
        )
        guard committedCriteria != criteria else { return }

        queryGeneration &+= 1
        let generation = queryGeneration
        let previousTask = queryUpdateTask
        previousTask?.cancel()
        let entries = entries
        let descriptor = Self.makeFetchDescriptor(for: criteria)
        queryUpdateTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard Task.isCancelled == false,
                  self?.isCurrentQuery(generation) == true else { return }
            do {
                try await entries.refetch(using: descriptor)
            } catch is CancellationError {
                return
            } catch {
                guard let self, isCurrentQuery(generation) else { return }
                queryError = error
                return
            }
            guard let self, isCurrentQuery(generation) else { return }
            committedCriteria = criteria
            queryError = nil
            queryUpdateTask = nil
        }
    }

    private func isCurrentQuery(_ generation: UInt64) -> Bool {
        isActive && queryGeneration == generation
    }

    private var itemIDs: [NetworkEntry.ID] {
        entries.snapshot?.itemIDs ?? []
    }

    #if DEBUG
    package var isRetiredForTesting: Bool { isActive == false }
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
                entry.searchableText.localizedStandardContains(searchText)
            }
        case (true, false):
            predicate = #Predicate { entry in
                entry.resourceCategories.contains { categories.contains($0) }
            }
        case (false, false):
            predicate = #Predicate { entry in
                entry.searchableText.localizedStandardContains(searchText)
                    && entry.resourceCategories.contains {
                    categories.contains($0)
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
        for filter in NetworkDisplay.ResourceFilter.pickerCases
        where filters.contains(filter) {
            categories.formUnion(filter.networkResourceCategories)
        }
        return categories
    }
}

private extension NetworkDisplay.ResourceFilter {
    var networkResourceCategories: [NetworkRequest.ResourceCategory] {
        switch self {
        case .all: []
        case .document: [.document]
        case .stylesheet: [.stylesheet]
        case .media: [.image, .media]
        case .font: [.font]
        case .script: [.script]
        case .xhrFetch: [.xhrFetch]
        case .other: [.webSocket, .other]
        }
    }
}
