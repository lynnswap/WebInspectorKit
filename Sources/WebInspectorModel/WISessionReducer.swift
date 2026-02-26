import Foundation
import WebInspectorEngine

public enum WISessionEffect {
    case dom(WIDOMCommand)
    case network(WINetworkCommand)
}

@MainActor
public enum WISessionReducer {
    public static func reduce(state: inout WISessionState, command: WISessionCommand) -> [WISessionEffect] {
        switch command {
        case let .selectTab(tabID):
            state.selectedTabID = tabID
            return []

        case let .dom(command):
            return reduceDOM(state: &state, command: command)

        case let .network(command):
            return reduceNetwork(state: &state, command: command)

        case let .event(event):
            reduceEvent(state: &state, event: event)
            return []
        }
    }

    private static func reduceDOM(state: inout WISessionState, command: WIDOMCommand) -> [WISessionEffect] {
        switch command {
        case let .setSnapshotDepth(depth):
            let clampedDepth = max(1, depth)
            state.dom.snapshotDepth = clampedDepth
            return [.dom(.setSnapshotDepth(clampedDepth))]

        case .cancelSelectionMode:
            state.dom.isSelectingElement = false
            return [.dom(.cancelSelectionMode)]

        case let .deleteNode(nodeId, undoManager):
            if state.dom.selectedNodeID == nodeId {
                state.dom.selectedNodeID = nil
            }
            return [.dom(.deleteNode(nodeId: nodeId, undoManager: undoManager))]

        default:
            return [.dom(command)]
        }
    }

    private static func reduceNetwork(state: inout WISessionState, command: WINetworkCommand) -> [WISessionEffect] {
        switch command {
        case let .setSearchText(text):
            state.network.searchText = text
            return [.network(.setSearchText(text))]

        case let .selectEntry(id):
            state.network.selectedEntryID = id
            return [.network(.selectEntry(id: id))]

        case let .setResourceFilter(filter, isEnabled):
            state.network.activeResourceFilters = nextFilters(
                from: state.network.activeResourceFilters,
                filter: filter,
                isEnabled: isEnabled
            )
            state.network.effectiveResourceFilters = NetworkResourceFilter.normalizedSelection(state.network.activeResourceFilters)
            return [.network(.setResourceFilter(filter, isEnabled: isEnabled))]

        case .clear:
            state.network.selectedEntryID = nil
            return [.network(.clear)]

        case let .fetchBody(entry, body, force):
            return [.network(.fetchBody(entry: entry, body: body, force: force))]
        }
    }

    private static func reduceEvent(state: inout WISessionState, event: WIDomainEvent) {
        switch event {
        case let .dom(domEvent):
            switch domEvent {
            case let .pageWebViewAvailabilityChanged(hasPageWebView):
                state.dom.hasPageWebView = hasPageWebView
            case let .selectingElementChanged(isSelecting):
                state.dom.isSelectingElement = isSelecting
            case let .selectionNodeChanged(nodeID):
                state.dom.selectedNodeID = nodeID
            case let .snapshotDepthChanged(depth):
                state.dom.snapshotDepth = max(1, depth)
            }

        case let .network(networkEvent):
            switch networkEvent {
            case let .selectedEntryChanged(entryID):
                state.network.selectedEntryID = entryID
            case let .searchTextChanged(searchText):
                state.network.searchText = searchText
            case let .activeFiltersChanged(filters):
                state.network.activeResourceFilters = filters
            case let .effectiveFiltersChanged(filters):
                state.network.effectiveResourceFilters = filters
            }
        }
    }

    private static func nextFilters(
        from current: Set<NetworkResourceFilter>,
        filter: NetworkResourceFilter,
        isEnabled: Bool
    ) -> Set<NetworkResourceFilter> {
        if filter == .all {
            return isEnabled ? [] : current
        }
        var next = current
        if isEnabled {
            next.insert(filter)
        } else {
            next.remove(filter)
        }
        return next
    }
}
