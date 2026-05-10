import Foundation

@available(*, deprecated, message: "The native DOM pipeline no longer emits DOMPageEvent; this type remains for source compatibility.")
public enum DOMPageEvent: Sendable {
    case snapshot(payload: AnySendablePayload, contextID: DOMContextID)
    case mutations(payload: AnySendablePayload, contextID: DOMContextID)
}

@available(*, deprecated, message: "The native DOM pipeline no longer uses untyped sendable payload wrappers; this type remains for source compatibility.")
public struct AnySendablePayload: @unchecked Sendable {
    public let rawValue: Any

    public init(_ rawValue: Any) {
        self.rawValue = rawValue
    }
}
