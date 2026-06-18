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
#if DEBUG
    private let testProbe = NetworkDisplayRowsProjectionTestProbe()
#endif

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
        task = Task.detached { [input, generation, projector, weak self] in
            do {
                let rows = try await projector.rows(for: input)
#if DEBUG
                await self?.suspendApplyIfNeededForTesting(generation: generation)
#endif
                try Task.checkCancellation()
                await self?.applyIfCurrent(rows, generation: generation, apply: apply)
            } catch is CancellationError {
#if DEBUG
                await self?.recordDiscardForTesting(generation: generation)
#endif
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
#if DEBUG
            await suspendApplyIfNeededForTesting(generation: generation)
#endif
            try Task.checkCancellation()
            applyIfCurrent(rows, generation: generation, apply: apply)
        } catch is CancellationError {
#if DEBUG
            recordDiscardForTesting(generation: generation)
#endif
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
#if DEBUG
        testProbe.resumeSuspendedApply()
#endif
    }

    private func applyIfCurrent(
        _ rows: [NetworkRequest.Display.Projection],
        generation: Int,
        apply: ApplyAction
    ) {
        guard generation == self.generation else {
#if DEBUG
            recordDiscardForTesting(generation: generation)
#endif
            return
        }
        apply(rows)
#if DEBUG
        recordApplyForTesting(generation: generation)
#endif
        task = nil
    }

#if DEBUG
    func suspendNextApplyForTesting() {
        testProbe.suspendNextApply()
    }

    func waitForApplySuspensionForTesting() async -> Int {
        await testProbe.waitForApplySuspension()
    }

    func waitForDiscardForTesting(generation: Int) async {
        await testProbe.waitForDiscard(generation: generation)
    }

    func waitForApplyForTesting(after generation: Int) async -> Int {
        await testProbe.waitForApply(after: generation)
    }

    private func suspendApplyIfNeededForTesting(generation: Int) async {
        await testProbe.suspendApplyIfNeeded(generation: generation)
    }

    private func recordDiscardForTesting(generation: Int) {
        testProbe.recordDiscard(generation: generation)
    }

    private func recordApplyForTesting(generation: Int) {
        testProbe.recordApply(generation: generation)
    }
#endif
}

#if DEBUG
@MainActor
private final class NetworkDisplayRowsProjectionTestProbe {
    private var shouldSuspendNextApply = false
    private var suspendedApplyGeneration: Int?
    private var suspendedApplyContinuation: CheckedContinuation<Void, Never>?
    private var applySuspensionWaiters: [CheckedContinuation<Int, Never>] = []
    private var discardedGenerations: Set<Int> = []
    private var discardWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var appliedGenerations: [Int] = []
    private var applyWaiters: [(after: Int, continuation: CheckedContinuation<Int, Never>)] = []

    func suspendNextApply() {
        shouldSuspendNextApply = true
    }

    func waitForApplySuspension() async -> Int {
        if let suspendedApplyGeneration {
            return suspendedApplyGeneration
        }
        return await withCheckedContinuation { continuation in
            applySuspensionWaiters.append(continuation)
        }
    }

    func waitForDiscard(generation: Int) async {
        if discardedGenerations.contains(generation) {
            return
        }
        await withCheckedContinuation { continuation in
            discardWaiters[generation, default: []].append(continuation)
        }
    }

    func waitForApply(after generation: Int) async -> Int {
        if let appliedGeneration = appliedGenerations.first(where: { $0 > generation }) {
            return appliedGeneration
        }
        return await withCheckedContinuation { continuation in
            applyWaiters.append((after: generation, continuation: continuation))
        }
    }

    func suspendApplyIfNeeded(generation: Int) async {
        guard shouldSuspendNextApply else {
            return
        }
        shouldSuspendNextApply = false
        await withCheckedContinuation { continuation in
            suspendedApplyGeneration = generation
            suspendedApplyContinuation = continuation
            let waiters = applySuspensionWaiters
            applySuspensionWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters {
                waiter.resume(returning: generation)
            }
        }
    }

    func resumeSuspendedApply() {
        guard let continuation = suspendedApplyContinuation else {
            return
        }
        suspendedApplyContinuation = nil
        suspendedApplyGeneration = nil
        continuation.resume()
    }

    func recordDiscard(generation: Int) {
        guard discardedGenerations.insert(generation).inserted else {
            return
        }
        let waiters = discardWaiters.removeValue(forKey: generation) ?? []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func recordApply(generation: Int) {
        appliedGenerations.append(generation)
        var unresolvedWaiters: [(after: Int, continuation: CheckedContinuation<Int, Never>)] = []
        for waiter in applyWaiters {
            if generation > waiter.after {
                waiter.continuation.resume(returning: generation)
            } else {
                unresolvedWaiters.append(waiter)
            }
        }
        applyWaiters = unresolvedWaiters
    }
}
#endif

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

#if DEBUG
extension NetworkPanelModel {
    package func suspendNextDisplayRowsProjectionApplyForTesting() {
        displayRowsProjectionCoordinator.suspendNextApplyForTesting()
    }

    package func waitForDisplayRowsProjectionApplySuspensionForTesting() async -> Int {
        await displayRowsProjectionCoordinator.waitForApplySuspensionForTesting()
    }

    package func waitForDisplayRowsProjectionDiscardForTesting(generation: Int) async {
        await displayRowsProjectionCoordinator.waitForDiscardForTesting(generation: generation)
    }

    package func waitForDisplayRowsProjectionApplyForTesting(after generation: Int) async -> Int {
        await displayRowsProjectionCoordinator.waitForApplyForTesting(after: generation)
    }
}
#endif
