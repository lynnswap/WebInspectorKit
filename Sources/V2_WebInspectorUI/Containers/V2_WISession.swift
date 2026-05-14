#if canImport(UIKit)
import Observation
import UIKit
import WebKit
import V2_WebInspectorRuntime

@MainActor
@Observable
public final class V2_WISession {
    package let inspector: V2_InspectorSession
    package let interface: V2_InterfaceModel

    public convenience init(tabs: [V2_WITab] = [.dom, .network]) {
        self.init(inspector: V2_InspectorSession(), tabs: tabs)
    }

    package init(
        inspector: V2_InspectorSession,
        tabs: [V2_WITab] = [.dom, .network]
    ) {
        self.inspector = inspector
        self.interface = V2_InterfaceModel(tabs: tabs)
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
package final class V2_InterfaceModel {
    package private(set) var tabs: [V2_WITab]
    package private(set) var selectedItemID: V2_TabDisplayItem.ID?
    @ObservationIgnored private let projection = V2_TabDisplayProjection()
    @ObservationIgnored private let contentCache = V2_TabContentCache()
    @ObservationIgnored private var networkPanelModel: V2_NetworkPanelModel?

    package init(tabs: [V2_WITab] = [.dom, .network]) {
        self.tabs = Self.uniqueTabs(tabs)
        selectedItemID = self.tabs.first?.id
    }

    package func displayItems(for hostLayout: V2_WITabHostLayout) -> [V2_TabDisplayItem] {
        projection.displayItems(for: hostLayout, tabs: tabs)
    }

    package func resolvedSelection(for hostLayout: V2_WITabHostLayout) -> V2_TabDisplayItem? {
        projection.resolvedSelection(
            for: hostLayout,
            tabs: tabs,
            selectedItemID: selectedItemID
        )
    }

    package func descriptor(for displayItem: V2_TabDisplayItem) -> V2_TabDisplayDescriptor? {
        projection.descriptor(for: displayItem, tabs: tabs)
    }

    package func selectTab(_ tab: V2_WITab) {
        guard tabs.contains(tab) else {
            return
        }
        selectItem(.tab(tab.id))
    }

    package func selectTab(withID tabID: V2_WITab.ID) {
        selectItem(.tab(tabID))
    }

    package func selectItem(_ displayItem: V2_TabDisplayItem) {
        guard isValidItemID(displayItem.id),
              selectedItemID != displayItem.id else {
            return
        }
        selectedItemID = displayItem.id
    }

    package func selectItem(withID displayItemID: V2_TabDisplayItem.ID) {
        guard isValidItemID(displayItemID),
              selectedItemID != displayItemID else {
            return
        }
        selectedItemID = displayItemID
    }

    package func setTabs(_ tabs: [V2_WITab]) {
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
        for key: V2_TabContentKey,
        make: () -> Content
    ) -> Content {
        contentCache.viewController(for: key, make: make)
    }

    package func networkPanelModel(for inspector: V2_InspectorSession) -> V2_NetworkPanelModel {
        if let networkPanelModel,
           networkPanelModel.network === inspector.network {
            return networkPanelModel
        }

        let model = V2_NetworkPanelModel(network: inspector.network) { [weak inspector] id in
            await inspector?.fetchResponseBody(for: id)
        }
        networkPanelModel = model
        return model
    }

    package func pruneContentCache(retaining keys: Set<V2_TabContentKey>) {
        contentCache.prune(retaining: keys)
    }

    package func removeContentCache() {
        contentCache.removeAll()
    }

    package var selectedTab: V2_WITab? {
        guard let selectedItemID else {
            return nil
        }
        let selectedSourceTabID = selectedItemID == V2_TabDisplayItem.domElementID
            ? V2_WITab.dom.id
            : selectedItemID
        return tabs.first { $0.id == selectedSourceTabID }
    }

    private func isValidItemID(_ displayItemID: V2_TabDisplayItem.ID) -> Bool {
        if tabs.contains(where: { $0.id == displayItemID }) {
            return true
        }
        return displayItemID == V2_TabDisplayItem.domElementID
            && tabs.contains(where: { $0.builtIn == .dom })
    }

    private func reachableContentKeys(for tabs: [V2_WITab]) -> Set<V2_TabContentKey> {
        projection.contentKeys(for: .compact, tabs: tabs)
            .union(projection.contentKeys(for: .regular, tabs: tabs))
    }

    private static func uniqueTabs(_ tabs: [V2_WITab]) -> [V2_WITab] {
        tabs.reduce(into: []) { result, tab in
            guard result.contains(where: { $0.id == tab.id }) == false else {
                return
            }
            result.append(tab)
        }
    }
}
#endif
