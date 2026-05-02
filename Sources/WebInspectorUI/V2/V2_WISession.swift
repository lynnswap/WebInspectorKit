#if canImport(UIKit)
import Observation
import UIKit
import WebKit
import WebInspectorRuntime

@MainActor
@Observable
public final class V2_WISession {
    public let runtime: V2_WIRuntimeSession
    public let interface: V2_WIInterfaceModel

    public init(
        runtime: V2_WIRuntimeSession = V2_WIRuntimeSession(),
        tabs: [V2_WITab] = [.dom, .network]
    ) {
        self.runtime = runtime
        self.interface = V2_WIInterfaceModel(tabs: tabs)
    }

    public convenience init(
        configuration: WIModelConfiguration,
        dependencies: WIInspectorDependencies = .liveValue,
        tabs: [V2_WITab] = [.dom, .network]
    ) {
        self.init(
            runtime: V2_WIRuntimeSession(
                configuration: configuration,
                dependencies: dependencies
            ),
            tabs: tabs
        )
    }

    public convenience init(
        dependencies: WIInspectorDependencies,
        tabs: [V2_WITab] = [.dom, .network]
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
public final class V2_WIInterfaceModel {
    private(set) var tabs: [V2_WITab]
    private(set) var selectedItemID: V2_TabDisplayItem.ID?
    @ObservationIgnored private let projection = V2_TabDisplayProjection()
    @ObservationIgnored private let contentCache = V2_TabContentCache()

    public init(tabs: [V2_WITab] = [.dom, .network]) {
        self.tabs = Self.uniqueTabs(tabs)
        self.selectedItemID = self.tabs.first?.id
    }

    func displayItems(for hostLayout: V2_WITabHostLayout) -> [V2_TabDisplayItem] {
        projection.displayItems(for: hostLayout, tabs: tabs)
    }

    func resolvedSelection(for hostLayout: V2_WITabHostLayout) -> V2_TabDisplayItem? {
        projection.resolvedSelection(
            for: hostLayout,
            tabs: tabs,
            selectedItemID: selectedItemID
        )
    }

    func descriptor(for displayItem: V2_TabDisplayItem) -> V2_TabDisplayDescriptor? {
        projection.descriptor(for: displayItem, tabs: tabs)
    }

    func selectTab(_ tab: V2_WITab) {
        guard tabs.contains(tab) else {
            return
        }
        selectItem(.tab(tab.id))
    }

    func selectTab(withID tabID: V2_WITab.ID) {
        selectItem(.tab(tabID))
    }

    func selectItem(_ displayItem: V2_TabDisplayItem) {
        guard isValidItemID(displayItem.id),
              selectedItemID != displayItem.id else {
            return
        }
        selectedItemID = displayItem.id
    }

    func selectItem(withID displayItemID: V2_TabDisplayItem.ID) {
        guard isValidItemID(displayItemID),
              selectedItemID != displayItemID else {
            return
        }
        selectedItemID = displayItemID
    }

    func setTabs(_ tabs: [V2_WITab]) {
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
        for key: V2_TabContentKey,
        make: () -> Content
    ) -> Content {
        contentCache.viewController(for: key, make: make)
    }

    func pruneContentCache(retaining keys: Set<V2_TabContentKey>) {
        contentCache.prune(retaining: keys)
    }

    func removeContentCache() {
        contentCache.removeAll()
    }

    var selectedTab: V2_WITab? {
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
