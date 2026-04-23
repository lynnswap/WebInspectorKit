import Foundation

public enum DOMOperationError: Error, Equatable, Sendable {
    case pageUnavailable
    case contextInvalidated
    case invalidSelection
    case scriptFailure(String?)
}
