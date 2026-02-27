import Foundation
import WebInspectorEngine

public struct WISessionState: Sendable, Equatable {
    public var selectedTabID: String?
    public var dom: WIDOMState
    public var network: WINetworkState

    public init(
        selectedTabID: String? = nil,
        dom: WIDOMState = .init(),
        network: WINetworkState = .init()
    ) {
        self.selectedTabID = selectedTabID
        self.dom = dom
        self.network = network
    }
}

public struct WIDOMState: Sendable, Equatable {
    public var hasPageWebView: Bool
    public var isSelectingElement: Bool
    public var selectedNodeID: Int?
    public var snapshotDepth: Int

    public init(
        hasPageWebView: Bool = false,
        isSelectingElement: Bool = false,
        selectedNodeID: Int? = nil,
        snapshotDepth: Int = 4
    ) {
        self.hasPageWebView = hasPageWebView
        self.isSelectingElement = isSelectingElement
        self.selectedNodeID = selectedNodeID
        self.snapshotDepth = snapshotDepth
    }
}

public struct WINetworkState: Sendable, Equatable {
    public var selectedEntryID: UUID?

    public init(
        selectedEntryID: UUID? = nil
    ) {
        self.selectedEntryID = selectedEntryID
    }
}
