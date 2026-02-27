import Foundation
import WebInspectorEngine

public struct WISessionFeatureRequirements: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let dom = WISessionFeatureRequirements(rawValue: 1 << 0)
    public static let network = WISessionFeatureRequirements(rawValue: 1 << 1)
}

public struct WISessionTabActivation: Hashable, Sendable {
    public var domLiveUpdates: Bool
    public var networkLiveLogging: Bool

    public init(domLiveUpdates: Bool = false, networkLiveLogging: Bool = false) {
        self.domLiveUpdates = domLiveUpdates
        self.networkLiveLogging = networkLiveLogging
    }
}

public struct WISessionTabDefinition: Hashable, Sendable {
    public var id: String
    public var requires: WISessionFeatureRequirements
    public var activation: WISessionTabActivation

    public init(
        id: String,
        requires: WISessionFeatureRequirements = [],
        activation: WISessionTabActivation = .init()
    ) {
        self.id = id
        self.requires = requires
        self.activation = activation
    }
}

public enum WISessionCommand {
    case selectTab(String?)
    case dom(WIDOMCommand)
    case network(WINetworkCommand)
}

public enum WIDOMCommand {
    case reloadInspector(preserveState: Bool)
    case setSnapshotDepth(Int)
    case toggleSelectionMode
    case cancelSelectionMode
    case copySelection(DOMSelectionCopyKind)
    case deleteSelectedNode(undoManager: UndoManager?)
    case deleteNode(nodeId: Int?, undoManager: UndoManager?)
    case updateAttributeValue(name: String, value: String)
    case removeAttribute(name: String)
}

public enum WINetworkCommand {
    case fetchBody(entry: NetworkEntry, body: NetworkBody, force: Bool)
}
