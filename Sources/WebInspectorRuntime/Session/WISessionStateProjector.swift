import Foundation
import WebInspectorModel

@MainActor
enum WISessionStateProjector {
    static func project(_ state: WISessionState, onto session: WISession) {
        if session.selectedTabID != state.selectedTabID {
            session.selectedTabID = state.selectedTabID
        }

        if session.network.searchText != state.network.searchText {
            session.network.searchText = state.network.searchText
        }

        if session.network.activeResourceFilters != state.network.activeResourceFilters {
            session.network.activeResourceFilters = state.network.activeResourceFilters
        }

        if session.network.selectedEntry?.id != state.network.selectedEntryID {
            if let entryID = state.network.selectedEntryID {
                session.network.selectedEntry = session.network.store.entries.first(where: { $0.id == entryID })
            } else {
                session.network.selectedEntry = nil
            }
        }
    }
}

@MainActor
extension WISessionState {
    static func makeInitial(selectedTabID: String? = nil, dom: WIDOMModel, network: WINetworkModel) -> Self {
        WISessionState(
            selectedTabID: selectedTabID,
            dom: WIDOMState(
                hasPageWebView: dom.hasPageWebView,
                isSelectingElement: dom.isSelectingElement,
                selectedNodeID: dom.selection.nodeId,
                snapshotDepth: dom.session.configuration.snapshotDepth
            ),
            network: WINetworkState(
                selectedEntryID: network.selectedEntry?.id,
                searchText: network.searchText,
                activeResourceFilters: network.activeResourceFilters,
                effectiveResourceFilters: network.effectiveResourceFilters
            )
        )
    }
}
