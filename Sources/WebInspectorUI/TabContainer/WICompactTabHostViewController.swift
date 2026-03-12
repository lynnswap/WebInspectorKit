#if canImport(UIKit)
import UIKit
import ObservationBridge
import WebInspectorShell

@MainActor
final class WICompactTabHostViewController: UITabBarController, UITabBarControllerDelegate {
    private let model: WIInspectorController
    private let requestedTabs: [WIInspectorTab]
    private let renderCache: WIUIKitTabRenderCache
    private var tabObservationHandles: Set<ObservationHandle> = []
    private var isApplyingSelectionFromModel = false

    init(model: WIInspectorController, tabs: [WIInspectorTab], renderCache: WIUIKitTabRenderCache) {
        self.model = model
        requestedTabs = tabs
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
        renderCache.prune(activeTabs: requestedTabs)
        let desiredTabs = requestedTabs.map { makeNativeTab(for: $0) }
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

    private func makeNativeTab(for tab: WIInspectorTab) -> UITab {
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

    private func syncNativeSelection(with panelConfiguration: WIInspectorPanelConfiguration?) {
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

    private func applyUserSelection(selectedTab: WIInspectorTab) {
        model.setSelectedPanelFromUI(selectedTab.configuration)
    }

    private func resolveDisplayedModelTab(
        from requestedPanelConfiguration: WIInspectorPanelConfiguration?
    ) -> WIInspectorTab? {
        guard let requestedPanelConfiguration else {
            return requestedTabs.first
        }
        if let exactMatch = requestedTabs.first(where: { $0.configuration == requestedPanelConfiguration }) {
            return exactMatch
        }
        let identifierMatches = requestedTabs.filter {
            $0.configuration.identifier == requestedPanelConfiguration.identifier
        }
        if identifierMatches.count == 1, let identifierMatch = identifierMatches.first {
            return identifierMatch
        }
        return requestedTabs.first
    }

    private func resolveModelTab(for nativeTab: UITab) -> WIInspectorTab? {
        if let exactMatch = renderCache.modelTab(for: nativeTab, among: requestedTabs) {
            return exactMatch
        }
        let identifierMatches = requestedTabs.filter { $0.identifier == nativeTab.identifier }
        if identifierMatches.count == 1 {
            return identifierMatches.first
        }
        return nil
    }

    private func resolveNativeTab(for modelTab: WIInspectorTab) -> UITab? {
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

    private func makeTabRootViewController(for tab: WIInspectorTab) -> UIViewController? {
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
                viewController = WIDOMViewController(inspector: model.dom)
            case .domDetail:
                viewController = WIDOMDetailViewController(inspector: model.dom)
            case .network:
                viewController = WINetworkViewController(inspector: model.network)
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
    WIUIKitPreviewContainer {
        let session = WIInspectorController()
        let tabs: [WIInspectorTab] = [.dom(), .element(), .network()]
        session.configurePanels(tabs.map(\.configuration))
        let host = WICompactTabHostViewController(model: session, tabs: tabs, renderCache: WIUIKitTabRenderCache())
        session.setSelectedPanelFromUI(tabs.first?.configuration)
        return host
    }
}
#endif
#endif
