import Foundation

public typealias DOMContextID = UInt64

public struct DOMContext: Equatable, Sendable {
    public let contextID: DOMContextID
    public let documentURL: String?

    public init(contextID: DOMContextID, documentURL: String? = nil) {
        self.contextID = contextID
        self.documentURL = documentURL
    }
}
