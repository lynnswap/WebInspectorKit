#if canImport(UIKit)
import Observation
import UIKit
import WebKit
import WebInspectorRuntime

@MainActor
@Observable
public final class WebInspectorSession {
    package let inspector: InspectorSession
    package let interface: InterfaceModel

    public convenience init(tabs: [WebInspectorTab] = [.dom, .network]) {
        self.init(inspector: InspectorSession(), tabs: tabs)
    }

    package init(
        inspector: InspectorSession,
        tabs: [WebInspectorTab] = [.dom, .network]
    ) {
        self.inspector = inspector
        self.interface = InterfaceModel(tabs: tabs)
    }

    isolated deinit {
        interface.removeContentCache()
    }

    public func attach(to webView: WKWebView) async throws {
        try await inspector.attach(to: webView)
    }

    public func detach() async {
        await inspector.detach()
    }
}

@MainActor
@Observable
package final class InterfaceModel {
    package private(set) var tabs: [WebInspectorTab]
    package private(set) var selectedItemID: TabDisplayItem.ID?
    @ObservationIgnored private let projection = TabDisplayProjection()
    @ObservationIgnored private let contentCache = TabContentCache()
    @ObservationIgnored private var networkPanelModel: NetworkPanelModel?

    package init(tabs: [WebInspectorTab] = [.dom, .network]) {
        self.tabs = Self.uniqueTabs(tabs)
        selectedItemID = self.tabs.first?.id
    }

    package func displayItems(for hostLayout: WebInspectorTabHostLayout) -> [TabDisplayItem] {
        projection.displayItems(for: hostLayout, tabs: tabs)
    }

    package func resolvedSelection(for hostLayout: WebInspectorTabHostLayout) -> TabDisplayItem? {
        projection.resolvedSelection(
            for: hostLayout,
            tabs: tabs,
            selectedItemID: selectedItemID
        )
    }

    package func descriptor(for displayItem: TabDisplayItem) -> TabDisplayDescriptor? {
        projection.descriptor(for: displayItem, tabs: tabs)
    }

    package func selectTab(_ tab: WebInspectorTab) {
        guard tabs.contains(tab) else {
            return
        }
        selectItem(.tab(tab.id))
    }

    package func selectTab(withID tabID: WebInspectorTab.ID) {
        selectItem(.tab(tabID))
    }

    package func selectItem(_ displayItem: TabDisplayItem) {
        guard isValidItemID(displayItem.id),
              selectedItemID != displayItem.id else {
            return
        }
        selectedItemID = displayItem.id
    }

    package func selectItem(withID displayItemID: TabDisplayItem.ID) {
        guard isValidItemID(displayItemID),
              selectedItemID != displayItemID else {
            return
        }
        selectedItemID = displayItemID
    }

    package func setTabs(_ tabs: [WebInspectorTab]) {
        let uniqueTabs = Self.uniqueTabs(tabs)
        self.tabs = uniqueTabs
        pruneContentCache(retaining: reachableContentKeys(for: uniqueTabs))
        guard let selectedItemID,
              isValidItemID(selectedItemID) else {
            self.selectedItemID = uniqueTabs.first?.id
            return
        }
    }

    package func viewController<Content: UIViewController>(
        for key: TabContentKey,
        make: () -> Content
    ) -> Content {
        contentCache.viewController(for: key, make: make)
    }

    package func networkPanelModel(for inspector: InspectorSession) -> NetworkPanelModel {
        if let networkPanelModel,
           networkPanelModel.network === inspector.network {
            return networkPanelModel
        }

        let model = NetworkPanelModel(network: inspector.network) { [weak inspector] id in
            await inspector?.fetchResponseBody(for: id)
        }
        networkPanelModel = model
        return model
    }

    package func pruneContentCache(retaining keys: Set<TabContentKey>) {
        contentCache.prune(retaining: keys)
    }

    package func removeContentCache() {
        contentCache.removeAll()
    }

    package var selectedTab: WebInspectorTab? {
        guard let selectedItemID else {
            return nil
        }
        let selectedSourceTabID = selectedItemID == TabDisplayItem.domElementID
            ? WebInspectorTab.dom.id
            : selectedItemID
        return tabs.first { $0.id == selectedSourceTabID }
    }

    private func isValidItemID(_ displayItemID: TabDisplayItem.ID) -> Bool {
        if tabs.contains(where: { $0.id == displayItemID }) {
            return true
        }
        return displayItemID == TabDisplayItem.domElementID
            && tabs.contains(where: { $0.builtIn == .dom })
    }

    private func reachableContentKeys(for tabs: [WebInspectorTab]) -> Set<TabContentKey> {
        projection.contentKeys(for: .compact, tabs: tabs)
            .union(projection.contentKeys(for: .regular, tabs: tabs))
    }

    private static func uniqueTabs(_ tabs: [WebInspectorTab]) -> [WebInspectorTab] {
        tabs.reduce(into: []) { result, tab in
            guard result.contains(where: { $0.id == tab.id }) == false else {
                return
            }
            result.append(tab)
        }
    }
}
#endif
