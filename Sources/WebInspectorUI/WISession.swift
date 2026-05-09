#if canImport(UIKit)
import Observation
import UIKit
import WebKit
import WebInspectorRuntime

@MainActor
@Observable
public final class WISession {
    public let runtime: WIRuntimeSession
    public let interface: WIInterfaceModel

    public init(
        runtime: WIRuntimeSession = WIRuntimeSession(),
        tabs: [WITab] = [.dom, .network]
    ) {
        self.runtime = runtime
        self.interface = WIInterfaceModel(tabs: tabs)
    }

    public convenience init(
        configuration: WIModelConfiguration,
        dependencies: WIInspectorDependencies = .liveValue,
        tabs: [WITab] = [.dom, .network]
    ) {
        self.init(
            runtime: WIRuntimeSession(
                configuration: configuration,
                dependencies: dependencies
            ),
            tabs: tabs
        )
    }

    public convenience init(
        dependencies: WIInspectorDependencies,
        tabs: [WITab] = [.dom, .network]
    ) {
        self.init(
            configuration: .init(),
            dependencies: dependencies,
            tabs: tabs
        )
    }

    isolated deinit {
        interface.removeContentCache()
    }

    public func attach(to webView: WKWebView) async {
        await runtime.attach(to: webView)
    }

    public func detach() async {
        await runtime.detach()
    }
}

@MainActor
@Observable
public final class WIInterfaceModel {
    private(set) var tabs: [WITab]
    private(set) var selectedItemID: TabDisplayItem.ID?
    @ObservationIgnored private let projection = TabDisplayProjection()
    @ObservationIgnored private let contentCache = TabContentCache()

    public init(tabs: [WITab] = [.dom, .network]) {
        self.tabs = Self.uniqueTabs(tabs)
        self.selectedItemID = self.tabs.first?.id
    }

    func displayItems(for hostLayout: WITabHostLayout) -> [TabDisplayItem] {
        projection.displayItems(for: hostLayout, tabs: tabs)
    }

    func resolvedSelection(for hostLayout: WITabHostLayout) -> TabDisplayItem? {
        projection.resolvedSelection(
            for: hostLayout,
            tabs: tabs,
            selectedItemID: selectedItemID
        )
    }

    func descriptor(for displayItem: TabDisplayItem) -> TabDisplayDescriptor? {
        projection.descriptor(for: displayItem, tabs: tabs)
    }

    func selectTab(_ tab: WITab) {
        guard tabs.contains(tab) else {
            return
        }
        selectItem(.tab(tab.id))
    }

    func selectTab(withID tabID: WITab.ID) {
        selectItem(.tab(tabID))
    }

    func selectItem(_ displayItem: TabDisplayItem) {
        guard isValidItemID(displayItem.id),
              selectedItemID != displayItem.id else {
            return
        }
        selectedItemID = displayItem.id
    }

    func selectItem(withID displayItemID: TabDisplayItem.ID) {
        guard isValidItemID(displayItemID),
              selectedItemID != displayItemID else {
            return
        }
        selectedItemID = displayItemID
    }

    func setTabs(_ tabs: [WITab]) {
        let uniqueTabs = Self.uniqueTabs(tabs)
        self.tabs = uniqueTabs
        pruneContentCache(retaining: reachableContentKeys(for: uniqueTabs))
        guard let selectedItemID,
              isValidItemID(selectedItemID) else {
            self.selectedItemID = uniqueTabs.first?.id
            return
        }
    }

    func viewController<Content: UIViewController>(
        for key: TabContentKey,
        make: () -> Content
    ) -> Content {
        contentCache.viewController(for: key, make: make)
    }

    func pruneContentCache(retaining keys: Set<TabContentKey>) {
        contentCache.prune(retaining: keys)
    }

    func removeContentCache() {
        contentCache.removeAll()
    }

    var selectedTab: WITab? {
        guard let selectedItemID else {
            return nil
        }
        let selectedSourceTabID = selectedItemID == TabDisplayItem.domElementID
            ? WITab.dom.id
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

    private func reachableContentKeys(for tabs: [WITab]) -> Set<TabContentKey> {
        projection.contentKeys(for: .compact, tabs: tabs)
            .union(projection.contentKeys(for: .regular, tabs: tabs))
    }

    private static func uniqueTabs(_ tabs: [WITab]) -> [WITab] {
        tabs.reduce(into: []) { result, tab in
            guard result.contains(where: { $0.id == tab.id }) == false else {
                return
            }
            result.append(tab)
        }
    }
}
#endif
