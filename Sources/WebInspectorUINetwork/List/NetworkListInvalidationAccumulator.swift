#if canImport(UIKit)
struct NetworkListFrameRequest: Sendable {}

actor NetworkListInvalidationAccumulator {
    nonisolated let frameRequests: AsyncStream<NetworkListFrameRequest>

    private let frameRequestContinuation: AsyncStream<NetworkListFrameRequest>.Continuation
    private var latestVersion: NetworkPanelListVersion?
    private var lastCapturedRevision: UInt64 = 0
    private var outstandingRevision: UInt64?
#if DEBUG
    private var frameRequestPublicationCount = 0
#endif

    init() {
        let pair = AsyncStream<NetworkListFrameRequest>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        frameRequests = pair.stream
        frameRequestContinuation = pair.continuation
    }

    func consume(
        _ invalidations: AsyncStream<NetworkPanelListInvalidation>
    ) async {
        for await invalidation in invalidations {
            receive(invalidation)
        }
    }

    func didCapture(_ version: NetworkPanelListVersion) {
        lastCapturedRevision = max(lastCapturedRevision, version.revision)
        if let outstandingRevision,
           version.revision >= outstandingRevision {
            self.outstandingRevision = nil
        }
        requestFrameIfNeeded()
    }

    private func receive(_ invalidation: NetworkPanelListInvalidation) {
        if let latestVersion {
            precondition(
                invalidation.version.revision > latestVersion.revision,
                "Network list invalidations must advance monotonically."
            )
        }
        latestVersion = invalidation.version
        requestFrameIfNeeded()
    }

    private func requestFrameIfNeeded() {
        guard let latestVersion,
              latestVersion.revision > lastCapturedRevision,
              outstandingRevision == nil else {
            return
        }
        outstandingRevision = latestVersion.revision
#if DEBUG
        frameRequestPublicationCount += 1
#endif
        frameRequestContinuation.yield(NetworkListFrameRequest())
    }

    deinit {
        frameRequestContinuation.finish()
    }
}

#if DEBUG
extension NetworkListInvalidationAccumulator {
    struct StateForTesting: Equatable, Sendable {
        let latestVersion: NetworkPanelListVersion?
        let lastCapturedRevision: UInt64
        let outstandingRevision: UInt64?
        let frameRequestPublicationCount: Int
    }

    func receiveForTesting(_ invalidation: NetworkPanelListInvalidation) {
        receive(invalidation)
    }

    var stateForTesting: StateForTesting {
        StateForTesting(
            latestVersion: latestVersion,
            lastCapturedRevision: lastCapturedRevision,
            outstandingRevision: outstandingRevision,
            frameRequestPublicationCount: frameRequestPublicationCount
        )
    }
}
#endif
#endif
