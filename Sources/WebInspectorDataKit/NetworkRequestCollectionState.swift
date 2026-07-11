import Observation

@Observable
package final class NetworkRequestCollectionState {
    private struct Snapshot {
        let requestCount: Int
        let topologyRevision: UInt64
        let sourceEpoch: UInt64
    }

    private var snapshot: Snapshot

    package init(requestCount: Int = 0) {
        snapshot = Snapshot(
            requestCount: requestCount,
            topologyRevision: 0,
            sourceEpoch: 0
        )
    }

    package var requestCount: Int {
        snapshot.requestCount
    }

    package var topologyRevision: UInt64 {
        snapshot.topologyRevision
    }

    package var sourceEpoch: UInt64 {
        snapshot.sourceEpoch
    }

    package var hasRequests: Bool {
        requestCount > 0
    }

    package func reset(sourceEpoch: UInt64) {
        precondition(
            sourceEpoch > snapshot.sourceEpoch,
            "Network request collection source epochs must advance on reset."
        )
        snapshot = Snapshot(
            requestCount: 0,
            topologyRevision: nextTopologyRevision(),
            sourceEpoch: sourceEpoch
        )
    }

    package func didInsertRequest() {
        precondition(
            snapshot.requestCount < Int.max,
            "Network request collection count overflowed."
        )
        snapshot = Snapshot(
            requestCount: snapshot.requestCount + 1,
            topologyRevision: nextTopologyRevision(),
            sourceEpoch: snapshot.sourceEpoch
        )
    }

    package func didChangeRequestGroupTopology() {
        snapshot = Snapshot(
            requestCount: snapshot.requestCount,
            topologyRevision: nextTopologyRevision(),
            sourceEpoch: snapshot.sourceEpoch
        )
    }

    private func nextTopologyRevision() -> UInt64 {
        precondition(
            snapshot.topologyRevision < UInt64.max,
            "Network request collection topology revision overflowed."
        )
        return snapshot.topologyRevision + 1
    }
}
