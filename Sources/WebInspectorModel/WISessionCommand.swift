import Foundation
import WebInspectorEngine

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    case event(WIDomainEvent)
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
    case setSearchText(String)
    case selectEntry(id: UUID?)
    case setResourceFilter(NetworkResourceFilter, isEnabled: Bool)
    case clear
    case fetchBody(entry: NetworkEntry, body: NetworkBody, force: Bool)
}

public enum WIDomainEvent {
    case dom(WIDOMEvent)
    case network(WINetworkEvent)
}

public enum WIDOMEvent {
    case pageWebViewAvailabilityChanged(Bool)
    case selectingElementChanged(Bool)
    case selectionNodeChanged(Int?)
    case snapshotDepthChanged(Int)
}

public enum WINetworkEvent {
    case selectedEntryChanged(UUID?)
    case searchTextChanged(String)
    case activeFiltersChanged(Set<NetworkResourceFilter>)
    case effectiveFiltersChanged(Set<NetworkResourceFilter>)
}
