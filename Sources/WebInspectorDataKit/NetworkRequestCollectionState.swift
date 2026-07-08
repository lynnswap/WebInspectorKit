import Observation

@Observable
package final class NetworkRequestCollectionState {
    package private(set) var requestCount: Int
    package private(set) var topologyRevision: Int

    package init(requestCount: Int = 0) {
        self.requestCount = requestCount
        topologyRevision = 0
    }

    package var hasRequests: Bool {
        requestCount > 0
    }

    package func replaceCount(_ count: Int) {
        guard requestCount != count else {
            return
        }
        requestCount = count
        topologyRevision &+= 1
    }

    package func didInsertRequest() {
        requestCount &+= 1
        topologyRevision &+= 1
    }
}
