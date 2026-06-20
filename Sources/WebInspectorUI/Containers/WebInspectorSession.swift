#if canImport(UIKit)
import Observation
import UIKit
import WebKit
import WebInspectorCore

@MainActor
@Observable
public final class WebInspectorSession {
    package let inspector: InspectorSession
    package let interface: InterfaceModel
    /// The user interface style inferred from the inspected page.
    ///
    /// The value is `.unspecified` until the page style is known or when no useful style can be inferred.
    public private(set) var pageUserInterfaceStyle: UIUserInterfaceStyle = .unspecified
    @ObservationIgnored private let attachAction: @MainActor (InspectorSession, WKWebView) async throws -> Void
    @ObservationIgnored private let detachAction: @MainActor (InspectorSession) async -> Void
    @ObservationIgnored private var pageUserInterfaceStyleObserver: WebInspectorPageUserInterfaceStyleObserver?

    public convenience init(tabs: [WebInspectorTab] = [.dom, .network]) {
        self.init(inspector: InspectorSession(), tabs: tabs)
    }

    package init(
        inspector: InspectorSession,
        tabs: [WebInspectorTab] = [.dom, .network],
        attachAction: @escaping @MainActor (InspectorSession, WKWebView) async throws -> Void = { inspector, webView in
            try await inspector.attach(to: webView)
        },
        detachAction: @escaping @MainActor (InspectorSession) async -> Void = { inspector in
            await inspector.detach()
        }
    ) {
        self.inspector = inspector
        self.interface = InterfaceModel(tabs: tabs)
        self.attachAction = attachAction
        self.detachAction = detachAction
    }

    isolated deinit {
        stopPageUserInterfaceStyleObservation()
        interface.removeContentCache()
    }

    package var attachment: AttachedInspection {
        inspector.attachment
    }

    public func attach(to webView: WKWebView) async throws {
        stopPageUserInterfaceStyleObservation()
        do {
            try await attachAction(inspector, webView)
            startPageUserInterfaceStyleObservation(for: webView)
        } catch {
            stopPageUserInterfaceStyleObservation()
            throw error
        }
    }

    public func detach() async {
        stopPageUserInterfaceStyleObservation()
        await detachAction(inspector)
    }

    private func startPageUserInterfaceStyleObservation(for webView: WKWebView) {
        let observer = WebInspectorPageUserInterfaceStyleObserver(webView: webView) { [weak self] style in
            self?.setPageUserInterfaceStyle(style)
        }
        pageUserInterfaceStyleObserver = observer
        observer.start()
    }

    private func stopPageUserInterfaceStyleObservation() {
        pageUserInterfaceStyleObserver?.invalidate()
        pageUserInterfaceStyleObserver = nil
        setPageUserInterfaceStyle(.unspecified)
    }

    private func setPageUserInterfaceStyle(_ style: UIUserInterfaceStyle) {
        guard pageUserInterfaceStyle != style else {
            return
        }
        pageUserInterfaceStyle = style
    }
}

#if DEBUG
extension WebInspectorSession {
    package var hasPageUserInterfaceStyleObserverForTesting: Bool {
        pageUserInterfaceStyleObserver != nil
    }
}
#endif

@MainActor
@Observable
package final class InterfaceModel {
    package private(set) var tabs: [WebInspectorTab]
    package private(set) var selectedItemID: WebInspectorTab.DisplayItem.ID?
    @ObservationIgnored private let projection = WebInspectorTab.DisplayProjection()
    @ObservationIgnored private let contentCache = WebInspectorTab.ContentCache()
    @ObservationIgnored private var networkPanelModel: NetworkPanelModel?

    package init(tabs: [WebInspectorTab] = [.dom, .network]) {
        let uniqueTabs = Self.uniqueTabs(tabs)
        self.tabs = uniqueTabs
        selectedItemID = uniqueTabs.first?.id
    }

    package func displayItems(for hostLayout: WebInspectorTab.HostLayout) -> [WebInspectorTab.DisplayItem] {
        projection.displayItems(for: hostLayout, tabs: tabs)
    }

    package func resolvedSelection(for hostLayout: WebInspectorTab.HostLayout) -> WebInspectorTab.DisplayItem? {
        projection.resolvedSelection(
            for: hostLayout,
            tabs: tabs,
            selectedItemID: selectedItemID
        )
    }

    package func descriptor(for displayItem: WebInspectorTab.DisplayItem) -> WebInspectorTab.DisplayDescriptor? {
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

    package func selectItem(_ displayItem: WebInspectorTab.DisplayItem) {
        guard isValidItemID(displayItem.id),
              selectedItemID != displayItem.id else {
            return
        }
        selectedItemID = displayItem.id
    }

    package func selectItem(withID displayItemID: WebInspectorTab.DisplayItem.ID) {
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
        for key: WebInspectorTab.ContentKey,
        make: () -> Content
    ) -> Content {
        contentCache.viewController(for: key, make: make)
    }

    package func networkPanelModel(for inspection: AttachedInspection) -> NetworkPanelModel {
        if let networkPanelModel,
           networkPanelModel.network === inspection.network {
            return networkPanelModel
        }

        let model = NetworkPanelModel(network: inspection.network) { [weak inspection] id in
            await inspection?.network.fetchResponseBody(for: id)
        }
        networkPanelModel = model
        return model
    }

    package func pruneContentCache(retaining keys: Set<WebInspectorTab.ContentKey>) {
        contentCache.prune(retaining: keys)
    }

    package func removeContentCache() {
        contentCache.removeAll()
    }

    #if DEBUG
    package var contentCacheCountForTesting: Int {
        contentCache.countForTesting
    }
    #endif

    package var selectedTab: WebInspectorTab? {
        guard let selectedItemID else {
            return nil
        }
        let selectedSourceTabID = selectedItemID == WebInspectorTab.DisplayItem.domElementID
            ? WebInspectorTab.dom.id
            : selectedItemID
        return tabs.first { $0.id == selectedSourceTabID }
    }

    private func isValidItemID(_ displayItemID: WebInspectorTab.DisplayItem.ID) -> Bool {
        if tabs.contains(where: { $0.id == displayItemID }) {
            return true
        }
        return displayItemID == WebInspectorTab.DisplayItem.domElementID
            && tabs.contains(where: { $0.builtIn == .dom })
    }

    private func reachableContentKeys(for tabs: [WebInspectorTab]) -> Set<WebInspectorTab.ContentKey> {
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
