#if canImport(UIKit)
import Observation
import ObservationBridge
import OSLog
import SyntaxEditorUI
import UIHostingMenu
import UIKit
import WebKit
import WebInspectorDataKit
import WebInspectorUIBase

private let webInspectorSessionLifecycleLogger = Logger(
    subsystem: "com.lynnswap.WebInspectorKit",
    category: "WebInspectorKit.Lifecycle"
)

/// The presentation state that the built-in UI keeps for one inspector: the
/// tabs and their selection, the style of the inspected page, and the root
/// presentations that are showing the inspector.
///
/// The inspector owns its session, so the state outlives the view controllers
/// that present it. Use ``session(for:)`` to reach it.
@MainActor
@Observable
final class WebInspectorSession {
    /// Warms up observation, hosted menus, and syntax previews.
    ///
    /// The inspector UI works before this finishes: the dependencies prepare
    /// on first use, and hosted menus are empty until they are ready. Repeated
    /// and concurrent calls share each dependency's preparation.
    static func prepare() async throws {
        try await PortableObservationTracking.prepare()
        try await SyntaxEditorModel.prepare()
        try await UIHostingMenuRuntime.prepare()
    }

    private static var runtimePreparation: Task<Void, Never>?

    /// Starts ``prepare()`` once per process, without waiting for it.
    static func prepareRuntimesIfNeeded() {
        guard runtimePreparation == nil else {
            return
        }
        runtimePreparation = Task {
            do {
                try await prepare()
            } catch {
                webInspectorSessionLifecycleLogger.error(
                    "Inspector runtime preparation failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Returns the session of an inspector, creating it on first use.
    static func session(for inspector: WebInspector) -> WebInspectorSession {
        if let session = inspector.presentationStorage as? WebInspectorSession {
            return session
        }
        let session = WebInspectorSession(inspector: inspector, retainsInspector: false)
        inspector.presentationStorage = session
        return session
    }

    private struct RootPresentationRetirement {
        let attachmentGeneration: UInt64
        var detachesSession: Bool
    }

    let interface: InterfaceModel
    /// The user interface style inferred from the inspected page.
    ///
    /// The value is `.unspecified` until the page style is known or when no useful style can be inferred.
    private(set) var pageUserInterfaceStyle: UIUserInterfaceStyle = .unspecified
    /// The inspector owns a session made by ``session(for:)``, so that
    /// session refers back weakly.
    @ObservationIgnored private(set) weak var inspector: WebInspector?
    /// Keeps the inspector of a session that was made without one.
    @ObservationIgnored private let retainedInspector: WebInspector?
    @ObservationIgnored private lazy var releasedInspectorContext = WebInspectorContext.detached()
    @ObservationIgnored private var activeRootPresentationIDs: Set<UUID> = []
    @ObservationIgnored private var deferredRootPresentationRetirement: RootPresentationRetirement?
    @ObservationIgnored private let makePageUserInterfaceStyleObserver: @MainActor (
        WKWebView,
        @escaping @MainActor (UIUserInterfaceStyle) -> Void
    ) -> any WebInspectorPageUserInterfaceStyleObserving
    /// Replaces the page style observer of the next attachment in tests,
    /// which attach without a web view.
    @ObservationIgnored private var makePageUserInterfaceStyleObserverForNextAttachment: (@MainActor (
        @escaping @MainActor (UIUserInterfaceStyle) -> Void
    ) -> (any WebInspectorPageUserInterfaceStyleObserving)?)?
    @ObservationIgnored private var pageUserInterfaceStyleObserver: (any WebInspectorPageUserInterfaceStyleObserving)?
    #if DEBUG
    private(set) var detachCountForTesting = 0
    @ObservationIgnored private(set) var abandonmentRetirementTaskForTesting: Task<Void, Never>?
    #endif

    /// Creates a session that keeps its own inspector.
    convenience init(tabs: [WebInspectorTab] = [.dom, .network]) {
        self.init(inspector: WebInspector(), retainsInspector: true, tabs: tabs)
    }

    /// Creates a session that keeps its own inspector for `context`.
    convenience init(
        context: WebInspectorContext,
        tabs: [WebInspectorTab] = [.dom, .network],
        makePageUserInterfaceStyleObserver: @escaping @MainActor (
            WKWebView,
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> any WebInspectorPageUserInterfaceStyleObserving = { webView, apply in
            WebInspectorPageUserInterfaceStyleObserver(webView: webView, apply: apply)
        }
    ) {
        self.init(
            inspector: WebInspector(context: context),
            retainsInspector: true,
            tabs: tabs,
            makePageUserInterfaceStyleObserver: makePageUserInterfaceStyleObserver
        )
    }

    private init(
        inspector: WebInspector,
        retainsInspector: Bool,
        tabs: [WebInspectorTab] = [.dom, .network],
        makePageUserInterfaceStyleObserver: @escaping @MainActor (
            WKWebView,
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> any WebInspectorPageUserInterfaceStyleObserving = { webView, apply in
            WebInspectorPageUserInterfaceStyleObserver(webView: webView, apply: apply)
        }
    ) {
        self.interface = InterfaceModel(tabs: tabs)
        self.inspector = inspector
        self.retainedInspector = retainsInspector ? inspector : nil
        self.makePageUserInterfaceStyleObserver = makePageUserInterfaceStyleObserver
        inspector.attachmentWillChange = { [weak self] in
            // The style belongs to the page that is being left.
            self?.stopPageUserInterfaceStyleObservation()
        }
        inspector.contextDidChange = { [weak self] in
            self?.inspectorContextDidChange()
        }
        // The inspector can already be attached when its session is made.
        restartPageUserInterfaceStyleObservation()
    }

    isolated deinit {
        stopPageUserInterfaceStyleObservation()
    }

    /// The context of the inspector's current attachment.
    var context: WebInspectorContext {
        inspector?.context ?? releasedInspectorContext
    }

    func attachForTesting(
        makeContainer: @escaping @MainActor () async throws -> WebInspectorContainer,
        makePageUserInterfaceStyleObserver: @escaping @MainActor (
            @escaping @MainActor (UIUserInterfaceStyle) -> Void
        ) -> (any WebInspectorPageUserInterfaceStyleObserving)? = { _ in nil }
    ) async throws {
        guard let inspector else {
            throw CancellationError()
        }
        makePageUserInterfaceStyleObserverForNextAttachment = makePageUserInterfaceStyleObserver
        let wasApplied = try await inspector.attachAndWait(makeContainer: makeContainer)
        guard wasApplied else {
            // A later call replaced this one and owns the session state now.
            throw CancellationError()
        }
    }

    /// Detaches the inspector and waits until the call is applied.
    func detach() async {
        await detachAndReplaceContext()
    }

    private func detachAndReplaceContext() async {
        #if DEBUG
        detachCountForTesting += 1
        #endif
        await inspector?.detachAndWait()
    }

    /// Follows the inspector to its new context: content that was built for
    /// the previous one is evicted, and the page style is observed on the
    /// web view of the new attachment.
    private func inspectorContextDidChange() {
        interface.contextDidChange()
        restartPageUserInterfaceStyleObservation()
    }

    private func restartPageUserInterfaceStyleObservation() {
        stopPageUserInterfaceStyleObservation()
        let makeObserverForNextAttachment = makePageUserInterfaceStyleObserverForNextAttachment
        makePageUserInterfaceStyleObserverForNextAttachment = nil
        guard let inspector, inspector.context.state != .detached else {
            return
        }
        if let makeObserverForNextAttachment {
            startPageUserInterfaceStyleObservation(makeObserverForNextAttachment)
        } else if let webView = inspector.inspectedWebView {
            startPageUserInterfaceStyleObservation { [makePageUserInterfaceStyleObserver] apply in
                makePageUserInterfaceStyleObserver(webView, apply)
            }
        }
    }

    func beginRootPresentation(id: UUID) {
        activeRootPresentationIDs.insert(id)
    }

    func retireRootPresentation(id: UUID, detach: Bool) async {
        guard activeRootPresentationIDs.remove(id) != nil else {
            return
        }
        recordRootPresentationRetirement(detach: detach)
        guard activeRootPresentationIDs.isEmpty,
              let retirement = takeDeferredRootPresentationRetirement() else {
            return
        }
        await completeRootPresentationRetirement(retirement)
    }

    func abandonRootPresentation(id: UUID, detach: Bool) {
        guard activeRootPresentationIDs.remove(id) != nil else {
            return
        }
        recordRootPresentationRetirement(detach: detach)
        guard activeRootPresentationIDs.isEmpty,
              let retirement = takeDeferredRootPresentationRetirement() else {
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await completeRootPresentationRetirement(retirement)
        }
        #if DEBUG
        abandonmentRetirementTaskForTesting = task
        #endif
    }

    func retireRootPresentation(detach: Bool) async {
        guard activeRootPresentationIDs.isEmpty else {
            return
        }
        await completeRootPresentationRetirement(
            RootPresentationRetirement(
                attachmentGeneration: attachmentGeneration,
                detachesSession: detach
            )
        )
    }

    private func recordRootPresentationRetirement(detach: Bool) {
        mergeDeferredRootPresentationRetirement(
            RootPresentationRetirement(
                attachmentGeneration: attachmentGeneration,
                detachesSession: detach
            )
        )
    }

    private func mergeDeferredRootPresentationRetirement(
        _ retirement: RootPresentationRetirement
    ) {
        guard retirement.attachmentGeneration == attachmentGeneration else {
            return
        }
        guard var deferredRetirement = deferredRootPresentationRetirement,
              deferredRetirement.attachmentGeneration == attachmentGeneration else {
            deferredRootPresentationRetirement = retirement
            return
        }
        deferredRetirement.detachesSession = deferredRetirement.detachesSession
            || retirement.detachesSession
        deferredRootPresentationRetirement = deferredRetirement
    }

    private func takeDeferredRootPresentationRetirement() -> RootPresentationRetirement? {
        defer { deferredRootPresentationRetirement = nil }
        return deferredRootPresentationRetirement
    }

    private func completeRootPresentationRetirement(
        _ retirement: RootPresentationRetirement
    ) async {
        guard retirement.attachmentGeneration == attachmentGeneration else {
            return
        }
        guard activeRootPresentationIDs.isEmpty else {
            mergeDeferredRootPresentationRetirement(retirement)
            return
        }
        guard retirement.detachesSession else {
            await suspendBackendInteractionForPresentationEnd()
            return
        }
        await detachAndReplaceContext()
    }

    /// Mirrors the legacy presentation-end retirement: without tearing down the
    /// connection, disable the element picker and hide any visible highlight so
    /// a re-presentation starts from a clean interaction state.
    private func suspendBackendInteractionForPresentationEnd() async {
        // Bind the context once: a concurrent attach can replace it across
        // the awaits below, and this retirement must not touch the
        // replacement context.
        let context = context
        guard context.state == .attached else {
            return
        }
        do {
            try await context.dom.setElementPickerEnabled(false)
        } catch {
            webInspectorSessionLifecycleLogger.error(
                "Element picker cleanup failed: \(String(describing: error), privacy: .public)"
            )
        }
        do {
            try await context.dom.hideHighlight()
        } catch {
            webInspectorSessionLifecycleLogger.error(
                "DOM highlight cleanup failed: \(String(describing: error), privacy: .public)"
            )
        }
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

    /// The number of attach and detach calls so far. A root presentation
    /// that ended before the latest call no longer decides what happens to
    /// the attachment.
    private var attachmentGeneration: UInt64 {
        inspector?.requestCount ?? 0
    }

    func installDataContext(_ context: WebInspectorContext) {
        inspector?.install(context)
    }
}

#if DEBUG
extension WebInspectorSession {
    var hasPageUserInterfaceStyleObserverForTesting: Bool {
        pageUserInterfaceStyleObserver != nil
    }
}
#endif

@MainActor
@Observable
final class InterfaceModel {
    private(set) var tabs: [WebInspectorTab]
    private(set) var selectedItemID: WebInspectorTab.DisplayItem.ID?
    private(set) var contextBoundContentRevision = 0
    @ObservationIgnored private let projection = WebInspectorTab.DisplayProjection()

    init(tabs: [WebInspectorTab] = [.dom, .network]) {
        let uniqueTabs = Self.uniqueTabs(tabs)
        self.tabs = uniqueTabs
        selectedItemID = uniqueTabs.first.map { Self.displayItem(for: $0).id }
    }

    func displayItems(for hostLayout: WebInspectorTab.HostLayout) -> [WebInspectorTab.DisplayItem] {
        projection.displayItems(for: hostLayout, tabs: tabs)
    }

    func resolvedSelection(for hostLayout: WebInspectorTab.HostLayout) -> WebInspectorTab.DisplayItem? {
        projection.resolvedSelection(
            for: hostLayout,
            tabs: tabs,
            selectedItemID: selectedItemID
        )
    }

    func descriptor(for displayItem: WebInspectorTab.DisplayItem) -> WebInspectorTab.DisplayDescriptor? {
        projection.descriptor(for: displayItem, tabs: tabs)
    }

    func selectTab(_ tab: WebInspectorTab) {
        guard tabs.contains(tab) else {
            return
        }
        selectItem(Self.displayItem(for: tab))
    }

    func selectTab(withID tabID: WebInspectorTab.ID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return
        }
        selectTab(tab)
    }

    func selectItem(_ displayItem: WebInspectorTab.DisplayItem) {
        guard isValidItemID(displayItem.id),
              selectedItemID != displayItem.id else {
            return
        }
        selectedItemID = displayItem.id
    }

    func selectItem(withID displayItemID: WebInspectorTab.DisplayItem.ID) {
        guard isValidItemID(displayItemID),
              selectedItemID != displayItemID else {
            return
        }
        selectedItemID = displayItemID
    }

    func setTabs(_ tabs: [WebInspectorTab]) {
        let uniqueTabs = Self.uniqueTabs(tabs)
        self.tabs = uniqueTabs
        guard let selectedItemID,
              isValidItemID(selectedItemID) else {
            self.selectedItemID = uniqueTabs.first.map { Self.displayItem(for: $0).id }
            return
        }
    }

    func contextDidChange() {
        contextBoundContentRevision &+= 1
    }

    /// Replaces the tabs of an inspector that may already be on screen.
    ///
    /// Tabs are equal by ID, so a tab with a known ID can still bring another
    /// title or factory. Advancing the content revision makes every host
    /// rebuild its tab items and evict the content it built for the previous
    /// tabs.
    func replaceTabs(_ tabs: [WebInspectorTab]) {
        setTabs(tabs)
        contextBoundContentRevision &+= 1
    }

    func reachableContentKeys() -> Set<WebInspectorTab.ContentKey> {
        projection.contentKeys(for: .compact, tabs: tabs)
            .union(projection.contentKeys(for: .regular, tabs: tabs))
    }

    var selectedTab: WebInspectorTab? {
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

#if canImport(UIKit)
extension WebInspector {
    /// The user interface style inferred from the page that the inspector is
    /// attached to.
    ///
    /// The value is `.unspecified` until the page style is known, when no
    /// useful style can be inferred, and while the inspector is detached.
    /// Use it to match the appearance of the UI that presents the inspector
    /// to the page.
    public var pageUserInterfaceStyle: UIUserInterfaceStyle {
        WebInspectorSession.session(for: self).pageUserInterfaceStyle
    }
}
#endif
