import Foundation
import WebInspectorEngine

public enum WITransportTargetScope: String, Sendable {
    case root
    case page
}

package enum WITransportBackendKind: String, Sendable {
    case iOSNativeInspector
    case macOSNativeInspector
    case unsupported
}

public enum WITransportCapability: String, Hashable, Sendable {
    case rootMessaging
    case pageMessaging
    case pageTargetRouting
    case domDomain
    case networkDomain
    case networkBootstrapSnapshot
}

public struct WIEmptyTransportParameters: Codable, Hashable, Sendable {
    public init() {}
}

public struct WIEmptyTransportResponse: Codable, Hashable, Sendable {
    public init() {}
}

public struct WITransportSupportSnapshot: Sendable {
    public enum Availability: String, Sendable {
        case supported
        case unsupported
    }

    public let availability: Availability
    package let backendKind: WITransportBackendKind
    public let capabilities: Set<WITransportCapability>
    public let failureReason: String?

    private init(
        availability: Availability,
        backendKind: WITransportBackendKind,
        capabilities: Set<WITransportCapability> = [],
        failureReason: String?
    ) {
        self.availability = availability
        self.backendKind = backendKind
        self.capabilities = capabilities
        self.failureReason = failureReason
    }

    package static func supported(
        backendKind: WITransportBackendKind,
        capabilities: Set<WITransportCapability> = [],
        failureReason: String? = nil
    ) -> Self {
        precondition(backendKind != .unsupported, "Use unsupported(reason:) for unsupported transport snapshots.")
        return Self(
            availability: .supported,
            backendKind: backendKind,
            capabilities: capabilities,
            failureReason: failureReason
        )
    }

    package static func unsupported(reason: String) -> Self {
        Self(
            availability: .unsupported,
            backendKind: .unsupported,
            capabilities: [],
            failureReason: reason
        )
    }

    public var isSupported: Bool {
        availability == .supported
    }

    package var backendSupport: WIBackendSupport {
        let resolvedBackendKind: WIBackendKind
        switch backendKind {
        case .iOSNativeInspector:
            resolvedBackendKind = .nativeInspectorIOS
        case .macOSNativeInspector:
            resolvedBackendKind = .nativeInspectorMacOS
        case .unsupported:
            resolvedBackendKind = .unsupported
        }

        let mappedCapabilities = Set(
            capabilities.compactMap { capability in
                WIBackendCapability(rawValue: capability.rawValue)
            }
        )

        return WIBackendSupport(
            availability: availability == .supported ? .supported : .unsupported,
            backendKind: resolvedBackendKind,
            capabilities: mappedCapabilities,
            failureReason: failureReason
        )
    }
}

public typealias WITransportLogHandler = @Sendable (String) -> Void

public struct WITransportConfiguration: Sendable {
    public var responseTimeout: Duration
    public var eventBufferLimit: Int
    public var dropEventsWithoutSubscribers: Bool
    public var logHandler: WITransportLogHandler?

    public init(
        responseTimeout: Duration = .seconds(15),
        eventBufferLimit: Int = 128,
        dropEventsWithoutSubscribers: Bool = true,
        logHandler: WITransportLogHandler? = nil
    ) {
        self.responseTimeout = responseTimeout
        self.eventBufferLimit = max(1, eventBufferLimit)
        self.dropEventsWithoutSubscribers = dropEventsWithoutSubscribers
        self.logHandler = logHandler
    }
}

public enum WITransportError: Error, LocalizedError, Sendable {
    case unsupported(String)
    case alreadyAttached
    case notAttached
    case attachFailed(String)
    case pageTargetUnavailable
    case remoteError(scope: WITransportTargetScope, method: String, message: String)
    case requestTimedOut(scope: WITransportTargetScope, method: String)
    case invalidResponse(String)
    case invalidCommandEncoding(String)
    case invalidChannelScope(expected: WITransportTargetScope, actual: WITransportTargetScope)
    case transportClosed

    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason):
            "WebInspectorTransport is unsupported: \(reason)"
        case .alreadyAttached:
            "The inspector session is already attached."
        case .notAttached:
            "The inspector session is not attached."
        case .attachFailed(let reason):
            "Failed to attach the inspector transport: \(reason)"
        case .pageTargetUnavailable:
            "The page target is unavailable."
        case .remoteError(_, let method, let message):
            "\(method) failed: \(message)"
        case .requestTimedOut(_, let method):
            "\(method) timed out."
        case .invalidResponse(let reason):
            "The inspector response was invalid: \(reason)"
        case .invalidCommandEncoding(let reason):
            "Failed to encode the inspector command: \(reason)"
        case .invalidChannelScope(let expected, let actual):
            "The \(actual.rawValue) channel cannot send a command that requires the \(expected.rawValue) scope."
        case .transportClosed:
            "The inspector transport is closed."
        }
    }
}

public protocol WITransportCommand {
    associatedtype Response: Decodable & Sendable
    associatedtype Parameters: Encodable & Sendable = WIEmptyTransportParameters

    static var method: String { get }
    var parameters: Parameters { get }
}

public protocol WITransportRootCommand: WITransportCommand {}

public protocol WITransportPageCommand: WITransportCommand {}

public struct WITransportEventEnvelope: Sendable {
    public let method: String
    public let targetScope: WITransportTargetScope
    public let targetIdentifier: String?
    public let paramsData: Data

    public init(method: String, targetScope: WITransportTargetScope, targetIdentifier: String?, paramsData: Data) {
        self.method = method
        self.targetScope = targetScope
        self.targetIdentifier = targetIdentifier
        self.paramsData = paramsData
    }

    public func decodeParams<T: Decodable>(
        _ type: T.Type,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        try decoder.decode(T.self, from: paramsData)
    }
}

package struct WITransportPageTargetChange: Sendable {
    let targetIdentifier: String?
    let reason: String
}

package enum WITransportPageTargetLifecycleKind: Sendable, Equatable {
    case created
    case committedProvisional
    case destroyed
}

package struct WITransportPageTargetLifecycleEvent: Sendable, Equatable {
    let kind: WITransportPageTargetLifecycleKind
    let targetIdentifier: String
    let oldTargetIdentifier: String?
    let targetType: String
    let isProvisional: Bool
}
