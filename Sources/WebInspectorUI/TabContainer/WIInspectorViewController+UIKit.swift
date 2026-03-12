import ObservationBridge
import WebKit
import WebInspectorShell

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

    func rootViewController(for tab: WIInspectorTab) -> UIViewController? {
        rootViewControllerByTabID[ObjectIdentifier(tab)]
    }

    func setRootViewController(_ viewController: UIViewController, for tab: WIInspectorTab) {
        rootViewControllerByTabID[ObjectIdentifier(tab)] = viewController
    }

    func compactTab(for tab: WIInspectorTab) -> UITab? {
        compactTabByTabID[ObjectIdentifier(tab)]
    }

    func setCompactTab(_ compactTab: UITab, for tab: WIInspectorTab) {
        let tabID = ObjectIdentifier(tab)
        if let previousCompactTab = compactTabByTabID[tabID] {
            modelTabIDByCompactTabID.removeValue(forKey: ObjectIdentifier(previousCompactTab))
        }
        compactTabByTabID[tabID] = compactTab
        modelTabIDByCompactTabID[ObjectIdentifier(compactTab)] = tabID
    }

    func modelTab(for compactTab: UITab, among tabs: [WIInspectorTab]) -> WIInspectorTab? {
        guard let modelTabID = modelTabIDByCompactTabID[ObjectIdentifier(compactTab)] else {
            return nil
        }
        return tabs.first(where: { ObjectIdentifier($0) == modelTabID })
    }

    func prune(activeTabs: [WIInspectorTab]) {
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
public final class WIInspectorViewController: UIViewController {
    private enum HostKind {
        case compact
        case regular
    }

    public private(set) var inspectorController: WIInspectorController

    private var requestedTabs: [WIInspectorTab]
    private let renderCache = WIUIKitTabRenderCache()
    private var sessionObservationHandles: Set<ObservationHandle> = []
    private var panelConfigurationObserverID: UUID?
    package private(set) var tabResolutionRevisionForTesting: UInt64 = 0
    package var onTabResolutionForTesting: (@MainActor (UInt64) -> Void)?

    private var activeHost: (UIViewController & WIUIKitTabHost)?
    private var activeHostKind: HostKind?

    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass?

    public init(
        _ inspectorController: WIInspectorController,
        webView: WKWebView?,
        tabs: [WIInspectorTab] = [.dom(), .network()]
    ) {
        self.inspectorController = inspectorController
        self.requestedTabs = tabs
        super.init(nibName: nil, bundle: nil)
        if let webView {
            inspectorController.setPageWebViewFromUI(webView)
        }
        inspectorController.configurePanels(tabs.map(\.configuration))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        if let panelConfigurationObserverID {
            inspectorController.removePanelConfigurationObserver(panelConfigurationObserverID)
        }
    }

    public func setPageWebView(_ webView: WKWebView?) {
        inspectorController.setPageWebViewFromUI(webView)
        if isViewLoaded {
            inspectorController.activateFromUIIfPossible()
        }
    }

    public func setInspectorController(_ inspectorController: WIInspectorController) {
        guard self.inspectorController !== inspectorController else {
            return
        }

        let currentRequestedTabs = requestedTabs
        let currentSelectedPanel = self.inspectorController.selectedPanelConfiguration
        let currentPageWebView = self.inspectorController.pageWebViewForUI
        let previousController = self.inspectorController
        if let panelConfigurationObserverID {
            previousController.removePanelConfigurationObserver(panelConfigurationObserverID)
            self.panelConfigurationObserverID = nil
        }
        renderCache.resetAll()
        previousController.disconnect()

        self.inspectorController = inspectorController
        inspectorController.setPageWebViewFromUI(currentPageWebView)
        inspectorController.configurePanels(currentRequestedTabs.map(\.configuration))
        inspectorController.setSelectedPanelFromUI(currentSelectedPanel)
        bindSessionState()

        if isViewLoaded {
            synchronizeRequestedTabsFromControllerIfNeeded()
            rebuildLayout(forceHostReplacement: true)
            inspectorController.activateFromUIIfPossible()
        }
    }

    public func setTabs(_ tabs: [WIInspectorTab]) {
        requestedTabs = tabs
        inspectorController.configurePanels(tabs.map(\.configuration))
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
        inspectorController.activateFromUIIfPossible()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            inspectorController.suspend()
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
        requestedTabs.map(\.identifier)
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
            inspectorController.removePanelConfigurationObserver(panelConfigurationObserverID)
        }

        panelConfigurationObserverID = inspectorController.addPanelConfigurationObserver { [weak self] in
            guard let self else {
                return
            }
            self.synchronizeRequestedTabsFromControllerIfNeeded()
            if self.isViewLoaded {
                self.rebuildLayout(forceHostReplacement: true)
            }
        }

        inspectorController.observe(\.panelConfigurationRevision) { [weak self] _ in
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
        let panelConfigurations = inspectorController.panelConfigurations
        guard requestedTabs.map(\.configuration) != panelConfigurations else {
            return
        }
        requestedTabs = WIInspectorTab.projectedTabs(
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
        renderCache.prune(activeTabs: requestedTabs)

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
                model: inspectorController,
                tabs: requestedTabs,
                renderCache: renderCache
            )
        case .regular:
            host = WIRegularTabHostViewController(
                model: inspectorController,
                tabs: requestedTabs,
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

    func makeTabRootViewController(for tab: WIInspectorTab) -> UIViewController? {
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
                viewController = WIDOMViewController(inspector: inspectorController.dom)
            case .domDetail:
                viewController = WIDOMDetailViewController(inspector: inspectorController.dom)
            case .network:
                viewController = WINetworkViewController(inspector: inspectorController.network)
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
    WIUIKitPreviewContainer {
        let session = WIInspectorController()
        let previewWebView = WIDOMPreviewFixtures.bootstrapDOMTreeForPreview(session.dom)
        WIDOMPreviewFixtures.applySampleSelection(to: session.dom, mode: .selected)
        WINetworkPreviewFixtures.applySampleData(to: session.network, mode: .detail)
        return WIInspectorViewController(
            session,
            webView: previewWebView,
            tabs: [.dom(), .network()]
        )
    }
}
#endif


#endif
