#if canImport(UIKit)
import Observation
import UIKit
import WebKit
import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorUIBase

/// The UIKit-facing inspection session used by `WebInspectorViewController`.
///
/// A session owns one model container, its stable main context, attachment
/// lifecycle, and page-derived presentation preferences.
@MainActor
@Observable
public final class WebInspectorSession {
    package let interface: InterfaceModel
    /// The container that owns the inspector connection and model contexts.
    @ObservationIgnored public let modelContainer: WebInspectorModelContainer
    /// The stable semantic model used by built-in and custom tabs.
    @ObservationIgnored public let model: WebInspectorModelContext
    /// The user interface style inferred from the inspected page.
    ///
    /// The value is `.unspecified` until the page style is known or when no useful style can be inferred.
    public private(set) var pageUserInterfaceStyle: UIUserInterfaceStyle = .unspecified
    @ObservationIgnored private var attachmentGeneration: UInt64 = 0
    @ObservationIgnored private let makePageUserInterfaceStyleObserver: @MainActor (
        WKWebView,
        @escaping @MainActor (UIUserInterfaceStyle) -> Void
    ) -> any WebInspectorPageUserInterfaceStyleObserving
    @ObservationIgnored private var pageUserInterfaceStyleObserver: (any WebInspectorPageUserInterfaceStyleObserving)?
    #if DEBUG
    package private(set) var detachCountForTesting = 0
    #endif

    /// Creates a session with the provided inspector tabs.
    public init(
        tabs: [WebInspectorTab] = [.dom, .network],
        additionalDomains: Set<WebInspectorModelContainer.Domain> = []
    ) {
        let domains = tabs.reduce(into: additionalDomains) { domains, tab in
            domains.formUnion(tab.requiredDomains)
        }
        let modelContainer = WebInspectorModelContainer(
            configuration: .init(domains: domains)
        )
        self.interface = InterfaceModel(tabs: tabs)
        self.modelContainer = modelContainer
        self.model = modelContainer.mainContext
        self.makePageUserInterfaceStyleObserver = { webView, apply in
            WebInspectorPageUserInterfaceStyleObserver(webView: webView, apply: apply)
        }
    }

    package init(
        modelContainer: WebInspectorModelContainer,
        tabs: [WebInspectorTab] = [.dom, .network],
        makePageUserInterfaceStyleObserver: @escaping @MainActor (
            WKWebView,
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> any WebInspectorPageUserInterfaceStyleObserving = { webView, apply in
            WebInspectorPageUserInterfaceStyleObserver(webView: webView, apply: apply)
        }
    ) {
        self.interface = InterfaceModel(tabs: tabs)
        self.modelContainer = modelContainer
        self.model = modelContainer.mainContext
        self.makePageUserInterfaceStyleObserver = makePageUserInterfaceStyleObserver
    }

    isolated deinit {
        stopPageUserInterfaceStyleObservation()
    }

    /// Attaches the session to a web view.
    ///
    /// Reattachment preserves model and result identity while replacing the
    /// exclusively owned ProxyKit connection.
    public func attach(to webView: WKWebView) async throws {
        try await attach(
            makeProxy: {
                try await WebInspectorProxy(attachingTo: webView)
            },
            makePageUserInterfaceStyleObserver: { [makePageUserInterfaceStyleObserver] apply in
                makePageUserInterfaceStyleObserver(webView, apply)
            }
        )
    }

    package func attach(
        to webView: WKWebView,
        makeProxy: @escaping @MainActor @Sendable (WKWebView) async throws
            -> WebInspectorProxy
    ) async throws {
        try await attach(
            makeProxy: {
                try await makeProxy(webView)
            },
            makePageUserInterfaceStyleObserver: { [makePageUserInterfaceStyleObserver] apply in
                makePageUserInterfaceStyleObserver(webView, apply)
            }
        )
    }

    package func attachForTesting(
        makeProxy: @escaping @MainActor @Sendable () async throws
            -> WebInspectorProxy,
        makePageUserInterfaceStyleObserver: @escaping @MainActor (
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> (any WebInspectorPageUserInterfaceStyleObserving)? = { _ in nil },
        afterModelAttach: (@MainActor () async -> Void)? = nil
    ) async throws {
        try await attach(
            makeProxy: makeProxy,
            makePageUserInterfaceStyleObserver: makePageUserInterfaceStyleObserver,
            afterModelAttach: afterModelAttach
        )
    }

    private func attach(
        makeProxy: @escaping @MainActor @Sendable () async throws
            -> WebInspectorProxy,
        makePageUserInterfaceStyleObserver: @MainActor (
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> (any WebInspectorPageUserInterfaceStyleObserving)?,
        afterModelAttach: (@MainActor () async -> Void)? = nil
    ) async throws {
        let generation = advanceAttachmentGeneration()
        stopPageUserInterfaceStyleObservation()
        try Task.checkCancellation()
        guard isCurrentAttachmentGeneration(generation) else {
            throw CancellationError()
        }
        do {
            try await modelContainer.attach(makeProxy: makeProxy)
            if let afterModelAttach {
                await afterModelAttach()
            }
            guard isCurrentAttachmentGeneration(generation) else {
                throw CancellationError()
            }
            startPageUserInterfaceStyleObservation(makePageUserInterfaceStyleObserver)
        } catch {
            guard isCurrentAttachmentGeneration(generation) else {
                throw CancellationError()
            }
            stopPageUserInterfaceStyleObservation()
            throw error
        }
    }

    /// Detaches the session while preserving its model identity for reuse.
    public func detach() async {
        await detachModel()
    }

    private func detachModel() async {
        advanceAttachmentGeneration()
        #if DEBUG
        detachCountForTesting += 1
        #endif
        stopPageUserInterfaceStyleObservation()
        await modelContainer.detach()
    }

    /// Permanently closes this session and its model connection.
    public func close() async {
        advanceAttachmentGeneration()
        stopPageUserInterfaceStyleObservation()
        await modelContainer.close()
    }

    /// Disables transient page interaction without tearing down the connection.
    package func suspendBackendInteraction() async throws {
        guard modelContainer.state == .attached else {
            return
        }
        guard model.configuredDomains.contains(.dom) else {
            return
        }

        try await model.hideDOMHighlight()
    }

    private func startPageUserInterfaceStyleObservation(
        _ makeObserver: @MainActor (
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> (any WebInspectorPageUserInterfaceStyleObserving)?
    ) {
        guard let observer = makeObserver({ [weak self] style in
            self?.setPageUserInterfaceStyle(style)
        }) else {
            return
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
    package let tabs: [WebInspectorTab]
    package private(set) var selectedItemID: WebInspectorTab.DisplayItem.ID?
    @ObservationIgnored private let projection = WebInspectorTab.DisplayProjection()

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
