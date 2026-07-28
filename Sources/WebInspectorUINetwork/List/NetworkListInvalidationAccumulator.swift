#if canImport(UIKit)
package struct NetworkListFrameRequest: Sendable {}

package actor NetworkListInvalidationAccumulator {
    package nonisolated let frameRequests: AsyncStream<NetworkListFrameRequest>

    private let frameRequestContinuation: AsyncStream<NetworkListFrameRequest>.Continuation
    private var latestVersion: NetworkPanelListVersion?
    private var lastCapturedRevision: UInt64 = 0
    private var frameRequestOutstanding = false
#if DEBUG
    private var frameRequestPublicationCount = 0
#endif

    package init() {
        let pair = AsyncStream<NetworkListFrameRequest>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        frameRequests = pair.stream
        frameRequestContinuation = pair.continuation
    }

    package func consume(
        _ invalidations: AsyncStream<NetworkPanelListInvalidation>
    ) async {
        for await invalidation in invalidations {
            receive(invalidation)
        }
    }

    package func didCapture(_ version: NetworkPanelListVersion) {
        lastCapturedRevision = max(lastCapturedRevision, version.revision)
        frameRequestOutstanding = false
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
              frameRequestOutstanding == false else {
            return
        }
        frameRequestOutstanding = true
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
    package struct StateForTesting: Equatable, Sendable {
        package let latestVersion: NetworkPanelListVersion?
        package let lastCapturedRevision: UInt64
        package let frameRequestOutstanding: Bool
        package let frameRequestPublicationCount: Int
    }

    package func receiveForTesting(_ invalidation: NetworkPanelListInvalidation) {
        receive(invalidation)
    }

    package var stateForTesting: StateForTesting {
        StateForTesting(
            latestVersion: latestVersion,
            lastCapturedRevision: lastCapturedRevision,
            frameRequestOutstanding: frameRequestOutstanding,
            frameRequestPublicationCount: frameRequestPublicationCount
        )
    }
}
#endif
#endif
