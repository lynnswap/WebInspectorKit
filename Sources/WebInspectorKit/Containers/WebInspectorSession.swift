#if canImport(UIKit)
import Observation
import UIKit
import WebKit
import WebInspectorDataKit
import WebInspectorProxyKit

/// The UIKit-facing owner of one inspector model container.
///
/// Attachment, generations, feature state, and query lifetimes remain owned by
/// DataKit. This facade only pins the presentation's main context and observes
/// page appearance for UIKit.
@MainActor
@Observable
public final class WebInspectorSession {
    @ObservationIgnored public let modelContainer: WebInspectorModelContainer
    @ObservationIgnored private let pinnedModelContext: WebInspectorModelContext

    /// The stable main-actor context used by the built-in presentation.
    public var modelContext: WebInspectorModelContext { pinnedModelContext }

    public private(set) var pageUserInterfaceStyle: UIUserInterfaceStyle = .unspecified

    @ObservationIgnored private let makePageUserInterfaceStyleObserver: @MainActor (
        WKWebView,
        @escaping @MainActor (UIUserInterfaceStyle) -> Void
    ) -> any WebInspectorPageUserInterfaceStyleObserving
    @ObservationIgnored private var pageUserInterfaceStyleObserver:
        (any WebInspectorPageUserInterfaceStyleObserving)?

    #if DEBUG
    package private(set) var detachCountForTesting = 0
    #endif

    public init(
        modelContainer: WebInspectorModelContainer = .init()
    ) {
        self.modelContainer = modelContainer
        self.pinnedModelContext = modelContainer.mainContext
        self.makePageUserInterfaceStyleObserver = { webView, apply in
            WebInspectorPageUserInterfaceStyleObserver(
                webView: webView,
                apply: apply
            )
        }
    }

    package init(
        modelContainer: WebInspectorModelContainer,
        makePageUserInterfaceStyleObserver: @escaping @MainActor (
            WKWebView,
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> any WebInspectorPageUserInterfaceStyleObserving
    ) {
        self.modelContainer = modelContainer
        self.pinnedModelContext = modelContainer.mainContext
        self.makePageUserInterfaceStyleObserver = makePageUserInterfaceStyleObserver
    }

    isolated deinit {
        stopPageUserInterfaceStyleObservation()
    }

    public func attach(
        to webView: WKWebView,
        proxyConfiguration: WebInspectorProxy.Configuration = .init()
    ) async throws {
        stopPageUserInterfaceStyleObservation()
        do {
            try await modelContainer.attach(
                to: webView,
                proxyConfiguration: proxyConfiguration
            )
            startPageUserInterfaceStyleObservation(for: webView)
        } catch {
            stopPageUserInterfaceStyleObservation()
            throw error
        }
    }

    public func detach() async {
        #if DEBUG
        detachCountForTesting += 1
        #endif
        stopPageUserInterfaceStyleObservation()
        await modelContainer.detach()
    }

    public func close() async {
        stopPageUserInterfaceStyleObservation()
        await modelContainer.close()
    }

    package func suspendBackendInteraction() async throws {
        try await modelContainer.dom.hideHighlight()
    }

    private func startPageUserInterfaceStyleObservation(for webView: WKWebView) {
        let observer = makePageUserInterfaceStyleObserver(webView) { [weak self] style in
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
        guard pageUserInterfaceStyle != style else { return }
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
    package let catalog: WebInspectorTabCatalog
    package var tabs: [WebInspectorTab] { catalog.tabs }
    package private(set) var selectedItemID: WebInspectorTab.DisplayItem.ID?

    @ObservationIgnored private let projection = WebInspectorTab.DisplayProjection()

    package init(catalog: WebInspectorTabCatalog = .standard) {
        self.catalog = catalog
        self.selectedItemID = catalog.tabs.first?.id.rawValue
    }

    package func displayItems(
        for hostLayout: WebInspectorTab.HostLayout
    ) -> [WebInspectorTab.DisplayItem] {
        projection.displayItems(for: hostLayout, tabs: tabs)
    }

    package func resolvedSelection(
        for hostLayout: WebInspectorTab.HostLayout
    ) -> WebInspectorTab.DisplayItem? {
        projection.resolvedSelection(
            for: hostLayout,
            tabs: tabs,
            selectedItemID: selectedItemID
        )
    }

    package func descriptor(
        for displayItem: WebInspectorTab.DisplayItem
    ) -> WebInspectorTab.DisplayDescriptor? {
        projection.descriptor(for: displayItem, catalog: catalog)
    }

    package func selectTab(_ tab: WebInspectorTab) {
        guard catalog.tabByID[tab.id] != nil else { return }
        selectItem(.tab(tab.id))
    }

    package func selectTab(withID tabID: WebInspectorTab.ID) {
        guard let tab = catalog.tabByID[tabID] else { return }
        selectTab(tab)
    }

    package func selectItem(_ displayItem: WebInspectorTab.DisplayItem) {
        selectItem(withID: displayItem.id)
    }

    package func selectItem(withID displayItemID: WebInspectorTab.DisplayItem.ID) {
        guard validDisplayItemIDs.contains(displayItemID),
              selectedItemID != displayItemID else {
            return
        }
        selectedItemID = displayItemID
    }

    package var selectedTab: WebInspectorTab? {
        guard let selectedItemID,
              let item = allDisplayItems.first(where: { $0.id == selectedItemID })
        else {
            return nil
        }
        return catalog.tabByID[item.sourceTabID]
    }

    private var allDisplayItems: [WebInspectorTab.DisplayItem] {
        let compact = projection.displayItems(for: .compact, tabs: tabs)
        let regular = projection.displayItems(for: .regular, tabs: tabs)
        return compact + regular.filter { compact.contains($0) == false }
    }

    private var validDisplayItemIDs: Set<WebInspectorTab.DisplayItem.ID> {
        Set(allDisplayItems.map(\.id))
    }
}
#endif
