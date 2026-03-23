#if canImport(UIKit)
import UIKit
import ObservationBridge
import WebInspectorRuntime

@MainActor
final class WICompactTabHostViewController: UITabBarController, UITabBarControllerDelegate {
    private let inspector: WIInspectorController
    private let renderCache: WIUIKitTabRenderCache
    private let synthesizedElementTab = WITab.element()
    private var tabObservationHandles: Set<ObservationHandle> = []
    private var isApplyingSelectionFromModel = false

    init(
        inspector: WIInspectorController,
        renderCache: WIUIKitTabRenderCache
    ) {
        self.inspector = inspector
        self.renderCache = renderCache
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(model inspector: WIInspectorController, renderCache: WIUIKitTabRenderCache) {
        self.init(
            inspector: inspector,
            renderCache: renderCache
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        tabObservationHandles.removeAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        tabBar.scrollEdgeAppearance = tabBar.standardAppearance
        rebuildNativeTabsIfPossible()
        bindModel()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        restoreModelSelectionIfNeeded(displayTabs: displayTabs)
        syncNativeSelection(with: inspector.selectedTab)
    }

    func prepareForRemoval() {
        delegate = nil
        tabObservationHandles.removeAll()
        releaseInstalledTabsIfNeeded()
    }

    var displayedTabIdentifiersForTesting: [String] {
        tabs.map(\.identifier)
    }

    var currentUITabsForTesting: [UITab] {
        tabs
    }

    private var displayTabs: [WITab] {
        wiCompactDisplayTabs(
            from: inspector.tabs,
            synthesizedElementTab: synthesizedElementTab
        )
    }

    private func bindModel() {
        tabObservationHandles.removeAll()

        inspector.observe(
            \.tabs,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.rebuildNativeTabsIfPossible()
        }
        .store(in: &tabObservationHandles)

        inspector.observe(
            \.selectedTab,
            options: [.removeDuplicates]
        ) { [weak self] newValue in
            guard let self else {
                return
            }
            self.syncNativeSelection(with: newValue)
        }
        .store(in: &tabObservationHandles)
    }

    private func rebuildNativeTabsIfPossible() {
        let resolvedDisplayTabs = displayTabs
        restoreModelSelectionIfNeeded(displayTabs: resolvedDisplayTabs)
        renderCache.prune(activeTabs: resolvedDisplayTabs)
        let desiredTabs = resolvedDisplayTabs.map { makeNativeTab(for: $0) }
        applyNativeTabsIfNeeded(desiredTabs)
        syncNativeSelection(with: inspector.selectedTab, displayTabs: resolvedDisplayTabs)
    }

    private func applyNativeTabsIfNeeded(_ desiredTabs: [UITab]) {
        guard tabsMatchCurrent(desiredTabs) == false else {
            return
        }
        isApplyingSelectionFromModel = true
        setTabs(desiredTabs, animated: false)
        isApplyingSelectionFromModel = false
    }

    private func tabsMatchCurrent(_ desiredTabs: [UITab]) -> Bool {
        guard tabs.count == desiredTabs.count else {
            return false
        }
        for (current, desired) in zip(tabs, desiredTabs) {
            guard current === desired else {
                return false
            }
        }
        return true
    }

    private func makeNativeTab(for tab: WITab) -> UITab {
        if let cached = renderCache.compactTab(for: tab) {
            return cached
        }

        let contentViewController = makeTabRootViewController(for: tab) ?? UIViewController()
        let wrappedViewController = wrappedInNavigationControllerIfNeeded(contentViewController)
        let nativeTab = UITab(
            title: tab.title,
            image: tab.image,
            identifier: tab.identifier
        ) { _ in
            wrappedViewController
        }
        renderCache.setCompactTab(nativeTab, for: tab)
        return nativeTab
    }

    private func syncNativeSelection(with tab: WITab?, displayTabs: [WITab]? = nil) {
        let displayTabs = displayTabs ?? self.displayTabs
        guard displayTabs.isEmpty == false, tabs.isEmpty == false else {
            return
        }

        guard
            let targetModelTab = resolveDisplayedModelTab(from: tab, in: displayTabs),
            let targetTab = resolveNativeTab(for: targetModelTab)
        else {
            return
        }

        guard selectedTab !== targetTab else {
            return
        }

        isApplyingSelectionFromModel = true
        selectedTab = targetTab
        isApplyingSelectionFromModel = false
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab candidateTab: UITab) -> Bool {
        if isApplyingSelectionFromModel {
            return true
        }
        return resolveModelTab(for: candidateTab) != nil
    }

    func tabBarController(
        _ tabBarController: UITabBarController,
        didSelectTab selectedTab: UITab,
        previousTab: UITab?
    ) {
        _ = previousTab
        guard isApplyingSelectionFromModel == false else {
            return
        }

        guard let selectedModelTab = resolveModelTab(for: selectedTab) else {
            return
        }
        applyUserSelection(selectedTab: selectedModelTab)
    }

    private func applyUserSelection(selectedTab: WITab) {
        inspector.setPreferredCompactSelectedTabIdentifier(selectedTab.identifier)
        inspector.setSelectedTab(selectedTab)
    }

    private func restoreModelSelectionIfNeeded(displayTabs: [WITab]) {
        guard let preferredIdentifier = inspector.preferredCompactSelectedTabIdentifier else {
            return
        }
        guard inspector.selectedTab?.identifier != preferredIdentifier else {
            return
        }
        guard let preferredTab = displayTabs.first(where: { $0.identifier == preferredIdentifier }) else {
            return
        }
        inspector.setSelectedTab(preferredTab)
    }

    private func resolveDisplayedModelTab(from requestedTab: WITab?, in displayTabs: [WITab]) -> WITab? {
        guard let requestedTab else {
            return displayTabs.first
        }
        if let exactMatch = displayTabs.first(where: { $0 === requestedTab }) {
            return exactMatch
        }
        if let identifierMatch = displayTabs.first(where: { $0.identifier == requestedTab.identifier }) {
            return identifierMatch
        }
        return displayTabs.first
    }

    private func resolveModelTab(for nativeTab: UITab) -> WITab? {
        let resolvedDisplayTabs = displayTabs
        if let exactMatch = renderCache.modelTab(for: nativeTab, among: resolvedDisplayTabs) {
            return exactMatch
        }
        return resolvedDisplayTabs.first(where: { $0.identifier == nativeTab.identifier })
    }

    private func resolveNativeTab(for modelTab: WITab) -> UITab? {
        if let cachedTab = renderCache.compactTab(for: modelTab),
           tabs.contains(where: { $0 === cachedTab }) {
            return cachedTab
        }
        return tabs.first(where: { $0.identifier == modelTab.identifier })
    }

    private func makeTabRootViewController(for tab: WITab) -> UIViewController? {
        if let cached = renderCache.rootViewController(for: tab),
           cached is UISplitViewController == false {
            applyHorizontalSizeClassOverrideIfNeeded(to: cached)
            return cached
        }

        let viewController: UIViewController?
        if let customViewController = tab.viewControllerProvider?(tab) {
            viewController = customViewController
        } else {
            switch tab.identifier {
            case WITab.domTabID:
                viewController = WIDOMViewController(inspector: inspector.dom)
            case WITab.elementTabID:
                viewController = WIDOMDetailViewController(inspector: inspector.dom)
            case WITab.networkTabID:
                viewController = WINetworkViewController(inspector: inspector.network)
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
            domViewController.horizontalSizeClassOverrideForTesting = .compact
        }
        if let networkViewController = viewController as? WINetworkViewController {
            networkViewController.horizontalSizeClassOverrideForTesting = .compact
        }
    }

    private func wrappedInNavigationControllerIfNeeded(_ viewController: UIViewController) -> UIViewController {
        if viewController is UINavigationController || viewController is UISplitViewController {
            return viewController
        }
        if let compactNavigationHosting = viewController as? (any WICompactNavigationHosting),
           compactNavigationHosting.providesCompactNavigationController {
            return viewController
        }

        let navigationController = UINavigationController(rootViewController: viewController)
        wiApplyClearNavigationBarStyle(to: navigationController)
        return navigationController
    }

    private func releaseInstalledTabsIfNeeded() {
        guard tabs.isEmpty == false else {
            return
        }
        isApplyingSelectionFromModel = true
        setTabs([], animated: false)
        isApplyingSelectionFromModel = false
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Compact Tab Host (UIKit)") {
    WIUIKitPreviewContainer {
        let session = WIInspectorController()
        session.setTabs([.dom(), .element(), .network()])
        let host = WICompactTabHostViewController(
            inspector: session,
            renderCache: WIUIKitTabRenderCache()
        )
        session.setSelectedTab(.dom())
        return host
    }
}
#endif
#endif
