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

    public private(set) var inspectorController: WIModel

    private var requestedTabs: [WITab]
    private let renderCache = WIUIKitTabRenderCache()

    private var activeHost: (UIViewController & WIUIKitTabHost)?
    private var activeHostKind: HostKind?

    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass? {
        didSet {
            if isViewLoaded {
                handleHorizontalSizeClassChange()
            }
        }
    }

    public init(
        _ inspectorController: WIModel,
        webView: WKWebView?,
        tabs: [WITab] = [.dom(), .network()]
    ) {
        self.inspectorController = inspectorController
        self.requestedTabs = tabs
        super.init(nibName: nil, bundle: nil)
        if let webView {
            inspectorController.setPageWebViewFromUI(webView)
        }
        inspectorController.setTabs(tabs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public func setPageWebView(_ webView: WKWebView?) {
        inspectorController.setPageWebViewFromUI(webView)
        if isViewLoaded {
            inspectorController.activateFromUIIfPossible()
        }
    }

    public func setInspectorController(_ inspectorController: WIModel) {
        guard self.inspectorController !== inspectorController else {
            return
        }

        let currentRequestedTabs = requestedTabs
        let currentSelectedTab = self.inspectorController.selectedTab
        let currentPreferredCompactSelectedTabIdentifier = self.inspectorController.preferredCompactSelectedTabIdentifier
        let currentPageWebView = self.inspectorController.pageWebViewForUI
        let previousController = self.inspectorController
        renderCache.resetAll()
        previousController.disconnect()

        self.inspectorController = inspectorController
        inspectorController.setPageWebViewFromUI(currentPageWebView)
        inspectorController.setTabs(currentRequestedTabs)
        inspectorController.setPreferredCompactSelectedTabIdentifierFromUI(currentPreferredCompactSelectedTabIdentifier)
        inspectorController.setSelectedTabFromUI(currentSelectedTab)

        if isViewLoaded {
            rebuildLayout(forceHostReplacement: true)
            inspectorController.activateFromUIIfPossible()
        }
    }

    public func setTabs(_ tabs: [WITab]) {
        requestedTabs = tabs
        inspectorController.setTabs(tabs)
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
        inspectorController.tabs.map(\.identifier)
    }

    var activeHostViewControllerForTesting: UIViewController? {
        activeHost
    }

    private var effectiveHorizontalSizeClass: UIUserInterfaceSizeClass {
        horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass
    }

    private func rebuildLayout(forceHostReplacement: Bool = false) {
        renderCache.prune(activeTabs: inspectorController.tabs)

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
            host = WICompactTabHostViewController(model: inspectorController, renderCache: renderCache)
        case .regular:
            host = WIRegularTabHostViewController(model: inspectorController, renderCache: renderCache)
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
#Preview("Tab Container (UIKit)") {
    WIUIKitPreviewContainer {
        let session = WIModel()
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
