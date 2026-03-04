#if canImport(UIKit)
import UIKit
import ObservationsCompat
import WebInspectorRuntime

@MainActor
final class WICompactTabHostViewController: UITabBarController, UITabBarControllerDelegate {
    private let model: WIModel
    private let renderCache: WIUIKitTabRenderCache
    private var tabsObservationHandle: ObservationHandle?
    private var selectedTabObservationHandle: ObservationHandle?
    private var isApplyingSelectionFromModel = false

    init(model: WIModel, renderCache: WIUIKitTabRenderCache) {
        self.model = model
        self.renderCache = renderCache
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        tabsObservationHandle?.cancel()
        selectedTabObservationHandle?.cancel()
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
        tabsObservationHandle?.cancel()
        tabsObservationHandle = nil
        selectedTabObservationHandle?.cancel()
        selectedTabObservationHandle = nil
    }

    var displayedTabIdentifiersForTesting: [String] {
        tabs.map(\.identifier)
    }

    var currentUITabsForTesting: [UITab] {
        tabs
    }

    private func bindModel() {
        tabsObservationHandle?.cancel()
        selectedTabObservationHandle?.cancel()

        tabsObservationHandle = model.observe(
            \.tabs,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.rebuildNativeTabsIfPossible()
        }

        selectedTabObservationHandle = model.observe(
            \.selectedTab,
            options: [.removeDuplicates]
        ) { [weak self] newValue in
            guard let self else {
                return
            }
            self.syncNativeSelection(with: newValue)
        }
    }

    private func rebuildNativeTabsIfPossible() {
        renderCache.prune(activeTabs: model.tabs)
        // Intentionally project `model.tabs` as-is in compact mode.
        // We do not synthesize `.element` here; `WIModel.tabs` is the SSOT across layout changes.
        let desiredTabs = model.tabs.map { makeNativeTab(for: $0) }
        applyNativeTabsIfNeeded(desiredTabs)
        syncNativeSelection(with: model.selectedTab)
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

    private func syncNativeSelection(with tab: WITab?) {
        guard tabs.isEmpty == false else {
            return
        }

        guard
            let targetModelTab = resolveDisplayedModelTab(from: tab),
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
        model.setSelectedTabFromUI(selectedTab)
    }

    private func resolveDisplayedModelTab(from requestedTab: WITab?) -> WITab? {
        guard let requestedTab else {
            return model.tabs.first
        }
        if let exactMatch = model.tabs.first(where: { $0 === requestedTab }) {
            return exactMatch
        }
        if let identifierMatch = model.tabs.first(where: { $0.identifier == requestedTab.identifier }) {
            return identifierMatch
        }
        return model.tabs.first
    }

    private func resolveModelTab(for nativeTab: UITab) -> WITab? {
        if let exactMatch = renderCache.modelTab(for: nativeTab, among: model.tabs) {
            return exactMatch
        }
        return model.tabs.first(where: { $0.identifier == nativeTab.identifier })
    }

    private func resolveNativeTab(for modelTab: WITab) -> UITab? {
        if let cachedTab = renderCache.compactTab(for: modelTab),
           tabs.contains(where: { $0 === cachedTab }) {
            return cachedTab
        }
        return tabs.first(where: { $0.identifier == modelTab.identifier })
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
            switch tab.identifier {
            case WITab.domTabID:
                viewController = WIDOMViewController(inspector: model.dom)
            case WITab.elementTabID:
                viewController = WIDOMDetailViewController(inspector: model.dom)
            case WITab.networkTabID:
                viewController = WINetworkViewController(inspector: model.network)
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
        let session = WIModel()
        session.setTabs([.dom(), .element(), .network()])
        let host = WICompactTabHostViewController(model: session, renderCache: WIUIKitTabRenderCache())
        session.setSelectedTabFromUI(.dom())
        return host
    }
}
#endif
#endif
