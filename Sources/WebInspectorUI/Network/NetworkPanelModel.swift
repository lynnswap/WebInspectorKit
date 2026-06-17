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
    package private(set) var displayRows: [NetworkRequest.Display.Projection] = []
    @ObservationIgnored private let responseBodyFetchCoordinator: NetworkResponseBodyFetchCoordinator
    @ObservationIgnored private let displayRowsProjector: NetworkRequest.Display.RowsProjector
    @ObservationIgnored private let synchronousDisplayProjectionCache: NetworkRequest.Display.ProjectionCache
    @ObservationIgnored private var displayProjectionByID: [NetworkRequest.ID: NetworkRequest.Display.Projection] = [:]
    @ObservationIgnored private var displayRowsProjectionTask: Task<Void, Never>?
    @ObservationIgnored private var displayRowsProjectionGeneration = 0
    @ObservationIgnored private var lastRequestedRowsProjectionInput: NetworkRequest.Display.RowsProjectionInput?

    package init(
        network: NetworkSession,
        responseBodyFetchAction: ResponseBodyFetchAction? = nil,
        mediaPreviewClassifier: @escaping NetworkRequest.Display.MediaPreviewClassifier = { mimeType, url in
            NetworkRequest.Display.MediaPreviewSupport.classification(mimeType: mimeType, url: url)
        }
    ) {
        self.network = network
        self.responseBodyFetchCoordinator = NetworkResponseBodyFetchCoordinator(action: responseBodyFetchAction)
        self.displayRowsProjector = NetworkRequest.Display.RowsProjector(mediaPreviewClassifier: mediaPreviewClassifier)
        self.synchronousDisplayProjectionCache = NetworkRequest.Display.ProjectionCache(mediaPreviewClassifier: mediaPreviewClassifier)
    }

    isolated deinit {
        displayRowsProjectionTask?.cancel()
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
        cancelPendingDisplayRowsProjection()
        applyDisplayRows([], generation: displayRowsProjectionGeneration)
        lastRequestedRowsProjectionInput = nil
        Task { [displayRowsProjector] in
            await displayRowsProjector.removeAll()
        }
        synchronousDisplayProjectionCache.removeAll()
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
        guard input != lastRequestedRowsProjectionInput else {
            return
        }
        lastRequestedRowsProjectionInput = input
        cancelPendingDisplayRowsProjection()
        let generation = displayRowsProjectionGeneration
        let projector = displayRowsProjector
        displayRowsProjectionTask = Task { [input, generation, projector, weak self] in
            do {
                let rows = try await projector.rows(for: input)
                try Task.checkCancellation()
                await MainActor.run {
                    self?.applyDisplayRows(rows, generation: generation)
                }
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    @discardableResult
    package func refreshDisplayRows() async -> [NetworkRequest.Display.Projection] {
        let input = displayRowsProjectionInput()
        lastRequestedRowsProjectionInput = input
        cancelPendingDisplayRowsProjection()
        let generation = displayRowsProjectionGeneration
        do {
            let rows = try await displayRowsProjector.rows(for: input)
            try Task.checkCancellation()
            applyDisplayRows(rows, generation: generation)
        } catch is CancellationError {
        } catch {
        }
        return displayRows
    }

    @discardableResult
    package func refreshDisplayRowsSynchronously() -> [NetworkRequest.Display.Projection] {
        let input = displayRowsProjectionInput()
        lastRequestedRowsProjectionInput = input
        cancelPendingDisplayRowsProjection()
        let generation = displayRowsProjectionGeneration
        do {
            let rows = try synchronousDisplayProjectionCache.rows(for: input)
            applyDisplayRows(rows, generation: generation)
        } catch is CancellationError {
        } catch {
        }
        return displayRows
    }

    private func cancelPendingDisplayRowsProjection() {
        displayRowsProjectionGeneration += 1
        displayRowsProjectionTask?.cancel()
        displayRowsProjectionTask = nil
    }

    private func applyDisplayRows(
        _ rows: [NetworkRequest.Display.Projection],
        generation: Int
    ) {
        guard generation == displayRowsProjectionGeneration else {
            return
        }
        displayRows = rows
        displayProjectionByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        displayRowsProjectionTask = nil
    }
}
