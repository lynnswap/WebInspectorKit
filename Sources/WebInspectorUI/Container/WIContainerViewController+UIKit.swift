import ObservationBridge
import WebKit
import WebInspectorCore

#if canImport(UIKit)
import UIKit

@MainActor
private protocol WIUIKitTabHost where Self: UIViewController {
    func prepareForRemoval()
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
public final class WIContainerViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    public private(set) var sessionController: WISessionController

    private var requestedTabs: [WITab]
    private let synthesizedCompactElementTab = WITab.element()
    private let renderCache = WIUIKitTabRenderCache()
    private var sessionObservationHandles: Set<ObservationHandle> = []
    private var panelConfigurationObserverID: UUID?
    package private(set) var tabResolutionRevisionForTesting: UInt64 = 0
    package var onTabResolutionForTesting: (@MainActor (UInt64) -> Void)?

    private var activeHost: (UIViewController & WIUIKitTabHost)?
    private var activeHostKind: HostKind?

    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass?

    public init(
        _ sessionController: WISessionController,
        webView: WKWebView?,
        tabs: [WITab] = [.dom(), .network()]
    ) {
        self.sessionController = sessionController
        self.requestedTabs = tabs
        super.init(nibName: nil, bundle: nil)
        if let webView {
            sessionController.setPageWebViewFromUI(webView)
        }
        sessionController.configurePanels(tabs.map(\.configuration))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        if let panelConfigurationObserverID {
            sessionController.removePanelConfigurationObserver(panelConfigurationObserverID)
        }
    }

    public func setPageWebView(_ webView: WKWebView?) {
        sessionController.setPageWebViewFromUI(webView)
        if isViewLoaded {
            sessionController.activateFromUIIfPossible()
        }
    }

    public func setSessionController(_ sessionController: WISessionController) {
        guard self.sessionController !== sessionController else {
            return
        }

        let currentRequestedTabs = requestedTabs
        let currentSelectedPanel = self.sessionController.selectedPanelConfiguration
        let currentPageWebView = self.sessionController.pageWebViewForUI
        let previousController = self.sessionController
        if let panelConfigurationObserverID {
            previousController.removePanelConfigurationObserver(panelConfigurationObserverID)
            self.panelConfigurationObserverID = nil
        }
        renderCache.resetAll()
        previousController.disconnect()

        self.sessionController = sessionController
        sessionController.setPageWebViewFromUI(currentPageWebView)
        sessionController.configurePanels(currentRequestedTabs.map(\.configuration))
        sessionController.setSelectedPanelFromUI(currentSelectedPanel)
        bindSessionState()

        if isViewLoaded {
            synchronizeRequestedTabsFromControllerIfNeeded()
            rebuildLayout(forceHostReplacement: true)
            sessionController.activateFromUIIfPossible()
        }
    }

    public func setTabs(_ tabs: [WITab]) {
        requestedTabs = tabs
        sessionController.configurePanels(tabs.map(\.configuration))
        if isViewLoaded {
            rebuildLayout(forceHostReplacement: true)
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        bindSessionState()
        synchronizeRequestedTabsFromControllerIfNeeded()
        rebuildLayout(forceHostReplacement: true)

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.handleHorizontalSizeClassChange()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        sessionController.activateFromUIIfPossible()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            sessionController.suspend()
        }
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
        displayTabsForCurrentState().map(\.identifier)
    }

    var activeHostViewControllerForTesting: UIViewController? {
        activeHost
    }

    private var effectiveHorizontalSizeClass: UIUserInterfaceSizeClass {
        horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass
    }

    private func bindSessionState() {
        sessionObservationHandles.removeAll()
        if let panelConfigurationObserverID {
            sessionController.removePanelConfigurationObserver(panelConfigurationObserverID)
        }

        panelConfigurationObserverID = sessionController.addPanelConfigurationObserver { [weak self] in
            guard let self else {
                return
            }
            self.synchronizeRequestedTabsFromControllerIfNeeded()
            if self.isViewLoaded {
                self.rebuildLayout(forceHostReplacement: true)
            }
        }

        sessionController.observe(\.panelConfigurationRevision) { [weak self] _ in
            guard let self else {
                return
            }
            self.synchronizeRequestedTabsFromControllerIfNeeded()
            if self.isViewLoaded {
                self.rebuildLayout(forceHostReplacement: true)
            }
        }
        .store(in: &sessionObservationHandles)
    }

    private func synchronizeRequestedTabsFromControllerIfNeeded() {
        let panelConfigurations = sessionController.panelConfigurations
        guard requestedTabs.map(\.configuration) != panelConfigurations else {
            return
        }
        requestedTabs = WITab.projectedTabs(
            from: panelConfigurations,
            reusing: requestedTabs
        )
        tabResolutionRevisionForTesting &+= 1
        if tabResolutionRevisionForTesting == 0 {
            tabResolutionRevisionForTesting = 1
        }
        onTabResolutionForTesting?(tabResolutionRevisionForTesting)
    }

    private func rebuildLayout(forceHostReplacement: Bool = false) {
        let targetHostKind: HostKind = effectiveHorizontalSizeClass == .compact ? .compact : .regular
        let displayTabs = displayTabsForCurrentState()
        renderCache.prune(activeTabs: displayTabs)

        if activeHostKind == .compact, targetHostKind == .regular {
            // Compact UITab closures retain wrapped controllers; drop only compact caches
            // so regular host can reuse the shared root cache without cross-stack leakage.
            renderCache.resetCompactTabs()
        }

        if forceHostReplacement || activeHostKind != targetHostKind {
            installHost(of: targetHostKind, tabs: displayTabs)
        }
    }

    private func installHost(of kind: HostKind, tabs: [WITab]) {
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
                model: sessionController,
                tabs: tabs,
                renderCache: renderCache
            )
        case .regular:
            host = WIRegularTabHostViewController(
                model: sessionController,
                tabs: tabs,
                renderCache: renderCache
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

    private func displayTabsForCurrentState() -> [WITab] {
        guard effectiveHorizontalSizeClass == .compact else {
            return requestedTabs.filter { $0.panelKind != .domDetail }
        }

        let hasDOMTab = requestedTabs.contains { $0.panelKind == .domTree }
        let hasElementTab = requestedTabs.contains { $0.panelKind == .domDetail }
        guard hasDOMTab, hasElementTab == false else {
            return requestedTabs
        }

        var compactTabs = requestedTabs
        if let domIndex = compactTabs.firstIndex(where: { $0.panelKind == .domTree }) {
            compactTabs.insert(synthesizedCompactElementTab, at: domIndex + 1)
        } else {
            compactTabs.append(synthesizedCompactElementTab)
        }
        return compactTabs
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
            switch tab.panelKind {
            case .domTree:
                viewController = WIDOMViewController(store: sessionController.domStore)
            case .domDetail:
                viewController = WIDOMDetailViewController(store: sessionController.domStore)
            case .network:
                viewController = WINetworkViewController(store: sessionController.networkStore)
            case .custom:
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
#Preview("Tab Container (UIKit)") {
    let session = WISessionPreviewFixtures.makeSessionController()
    let previewWebView = WIDOMPreviewFixtures.bootstrapDOMTreeForPreview(session.domStore)
    WIDOMPreviewFixtures.applySampleSelection(to: session.domStore, mode: .selected)
    WINetworkPreviewFixtures.applySampleData(to: session.networkStore, mode: .detail)
    return WIContainerViewController(
        session,
        webView: previewWebView,
        tabs: [.dom(), .network()]
    )
}
#endif


#endif
