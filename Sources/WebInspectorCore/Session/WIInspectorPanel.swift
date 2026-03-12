import Foundation

public enum WIInspectorPanelKind: Hashable, Sendable {
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

public struct WIInspectorPanelConfiguration: Hashable, Sendable {
    public enum Role: Hashable, Sendable {
        case inspector
        case other
    }

    public let instanceID: UUID
    public let kind: WIInspectorPanelKind
    public let role: Role

    public init(
        kind: WIInspectorPanelKind,
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
