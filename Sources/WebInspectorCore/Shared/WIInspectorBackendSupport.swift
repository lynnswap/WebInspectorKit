import Foundation

public enum WIInspectorBackendKind: String, Sendable {
    case nativeInspectorIOS
    case nativeInspectorMacOS
    case privateCore
    case privateFull
    case legacy
    case unsupported
}

public enum WIInspectorBackendCapability: String, Hashable, Sendable {
    case domDomain
    case networkDomain
    case pageTargetRouting
}

public struct WIInspectorBackendSupport: Sendable {
    public enum Availability: String, Sendable {
        case supported
        case unsupported
    }

    public let availability: Availability
    public let backendKind: WIInspectorBackendKind
    public let capabilities: Set<WIInspectorBackendCapability>
    public let failureReason: String?

    public init(
        availability: Availability,
        backendKind: WIInspectorBackendKind,
        capabilities: Set<WIInspectorBackendCapability> = [],
        failureReason: String? = nil
    ) {
        self.availability = availability
        self.backendKind = backendKind
        self.capabilities = capabilities
        self.failureReason = failureReason
    }

    public var isSupported: Bool {
        availability == .supported
    }
}
