#if canImport(UIKit)
import Observation
import UIKit
import WebKit
import WebInspectorDataKit
import WebInspectorUIBase

/// The UIKit-facing inspection session used by `WebInspectorViewController`.
///
/// A session owns attachment lifecycle, the current DataKit context, and
/// page-derived presentation preferences.
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
    package private(set) var detachCountForTesting = 0
    #endif

    /// Creates a session with the provided inspector tabs.
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
    }

    package var context: WebInspectorContext {
        dataContext
    }

    /// Attaches the session to a web view.
    ///
    /// Attaching replaces any previous inspection context owned by this
    /// session.
    public func attach(to webView: WKWebView) async throws {
        try await attach(
            makeContainer: {
                try await WebInspectorContainer(attachingTo: webView)
            },
            makePageUserInterfaceStyleObserver: { [makePageUserInterfaceStyleObserver] apply in
                makePageUserInterfaceStyleObserver(webView, apply)
            }
        )
    }

    package func attach(
        to webView: WKWebView,
        makeContainer: @MainActor (WKWebView) async throws -> WebInspectorContainer
    ) async throws {
        try await attach(
            makeContainer: {
                try await makeContainer(webView)
            },
            makePageUserInterfaceStyleObserver: { [makePageUserInterfaceStyleObserver] apply in
                makePageUserInterfaceStyleObserver(webView, apply)
            }
        )
    }

    package func attachForTesting(
        makeContainer: @escaping @MainActor () async throws -> WebInspectorContainer,
        makePageUserInterfaceStyleObserver: @escaping @MainActor (
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> (any WebInspectorPageUserInterfaceStyleObserving)? = { _ in nil }
    ) async throws {
        try await attach(
            makeContainer: makeContainer,
            makePageUserInterfaceStyleObserver: makePageUserInterfaceStyleObserver
        )
    }

    private func attach(
        makeContainer: @MainActor () async throws -> WebInspectorContainer,
        makePageUserInterfaceStyleObserver: @MainActor (
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> (any WebInspectorPageUserInterfaceStyleObserving)?
    ) async throws {
        let generation = advanceAttachmentGeneration()
        stopPageUserInterfaceStyleObservation()
        await stopContainer(replaceContextWithDetached: false)
        try Task.checkCancellation()
        guard isCurrentAttachmentGeneration(generation) else {
            throw CancellationError()
        }
        do {
            let container = try await makeContainer()
            try Task.checkCancellation()
            guard isCurrentAttachmentGeneration(generation) else {
                await container.close()
                throw CancellationError()
            }
            self.container = container
            installDataContext(container.mainContext)
            startPageUserInterfaceStyleObservation(makePageUserInterfaceStyleObserver)
        } catch {
            guard isCurrentAttachmentGeneration(generation) else {
                throw error
            }
            installDataContext(Self.makeDetachedDataContext())
            stopPageUserInterfaceStyleObservation()
            throw error
        }
    }

    /// Detaches the session and replaces the current context with a detached
    /// placeholder context.
    public func detach() async {
        await detachAndReplaceContext()
    }

    private func detachAndReplaceContext() async {
        advanceAttachmentGeneration()
        #if DEBUG
        detachCountForTesting += 1
        #endif
        stopPageUserInterfaceStyleObservation()
        await stopContainer(replaceContextWithDetached: true)
    }

    /// Disables transient page interaction without tearing down the connection.
    package func suspendBackendInteraction() async {
        // Bind the context once: a concurrent attach can swap dataContext
        // across the awaits below, and this retirement must not touch the
        // replacement context.
        let context = dataContext
        guard context.status.state == .attached else {
            return
        }
        if context.isElementPickerEnabled {
            try? await context.setElementPickerEnabled(false)
        }
        try? await context.hideHighlight()
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

    package func installDataContext(_ context: WebInspectorContext) {
        dataContext = context
        interface.contextDidChange()
    }

    private func stopContainer(replaceContextWithDetached: Bool) async {
        interface.contextDidChange()
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
    package let tabs: [WebInspectorTab]
    package private(set) var selectedItemID: WebInspectorTab.DisplayItem.ID?
    package private(set) var contextBoundContentRevision = 0
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

    package func contextDidChange() {
        precondition(
            contextBoundContentRevision < Int.max,
            "A presentation content revision must not overflow."
        )
        contextBoundContentRevision += 1
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
