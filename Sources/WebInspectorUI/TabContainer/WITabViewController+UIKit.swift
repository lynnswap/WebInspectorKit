import WebKit
import WebInspectorRuntime

#if canImport(UIKit)
import UIKit

@MainActor
private protocol WIUIKitTabHost where Self: UIViewController {
    func prepareForRemoval()
}

@MainActor
func wiCompactDisplayTabs(
    from tabs: [WITab],
    synthesizedElementTab: WITab
) -> [WITab] {
    let hasDOMTab = tabs.contains { $0.identifier == WITab.domTabID }
    let hasElementTab = tabs.contains { $0.identifier == WITab.elementTabID }
    guard hasDOMTab, hasElementTab == false else {
        return tabs
    }

    var displayTabs: [WITab] = []
    displayTabs.reserveCapacity(tabs.count + 1)
    var didInsertSyntheticElement = false
    for tab in tabs {
        displayTabs.append(tab)
        guard didInsertSyntheticElement == false, tab.identifier == WITab.domTabID else {
            continue
        }
        displayTabs.append(synthesizedElementTab)
        didInsertSyntheticElement = true
    }
    return displayTabs
}

@MainActor
final class WIUIKitTabRenderCache {
    private var rootViewControllerByTabID: [ObjectIdentifier: UIViewController] = [:]
    private var compactTabByTabID: [ObjectIdentifier: UITab] = [:]
    private var modelTabIDByCompactTabID: [ObjectIdentifier: ObjectIdentifier] = [:]

    func rootViewController(for tab: WITab) -> UIViewController? {
        rootViewControllerByTabID[ObjectIdentifier(tab)]
    }

    func setRootViewController(_ viewController: UIViewController, for tab: WITab) {
        rootViewControllerByTabID[ObjectIdentifier(tab)] = viewController
    }

    func compactTab(for tab: WITab) -> UITab? {
        compactTabByTabID[ObjectIdentifier(tab)]
    }

    func setCompactTab(_ compactTab: UITab, for tab: WITab) {
        let tabID = ObjectIdentifier(tab)
        if let previousCompactTab = compactTabByTabID[tabID] {
            modelTabIDByCompactTabID.removeValue(forKey: ObjectIdentifier(previousCompactTab))
        }
        compactTabByTabID[tabID] = compactTab
        modelTabIDByCompactTabID[ObjectIdentifier(compactTab)] = tabID
    }

    func modelTab(for compactTab: UITab, among tabs: [WITab]) -> WITab? {
        guard let modelTabID = modelTabIDByCompactTabID[ObjectIdentifier(compactTab)] else {
            return nil
        }
        return tabs.first(where: { ObjectIdentifier($0) == modelTabID })
    }

    func prune(activeTabs: [WITab]) {
        let activeTabIDs = Set(activeTabs.map { ObjectIdentifier($0) })
        rootViewControllerByTabID = rootViewControllerByTabID.filter { activeTabIDs.contains($0.key) }
        compactTabByTabID = compactTabByTabID.filter { activeTabIDs.contains($0.key) }

        let activeCompactTabIDs = Set(compactTabByTabID.values.map { ObjectIdentifier($0) })
        modelTabIDByCompactTabID = modelTabIDByCompactTabID.filter { activeCompactTabIDs.contains($0.key) }
    }

    func resetAll() {
        rootViewControllerByTabID.removeAll()
        compactTabByTabID.removeAll()
        modelTabIDByCompactTabID.removeAll()
    }

    func resetCompactTabs() {
        compactTabByTabID.removeAll()
        modelTabIDByCompactTabID.removeAll()
    }
}

@MainActor
public final class WITabViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    private final class ControllerSwapRequest {}

    public private(set) var inspectorController: WIInspectorController

    private var requestedTabs: [WITab]
    private var requestedPageWebView: WKWebView?
    private let renderCache = WIUIKitTabRenderCache()
    private var controllerSwapTask: Task<Void, Never>?
    private var activeControllerSwapRequest: ControllerSwapRequest?
    private var uiStateApplyTask: Task<Void, Never>?
    private var runtimeStateSyncPending = false
    private var needsRuntimeStateSyncAfterSwap = false
    private var shouldDriveRuntimeStateFromUI = false

    private var activeHost: (UIViewController & WIUIKitTabHost)?
    private var activeHostKind: HostKind?
    private var model: WIModel { inspectorController.model }

    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass? {
        didSet {
            if isViewLoaded {
                handleHorizontalSizeClassChange()
            }
        }
    }

    public init(
        _ inspectorController: WIInspectorController,
        webView: WKWebView?,
        tabs: [WITab] = [.dom(), .network()]
    ) {
        self.inspectorController = inspectorController
        self.requestedTabs = tabs
        self.requestedPageWebView = webView
        super.init(nibName: nil, bundle: nil)
        inspectorController.model.setTabsFromUI(tabs)
    }

    public convenience init(
        _ model: WIModel,
        webView: WKWebView?,
        tabs: [WITab] = [.dom(), .network()]
    ) {
        self.init(WIInspectorController(model: model), webView: webView, tabs: tabs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public func setPageWebView(_ webView: WKWebView?) {
        requestedPageWebView = webView
        if isViewLoaded {
            scheduleRuntimeStateSync()
        }
    }

    public func setInspectorController(_ inspectorController: WIInspectorController) {
        guard self.inspectorController !== inspectorController else {
            return
        }

        let currentSelectedTab = model.selectedTab
        let currentPreferredCompactSelectedTabIdentifier = model.preferredCompactSelectedTabIdentifier
        let currentHasExplicitTabsConfiguration = model.hasExplicitTabsConfiguration
        let previousController = self.inspectorController
        let activeUIStateApplyTask = uiStateApplyTask
        uiStateApplyTask = nil
        runtimeStateSyncPending = false
        controllerSwapTask?.cancel()
        invalidatePresentationStateForControllerSwap()
        let request = ControllerSwapRequest()
        activeControllerSwapRequest = request
        controllerSwapTask = Task { [weak self, request] in
            defer {
                if let self, self.activeControllerSwapRequest === request {
                    self.controllerSwapTask = nil
                    self.activeControllerSwapRequest = nil
                    if self.needsRuntimeStateSyncAfterSwap {
                        self.needsRuntimeStateSyncAfterSwap = false
                        self.scheduleRuntimeStateSync()
                    }
                }
            }
            await activeUIStateApplyTask?.value
            await previousController.finalize()
            guard
                let self,
                Task.isCancelled == false,
                self.activeControllerSwapRequest === request,
                self.inspectorController === previousController
            else {
                return
            }
            let currentRequestedTabs = self.requestedTabs
            let currentPageWebView = self.requestedPageWebView
            self.applyInspectorController(
                inspectorController,
                requestedTabs: currentRequestedTabs,
                tabsExplicitlyConfigured: currentHasExplicitTabsConfiguration,
                selectedTab: currentSelectedTab,
                preferredCompactSelectedTabIdentifier: currentPreferredCompactSelectedTabIdentifier,
                pageWebView: currentPageWebView,
                syncRuntimeState: false
            )
            await inspectorController.applyHostState(
                pageWebView: currentPageWebView,
                visibility: self.shouldDriveRuntimeStateFromUI ? .visible : .hidden
            )
        }
    }

    private func invalidatePresentationStateForControllerSwap() {
        renderCache.resetAll()
        if let activeHost {
            activeHost.prepareForRemoval()
            activeHost.willMove(toParent: nil)
            activeHost.view.removeFromSuperview()
            activeHost.removeFromParent()
        }
        activeHost = nil
        activeHostKind = nil
    }

    public func setInspectorController(_ model: WIModel) {
        setInspectorController(WIInspectorController(model: model))
    }

    public func setTabs(_ tabs: [WITab]) {
        requestedTabs = tabs
        model.setTabsFromUI(tabs)
        scheduleRuntimeStateSync()
        if isViewLoaded {
            rebuildLayout()
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        rebuildLayout(forceHostReplacement: true)

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.handleHorizontalSizeClassChange()
        }
    }

    private func applyInspectorController(
        _ inspectorController: WIInspectorController,
        requestedTabs: [WITab],
        tabsExplicitlyConfigured: Bool,
        selectedTab: WITab?,
        preferredCompactSelectedTabIdentifier: String?,
        pageWebView: WKWebView?,
        syncRuntimeState: Bool
    ) {
        renderCache.resetAll()
        self.inspectorController = inspectorController
        self.requestedTabs = requestedTabs
        self.requestedPageWebView = pageWebView
        let model = inspectorController.model
        model.setTabsFromUI(
            requestedTabs,
            marksExplicitConfiguration: tabsExplicitlyConfigured
        )
        model.setPreferredCompactSelectedTabIdentifierFromUI(preferredCompactSelectedTabIdentifier)
        if let selectedTab {
            _ = model.projectSelectedTabFromUI(selectedTab)
        }

        guard isViewLoaded else {
            return
        }

        rebuildLayout(forceHostReplacement: true)
        _ = syncRuntimeState
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        shouldDriveRuntimeStateFromUI = true
        scheduleRuntimeStateSync()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard view.window == nil else {
            return
        }
        shouldDriveRuntimeStateFromUI = false
        if isViewLoaded {
            scheduleRuntimeStateSync()
        }
    }

    isolated deinit {
        controllerSwapTask?.cancel()
        uiStateApplyTask?.cancel()
    }

    private func scheduleRuntimeStateSync() {
        guard controllerSwapTask == nil else {
            needsRuntimeStateSyncAfterSwap = true
            return
        }
        runtimeStateSyncPending = true
        guard uiStateApplyTask == nil else {
            return
        }
        var applyTask: Task<Void, Never>?
        applyTask = Task.immediateIfAvailable { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.uiStateApplyTask = nil
                if self.runtimeStateSyncPending {
                    self.scheduleRuntimeStateSync()
                }
            }
            while self.runtimeStateSyncPending {
                self.runtimeStateSyncPending = false
                let inspectorController = self.inspectorController
                await inspectorController.applyHostState(
                    pageWebView: self.requestedPageWebView,
                    visibility: self.shouldDriveRuntimeStateFromUI ? .visible : .hidden
                )
            }
        }
        uiStateApplyTask = applyTask
    }

    var activeHostKindForTesting: String? {
        switch activeHostKind {
        case .compact:
            return "compact"
        case .regular:
            return "regular"
        case nil:
            return nil
        }
    }

    var resolvedTabIDsForTesting: [String] {
        model.tabs.map(\.identifier)
    }

    var activeHostViewControllerForTesting: UIViewController? {
        activeHost
    }

    private var effectiveHorizontalSizeClass: UIUserInterfaceSizeClass {
        horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass
    }

    private func rebuildLayout(forceHostReplacement: Bool = false) {
        renderCache.prune(activeTabs: model.tabs)

        let targetHostKind: HostKind = effectiveHorizontalSizeClass == .compact ? .compact : .regular

        if activeHostKind == .compact, targetHostKind == .regular {
            // Compact UITab closures retain wrapped controllers; drop only compact caches
            // so regular host can reuse the shared root cache without cross-stack leakage.
            renderCache.resetCompactTabs()
        }

        if forceHostReplacement || activeHostKind != targetHostKind {
            installHost(of: targetHostKind)
        }
    }

    private func installHost(of kind: HostKind) {
        if let activeHost {
            activeHost.prepareForRemoval()
            activeHost.willMove(toParent: nil)
            activeHost.view.removeFromSuperview()
            activeHost.removeFromParent()
        }

        let host: UIViewController & WIUIKitTabHost
        switch kind {
        case .compact:
            host = WICompactTabHostViewController(
                model: model,
                inspector: inspectorController,
                renderCache: renderCache,
                onSelectionChange: { [weak self] in self?.scheduleRuntimeStateSync() }
            )
        case .regular:
            host = WIRegularTabHostViewController(
                model: model,
                inspector: inspectorController,
                renderCache: renderCache,
                onSelectionChange: { [weak self] in self?.scheduleRuntimeStateSync() }
            )
        }

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        activeHost = host
        activeHostKind = kind
    }

    private func handleHorizontalSizeClassChange() {
        rebuildLayout()
    }

    func makeTabRootViewController(for tab: WITab) -> UIViewController? {
        if let cached = renderCache.rootViewController(for: tab) {
            applyHorizontalSizeClassOverrideIfNeeded(to: cached)
            return cached
        }

        let viewController: UIViewController?
        if let customViewController = tab.viewControllerProvider?(tab) {
            viewController = customViewController
        } else {
            switch tab.identifier {
            case WITab.domTabID:
                viewController = WIDOMViewController(inspector: inspectorController.dom)
            case WITab.elementTabID:
                viewController = WIDOMDetailViewController(inspector: inspectorController.dom)
            case WITab.networkTabID:
                viewController = WINetworkViewController(inspector: inspectorController.network)
            default:
                viewController = nil
            }
        }

        guard let viewController else {
            return nil
        }
        applyHorizontalSizeClassOverrideIfNeeded(to: viewController)
        renderCache.setRootViewController(viewController, for: tab)
        return viewController
    }

    private func applyHorizontalSizeClassOverrideIfNeeded(to viewController: UIViewController) {
        if let domViewController = viewController as? WIDOMViewController {
            domViewController.horizontalSizeClassOverrideForTesting = effectiveHorizontalSizeClass
        }
        if let networkViewController = viewController as? WINetworkViewController {
            networkViewController.horizontalSizeClassOverrideForTesting = effectiveHorizontalSizeClass
        }
    }
}

extension WICompactTabHostViewController: WIUIKitTabHost {}
extension WIRegularTabHostViewController: WIUIKitTabHost {}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

extension WITabViewController {
    func waitForRuntimeStateSyncForTesting() async {
        await controllerSwapTask?.value
        await uiStateApplyTask?.value
    }
}

#Preview("Tab Container (UIKit)") {
    WIUIKitPreviewContainer {
        let session = WIInspectorController()
        WIDOMPreviewFixtures.applySampleSelection(to: session.dom, mode: .selected)
        let previewWebView = WIDOMPreviewFixtures.bootstrapDOMTreeForPreview(session.dom)
        WINetworkPreviewFixtures.applySampleData(to: session.network, mode: .detail)
        return WITabViewController(
            session,
            webView: previewWebView,
            tabs: [.dom(), .network()]
        )
    }
}
#endif


#endif
