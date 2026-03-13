#if canImport(UIKit)
import UIKit
import ObservationBridge
import WebInspectorCore

@MainActor
final class WICompactTabHostViewController: UITabBarController, UITabBarControllerDelegate {
    private let model: WISessionController
    private let displayTabs: [WITab]
    private let renderCache: WIUIKitTabRenderCache
    private var tabObservationHandles: Set<ObservationHandle> = []
    private var isApplyingSelectionFromModel = false

    init(model: WISessionController, tabs: [WITab], renderCache: WIUIKitTabRenderCache) {
        self.model = model
        displayTabs = tabs
        self.renderCache = renderCache
        super.init(nibName: nil, bundle: nil)
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

    func prepareForRemoval() {
        delegate = nil
        tabObservationHandles.removeAll()
        // Release UITab closures before another compact host reuses cached roots.
        setTabs([], animated: false)
    }

    var displayedTabIdentifiersForTesting: [String] {
        tabs.map(\.identifier)
    }

    var currentUITabsForTesting: [UITab] {
        tabs
    }

    private func bindModel() {
        tabObservationHandles.removeAll()

        model.observe(
            \.selectedPanelConfiguration,
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
        let desiredTabs = displayTabs.map { makeNativeTab(for: $0) }
        applyNativeTabsIfNeeded(desiredTabs)
        syncNativeSelection(with: model.selectedPanelConfiguration)
    }

    private func applyNativeTabsIfNeeded(_ desiredTabs: [UITab]) {
        guard tabsMatchCurrent(desiredTabs) == false else {
            return
        }
        setTabs(desiredTabs, animated: false)
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
        let wrappedViewController =
            renderCache.compactWrappedViewController(for: tab)
            ?? wrappedInNavigationControllerIfNeeded(contentViewController)
        renderCache.setCompactWrappedViewController(wrappedViewController, for: tab)
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

    private func syncNativeSelection(with panelConfiguration: WIPanelConfiguration?) {
        guard tabs.isEmpty == false else {
            return
        }

        guard
            let targetModelTab = resolveDisplayedModelTab(from: panelConfiguration),
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
        model.setSelectedPanelFromUI(selectedTab.configuration)
    }

    private func resolveDisplayedModelTab(
        from requestedPanelConfiguration: WIPanelConfiguration?
    ) -> WITab? {
        guard let requestedPanelConfiguration else {
            return displayTabs.first
        }
        if let exactMatch = displayTabs.first(where: { $0.configuration == requestedPanelConfiguration }) {
            return exactMatch
        }
        let identifierMatches = displayTabs.filter {
            $0.configuration.identifier == requestedPanelConfiguration.identifier
        }
        if identifierMatches.count == 1, let identifierMatch = identifierMatches.first {
            return identifierMatch
        }
        return displayTabs.first
    }

    private func resolveModelTab(for nativeTab: UITab) -> WITab? {
        if let exactMatch = renderCache.modelTab(for: nativeTab, among: displayTabs) {
            return exactMatch
        }
        let identifierMatches = displayTabs.filter { $0.identifier == nativeTab.identifier }
        if identifierMatches.count == 1 {
            return identifierMatches.first
        }
        return nil
    }

    private func resolveNativeTab(for modelTab: WITab) -> UITab? {
        if let cachedTab = renderCache.compactTab(for: modelTab),
           tabs.contains(where: { $0 === cachedTab }) {
            return cachedTab
        }
        let identifierMatches = tabs.filter { $0.identifier == modelTab.identifier }
        if identifierMatches.count == 1 {
            return identifierMatches.first
        }
        return nil
    }

    private func makeTabRootViewController(for tab: WITab) -> UIViewController? {
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
                viewController = WIDOMViewController(store: model.domStore)
            case .domDetail:
                viewController = WIDOMDetailViewController(store: model.domStore)
            case .network:
                viewController = WINetworkViewController(store: model.networkStore)
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
            domViewController.horizontalSizeClassOverrideForTesting = .compact
        }
        if let networkViewController = viewController as? WINetworkViewController {
            networkViewController.horizontalSizeClassOverrideForTesting = .compact
        }
    }

    private func wrappedInNavigationControllerIfNeeded(_ viewController: UIViewController) -> UIViewController {
        if viewController is UINavigationController {
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
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Compact Tab Host (UIKit)") {
    let session = WISessionPreviewFixtures.makeSessionController()
    let tabs: [WITab] = [.dom(), .element(), .network()]
    session.configurePanels(tabs.map(\.configuration))
    let host = WICompactTabHostViewController(model: session, tabs: tabs, renderCache: WIUIKitTabRenderCache())
    session.setSelectedPanelFromUI(tabs.first?.configuration)
    return host
}
#endif
#endif
