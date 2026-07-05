#if canImport(UIKit)
import Observation
import UIKit
import WebKit
import WebInspectorDataKit
import WebInspectorUIBase
import WebInspectorUINetwork

@MainActor
@Observable
public final class WebInspectorSession {
    package let interface: InterfaceModel
    /// The user interface style inferred from the inspected page.
    ///
    /// The value is `.unspecified` until the page style is known or when no useful style can be inferred.
    public private(set) var pageUserInterfaceStyle: UIUserInterfaceStyle = .unspecified
    @ObservationIgnored private var container: WebInspectorContainer?
    @ObservationIgnored private var dataContext: WebInspectorContext
    @ObservationIgnored private var attachmentGeneration: UInt64 = 0
    @ObservationIgnored private let makePageUserInterfaceStyleObserver: @MainActor (
        WKWebView,
        @escaping @MainActor (UIUserInterfaceStyle) -> Void
    ) -> any WebInspectorPageUserInterfaceStyleObserving
    @ObservationIgnored private var pageUserInterfaceStyleObserver: (any WebInspectorPageUserInterfaceStyleObserving)?
    #if DEBUG
    @ObservationIgnored package private(set) var detachCountForTesting = 0
    #endif

    public init(tabs: [WebInspectorTab] = [.dom, .network]) {
        self.interface = InterfaceModel(tabs: tabs)
        self.dataContext = Self.makeDetachedDataContext()
        self.makePageUserInterfaceStyleObserver = { webView, apply in
            WebInspectorPageUserInterfaceStyleObserver(webView: webView, apply: apply)
        }
    }

    package init(
        context: WebInspectorContext,
        tabs: [WebInspectorTab] = [.dom, .network],
        makePageUserInterfaceStyleObserver: @escaping @MainActor (
            WKWebView,
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> any WebInspectorPageUserInterfaceStyleObserving = { webView, apply in
            WebInspectorPageUserInterfaceStyleObserver(webView: webView, apply: apply)
        }
    ) {
        self.interface = InterfaceModel(tabs: tabs)
        self.dataContext = context
        self.makePageUserInterfaceStyleObserver = makePageUserInterfaceStyleObserver
    }

    isolated deinit {
        stopPageUserInterfaceStyleObservation()
        interface.removeContentCache()
    }

    package var context: WebInspectorContext {
        dataContext
    }

    public func attach(to webView: WKWebView) async throws {
        try await attach(to: webView) { webView in
            try await WebInspectorContainer(attachingTo: webView)
        }
    }

    package func attach(
        to webView: WKWebView,
        makeContainer: @MainActor (WKWebView) async throws -> WebInspectorContainer
    ) async throws {
        let generation = advanceAttachmentGeneration()
        stopPageUserInterfaceStyleObservation()
        await stopContainer(replaceContextWithDetached: false)
        try Task.checkCancellation()
        guard isCurrentAttachmentGeneration(generation) else {
            throw CancellationError()
        }
        do {
            let container = try await makeContainer(webView)
            try Task.checkCancellation()
            guard isCurrentAttachmentGeneration(generation) else {
                await container.close()
                throw CancellationError()
            }
            self.container = container
            installDataContext(container.mainContext)
            startPageUserInterfaceStyleObservation(for: webView)
        } catch {
            guard isCurrentAttachmentGeneration(generation) else {
                throw error
            }
            installDataContext(Self.makeDetachedDataContext())
            stopPageUserInterfaceStyleObservation()
            throw error
        }
    }

    public func detach() async {
        advanceAttachmentGeneration()
        #if DEBUG
        detachCountForTesting += 1
        #endif
        stopPageUserInterfaceStyleObservation()
        await stopContainer(replaceContextWithDetached: true)
    }

    package func retireRootPresentation(detach: Bool) async {
        interface.removeContentCache()
        guard detach else {
            await suspendBackendInteractionForPresentationEnd()
            return
        }
        await self.detach()
    }

    /// Mirrors the legacy presentation-end retirement: without tearing down the
    /// connection, disable the element picker and hide any visible highlight so
    /// a re-presentation starts from a clean interaction state.
    private func suspendBackendInteractionForPresentationEnd() async {
        guard dataContext.status.state == .attached else {
            return
        }
        if dataContext.isElementPickerEnabled {
            try? await dataContext.setElementPickerEnabled(false)
        }
        try? await dataContext.hideHighlight()
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
        guard pageUserInterfaceStyle != style else {
            return
        }
        pageUserInterfaceStyle = style
    }

    @discardableResult
    private func advanceAttachmentGeneration() -> UInt64 {
        attachmentGeneration &+= 1
        return attachmentGeneration
    }

    private func isCurrentAttachmentGeneration(_ generation: UInt64) -> Bool {
        attachmentGeneration == generation
    }

    package func installDataContext(_ context: WebInspectorContext) {
        dataContext = context
        interface.removeContextBoundContent()
    }

    private func stopContainer(replaceContextWithDetached: Bool) async {
        interface.removeContextBoundContent()
        if let container {
            self.container = nil
            await container.close()
        } else {
            await dataContext.stop()
        }
        if replaceContextWithDetached {
            installDataContext(Self.makeDetachedDataContext())
        }
    }

    private static func makeDetachedDataContext() -> WebInspectorContext {
        WebInspectorContext.detached(isolation: MainActor.shared)
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
        selectedItemID = uniqueTabs.first.map { Self.displayItem(for: $0).id }
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
        selectItem(Self.displayItem(for: tab))
    }

    package func selectTab(withID tabID: WebInspectorTab.ID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return
        }
        selectTab(tab)
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
            self.selectedItemID = uniqueTabs.first.map { Self.displayItem(for: $0).id }
            return
        }
    }

    package func viewController<Content: UIViewController>(
        for key: WebInspectorTab.ContentKey,
        make: () -> Content
    ) -> Content {
        contentCache.viewController(for: key, make: make)
    }

    package func networkPanelModel(for context: WebInspectorContext) -> NetworkPanelModel {
        if let networkPanelModel,
           networkPanelModel.context === context {
            return networkPanelModel
        }

        let model = NetworkPanelModel(context: context)
        networkPanelModel = model
        return model
    }

    package func removeNetworkPanelModel() {
        networkPanelModel = nil
    }

    package func removeContextBoundContent() {
        removeNetworkPanelModel()
        removeContentCache()
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
        if let customTab = tabs.first(where: { tab in
            tab.builtIn == nil
                && WebInspectorTab.DisplayItem.customTabID(tab.id) == selectedItemID
        }) {
            return customTab
        }
        return tabs.first { $0.id == selectedSourceTabID }
    }

    private func isValidItemID(_ displayItemID: WebInspectorTab.DisplayItem.ID) -> Bool {
        if tabs.contains(where: { tab in
            tab.builtIn != nil && tab.id == displayItemID
        }) {
            return true
        }
        if tabs.contains(where: { tab in
            tab.builtIn == nil && WebInspectorTab.DisplayItem.customTabID(tab.id) == displayItemID
        }) {
            return true
        }
        return displayItemID == WebInspectorTab.DisplayItem.domElementID
            && tabs.contains(where: { $0.builtIn == .dom })
    }

    private static func displayItem(for tab: WebInspectorTab) -> WebInspectorTab.DisplayItem {
        if tab.builtIn != nil {
            return .tab(tab.id)
        }
        return .customTab(tab.id)
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
