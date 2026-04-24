#if canImport(UIKit)
import Foundation
import Observation
import WebInspectorEngine
import WebInspectorRuntime

@MainActor
@Observable
public final class V2_WIInspectorSession {
    public let runtime: V2_WIRuntimeSession
    public let interface: V2_WIInterfaceModel

    public init(
        runtime: V2_WIRuntimeSession = V2_WIRuntimeSession(),
        interface: V2_WIInterfaceModel = V2_WIInterfaceModel()
    ) {
        self.runtime = runtime
        self.interface = interface
    }
}

@MainActor
@Observable
public final class V2_WIInterfaceModel {
    var providedTabs: Set<V2_ProvidedWITab>
    var customTabs: [V2_WITab]
    public let dom: V2_WIDOMInterfaceModel
    public let network: V2_WINetworkInterfaceModel

    public init(
        dom: V2_WIDOMInterfaceModel = V2_WIDOMInterfaceModel(),
        network: V2_WINetworkInterfaceModel = V2_WINetworkInterfaceModel()
    ) {
        self.providedTabs = V2_ProvidedWITab.defaults
        self.customTabs = []
        self.dom = dom
        self.network = network
    }
}

@MainActor
@Observable
public final class V2_WIDOMInterfaceModel {
    public var selectedNodeID: DOMNodeModel.ID?
    public var expandedNodeIDs: Set<DOMNodeModel.ID>
    public let editing: V2_WIDOMEditingModel

    public init(
        selectedNodeID: DOMNodeModel.ID? = nil,
        expandedNodeIDs: Set<DOMNodeModel.ID> = [],
        editing: V2_WIDOMEditingModel = V2_WIDOMEditingModel()
    ) {
        self.selectedNodeID = selectedNodeID
        self.expandedNodeIDs = expandedNodeIDs
        self.editing = editing
    }
}

@MainActor
@Observable
public final class V2_WIDOMEditingModel {
    public init() {}
}

@MainActor
@Observable
public final class V2_WINetworkInterfaceModel {
    public var searchText: String
    public var activeResourceFilters: Set<NetworkResourceFilter>
    public var selectedEntryID: UUID?

    public init(
        searchText: String = "",
        activeResourceFilters: Set<NetworkResourceFilter> = [],
        selectedEntryID: UUID? = nil
    ) {
        self.searchText = searchText
        self.activeResourceFilters = activeResourceFilters
        self.selectedEntryID = selectedEntryID
    }
}
#endif
