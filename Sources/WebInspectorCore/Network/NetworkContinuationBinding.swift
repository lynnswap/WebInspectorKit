import Foundation

package struct NetworkContinuationBinding {
    package let seedKind: NetworkSeedKind?
    package let allowsCrossTargetRebind: Bool
    package let canonicalRequestID: Int
    package var sessionID: String
    package var requestTargetIdentifier: String?
    package var responseTargetIdentifier: String?
    package let rawRequestID: String
    package let url: String
    package let requestType: String?

    package init(
        seedKind: NetworkSeedKind?,
        allowsCrossTargetRebind: Bool,
        canonicalRequestID: Int,
        sessionID: String,
        requestTargetIdentifier: String?,
        responseTargetIdentifier: String?,
        rawRequestID: String,
        url: String,
        requestType: String?
    ) {
        self.seedKind = seedKind
        self.allowsCrossTargetRebind = allowsCrossTargetRebind
        self.canonicalRequestID = canonicalRequestID
        self.sessionID = sessionID
        self.requestTargetIdentifier = requestTargetIdentifier
        self.responseTargetIdentifier = responseTargetIdentifier
        self.rawRequestID = rawRequestID
        self.url = url
        self.requestType = requestType
    }
}
