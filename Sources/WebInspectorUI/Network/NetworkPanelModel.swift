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
private final class NetworkDisplayRowsProjectionCoordinator {
    typealias ApplyAction = @MainActor @Sendable ([NetworkRequest.Display.Projection]) -> Void

    private let projector: NetworkRequest.Display.RowsProjector
    private let synchronousCache: NetworkRequest.Display.ProjectionCache
    private var task: Task<Void, Never>?
    private var generation = 0
    private var lastRequestedInput: NetworkRequest.Display.RowsProjectionInput?

    init(mediaPreviewClassifier: @escaping NetworkRequest.Display.MediaPreviewClassifier) {
        projector = NetworkRequest.Display.RowsProjector(mediaPreviewClassifier: mediaPreviewClassifier)
        synchronousCache = NetworkRequest.Display.ProjectionCache(mediaPreviewClassifier: mediaPreviewClassifier)
    }

    isolated deinit {
        task?.cancel()
    }

    func schedule(
        input: NetworkRequest.Display.RowsProjectionInput,
        apply: @escaping ApplyAction
    ) {
        guard input != lastRequestedInput else {
            return
        }
        lastRequestedInput = input
        cancelPending()
        let generation = generation
        let projector = projector
        task = Task { [input, generation, projector, weak self] in
            do {
                let rows = try await projector.rows(for: input)
                try Task.checkCancellation()
                self?.applyIfCurrent(rows, generation: generation, apply: apply)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func refresh(
        input: NetworkRequest.Display.RowsProjectionInput,
        apply: ApplyAction
    ) async {
        lastRequestedInput = input
        cancelPending()
        let generation = generation
        do {
            let rows = try await projector.rows(for: input)
            try Task.checkCancellation()
            applyIfCurrent(rows, generation: generation, apply: apply)
        } catch is CancellationError {
        } catch {
        }
    }

    func refreshSynchronously(
        input: NetworkRequest.Display.RowsProjectionInput,
        apply: ApplyAction
    ) {
        lastRequestedInput = input
        cancelPending()
        let generation = generation
        do {
            let rows = try synchronousCache.rows(for: input)
            applyIfCurrent(rows, generation: generation, apply: apply)
        } catch is CancellationError {
        } catch {
        }
    }

    func removeAll(apply: ApplyAction) {
        cancelPending()
        lastRequestedInput = nil
        applyIfCurrent([], generation: generation, apply: apply)
        Task { [projector] in
            await projector.removeAll()
        }
        synchronousCache.removeAll()
    }

    func cancel() {
        cancelPending()
    }

    private func cancelPending() {
        generation += 1
        task?.cancel()
        task = nil
    }

    private func applyIfCurrent(
        _ rows: [NetworkRequest.Display.Projection],
        generation: Int,
        apply: ApplyAction
    ) {
        guard generation == self.generation else {
            return
        }
        apply(rows)
        task = nil
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
    package private(set) var displayRows: [NetworkRequest.Display.Projection] = []
    @ObservationIgnored private let responseBodyFetchCoordinator: NetworkResponseBodyFetchCoordinator
    @ObservationIgnored private let displayRowsProjectionCoordinator: NetworkDisplayRowsProjectionCoordinator
    @ObservationIgnored private var displayProjectionByID: [NetworkRequest.ID: NetworkRequest.Display.Projection] = [:]

    package init(
        network: NetworkSession,
        responseBodyFetchAction: ResponseBodyFetchAction? = nil,
        mediaPreviewClassifier: @escaping NetworkRequest.Display.MediaPreviewClassifier = { mimeType, url in
            NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    ) {
        self.network = network
        self.responseBodyFetchCoordinator = NetworkResponseBodyFetchCoordinator(action: responseBodyFetchAction)
        self.displayRowsProjectionCoordinator = NetworkDisplayRowsProjectionCoordinator(
            mediaPreviewClassifier: mediaPreviewClassifier
        )
    }

    isolated deinit {
        displayRowsProjectionCoordinator.cancel()
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
        displayProjectionByID[id]
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
        displayRowsProjectionCoordinator.removeAll { [weak self] rows in
            self?.applyDisplayRows(rows)
        }
    }

    package func fetchResponseBodyIfNeeded(for request: NetworkRequest) {
        responseBodyFetchCoordinator.fetchIfNeeded(for: request)
    }

    package func displayRowsProjectionInput() -> NetworkRequest.Display.RowsProjectionInput {
        NetworkRequest.Display.RowsProjectionInput(
            requestSnapshots: network.requests.map(NetworkRequest.Display.RequestSnapshot.init),
            searchText: searchText,
            resourceFilters: effectiveResourceFilters
        )
    }

    package func scheduleDisplayRowsProjection(
        input: NetworkRequest.Display.RowsProjectionInput? = nil
    ) {
        let input = input ?? displayRowsProjectionInput()
        displayRowsProjectionCoordinator.schedule(input: input) { [weak self] rows in
            self?.applyDisplayRows(rows)
        }
    }

    @discardableResult
    package func refreshDisplayRows() async -> [NetworkRequest.Display.Projection] {
        let input = displayRowsProjectionInput()
        await displayRowsProjectionCoordinator.refresh(input: input) { [weak self] rows in
            self?.applyDisplayRows(rows)
        }
        return displayRows
    }

    @discardableResult
    package func refreshDisplayRowsSynchronously() -> [NetworkRequest.Display.Projection] {
        let input = displayRowsProjectionInput()
        displayRowsProjectionCoordinator.refreshSynchronously(input: input) { [weak self] rows in
            self?.applyDisplayRows(rows)
        }
        return displayRows
    }

    private func applyDisplayRows(_ rows: [NetworkRequest.Display.Projection]) {
        displayRows = rows
        displayProjectionByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }
}
