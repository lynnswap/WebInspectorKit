import Foundation

public enum WIBackendKind: String, Sendable {
    case nativeInspectorIOS
    case nativeInspectorMacOS
    case privateCore
    case privateFull
    case legacy
    case unsupported
}

public enum WIBackendCapability: String, Hashable, Sendable {
    case domDomain
    case networkDomain
    case pageTargetRouting
}

public struct WIBackendSupport: Sendable {
    public enum Availability: String, Sendable {
        case supported
        case unsupported
    }

    public let availability: Availability
    public let backendKind: WIBackendKind
    public let capabilities: Set<WIBackendCapability>
    public let failureReason: String?

    public init(
        availability: Availability,
        backendKind: WIBackendKind,
        capabilities: Set<WIBackendCapability> = [],
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
