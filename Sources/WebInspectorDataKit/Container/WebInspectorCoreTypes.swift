import Foundation

/// Identifies one semantic model feature owned by a model container.
public struct WebInspectorFeatureID: Hashable, Sendable {
    public let name: String

    package init(name: String) {
        self.name = name
    }

    public static let dom = Self(name: "dom")
    public static let network = Self(name: "network")
    public static let consoleRuntime = Self(name: "consoleRuntime")
}

/// Identifies one physical attachment attempt.
public struct WebInspectorAttachmentGeneration:
    RawRepresentable,
    Hashable,
    Comparable,
    Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (
        lhs: WebInspectorAttachmentGeneration,
        rhs: WebInspectorAttachmentGeneration
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Identifies one inspected-page generation.
public struct WebInspectorPageGeneration:
    RawRepresentable,
    Hashable,
    Comparable,
    Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (
        lhs: WebInspectorPageGeneration,
        rhs: WebInspectorPageGeneration
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Identifies one nonempty canonical-store commit.
public struct WebInspectorStoreRevision:
    RawRepresentable,
    Hashable,
    Comparable,
    Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (
        lhs: WebInspectorStoreRevision,
        rhs: WebInspectorStoreRevision
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// An immutable failure summary safe to publish across actors.
public struct WebInspectorFailureDescription:
    Error,
    Equatable,
    Sendable
{
    public let code: String
    public let phase: String
    public let message: String

    public init(code: String, phase: String, message: String) {
        self.code = code
        self.phase = phase
        self.message = message
    }
}

/// Why one semantic feature is rebuilding its canonical projection.
public enum WebInspectorRecoveryReason: Equatable, Sendable {
    case eventGap(WebInspectorFailureDescription)
    case snapshotConflict(WebInspectorFailureDescription)
    case malformedDomainEvent(WebInspectorFailureDescription)
    case targetChanged
}

/// A failure confined to one semantic feature.
public enum WebInspectorFeatureError: Error, Equatable, Sendable {
    case bootstrap(WebInspectorFailureDescription)
    case eventStream(WebInspectorFailureDescription)
    case command(WebInspectorFailureDescription)
    case recoveryBudgetExhausted(WebInspectorFailureDescription)
}

/// The query-visible readiness of one feature.
public enum WebInspectorFeatureState: Equatable, Sendable {
    case disabled
    case synchronizing(generation: WebInspectorPageGeneration)
    case ready(
        generation: WebInspectorPageGeneration,
        revision: WebInspectorStoreRevision
    )
    case recovering(
        generation: WebInspectorPageGeneration,
        reason: WebInspectorRecoveryReason
    )
    case unavailable(
        generation: WebInspectorPageGeneration,
        error: WebInspectorFeatureError
    )
}

/// Failures that invalidate the physical inspector connection.
public enum WebInspectorConnectionFailure: Error, Equatable, Sendable {
    case native(WebInspectorFailureDescription)
    case transportEnvelope(WebInspectorFailureDescription)
    case targetControlPlane(WebInspectorFailureDescription)
}

/// Failures from attaching one container to a Web view.
public enum WebInspectorAttachmentError: Error, Equatable, Sendable {
    case attachmentInProgress
    case alreadyAttached
    case webViewAlreadyAttached
    case containerClosed
    case native(WebInspectorConnectionFailure)
}

/// Typed failures from generic fetch operations.
public enum WebInspectorFetchError: Error, Equatable, Sendable {
    case invalidLimit(Int)
    case invalidOffset(Int)
    case unsupportedModel(String)
    case featureUnavailable(WebInspectorFeatureID, WebInspectorFeatureError)
    case predicateEvaluation(WebInspectorFailureDescription)
    case contextClosed
    case containerClosed
}

/// Typed failures from context issuance.
public enum WebInspectorModelContextError: Error, Equatable, Sendable {
    case containerClosed
}
