import Foundation

public enum DOMPageEvent: Sendable {
    case snapshot(payload: AnySendablePayload, contextID: DOMContextID)
    case mutations(payload: AnySendablePayload, contextID: DOMContextID)
}

public struct AnySendablePayload: @unchecked Sendable {
    public let rawValue: Any

    public init(_ rawValue: Any) {
        self.rawValue = rawValue
    }
}
