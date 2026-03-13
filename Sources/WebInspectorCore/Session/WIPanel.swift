import Foundation

public enum WIPanelKind: Hashable, Sendable {
    case domTree
    case domDetail
    case network
    case custom(String)

    public var identifier: String {
        switch self {
        case .domTree:
            "wi_dom"
        case .domDetail:
            "wi_element"
        case .network:
            "wi_network"
        case .custom(let identifier):
            identifier
        }
    }
}

public struct WIPanelConfiguration: Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        case builtIn
        case other
    }

    public let instanceID: UUID
    public let kind: WIPanelKind
    public let role: Role

    public init(
        kind: WIPanelKind,
        role: Role = .other,
        instanceID: UUID = UUID()
    ) {
        self.instanceID = instanceID
        self.kind = kind
        self.role = role
    }

    public var identifier: String {
        kind.identifier
    }
}
