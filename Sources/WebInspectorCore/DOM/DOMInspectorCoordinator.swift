import Foundation

@MainActor
package struct DOMReloadRequest: Equatable {
    package let preserveState: Bool
    package let minimumDepth: Int?
    package let requestedDepth: Int

    package init(
        preserveState: Bool,
        minimumDepth: Int?,
        requestedDepth: Int
    ) {
        self.preserveState = preserveState
        self.minimumDepth = minimumDepth
        self.requestedDepth = requestedDepth
    }
}

@MainActor
package final class DOMInspectorCoordinator {
    private var backgroundReloadTask: Task<Void, Never>?
    private var backgroundReloadRequest: DOMReloadRequest?
    private var queuedBackgroundReloadRequest: DOMReloadRequest?

    package init() {}

    package func scheduleReload(
        _ request: DOMReloadRequest,
        performReload: @escaping @MainActor (DOMReloadRequest) async -> Void
    ) {
        if backgroundReloadRequest == request || queuedBackgroundReloadRequest == request {
            return
        }

        guard backgroundReloadTask != nil else {
            startBackgroundReloadTask(for: request, performReload: performReload)
            return
        }

        queuedBackgroundReloadRequest = request
    }

    package func awaitReload(
        _ request: DOMReloadRequest,
        performReload: @escaping @MainActor (DOMReloadRequest) async -> Void
    ) async {
        if backgroundReloadRequest == request || queuedBackgroundReloadRequest == request {
            if let backgroundReloadTask {
                await backgroundReloadTask.value
            }
            return
        }

        if let backgroundReloadTask {
            await backgroundReloadTask.value
        }

        guard !Task.isCancelled else {
            return
        }

        await performReload(request)
    }

    package func cancelReloads() {
        backgroundReloadTask?.cancel()
        backgroundReloadTask = nil
        backgroundReloadRequest = nil
        queuedBackgroundReloadRequest = nil
    }
}

private extension DOMInspectorCoordinator {
    func startBackgroundReloadTask(
        for request: DOMReloadRequest,
        performReload: @escaping @MainActor (DOMReloadRequest) async -> Void
    ) {
        backgroundReloadRequest = request
        backgroundReloadTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.runBackgroundReloadLoop(
                startingWith: request,
                performReload: performReload
            )
        }
    }

    func runBackgroundReloadLoop(
        startingWith initialRequest: DOMReloadRequest,
        performReload: @escaping @MainActor (DOMReloadRequest) async -> Void
    ) async {
        var nextRequest: DOMReloadRequest? = initialRequest

        while let request = nextRequest {
            backgroundReloadRequest = request
            await performReload(request)

            guard !Task.isCancelled else {
                break
            }

            nextRequest = queuedBackgroundReloadRequest
            queuedBackgroundReloadRequest = nil
        }

        backgroundReloadTask = nil
        backgroundReloadRequest = nil
        queuedBackgroundReloadRequest = nil
    }
}
