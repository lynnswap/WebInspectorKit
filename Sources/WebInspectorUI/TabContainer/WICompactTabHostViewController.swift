#if canImport(UIKit)
import UIKit
import ObservationsCompat
import WebInspectorRuntime

@MainActor
final class WICompactTabHostViewController: UITabBarController, UITabBarControllerDelegate {
    private let model: WIModel
    private var tabsObservationHandle: ObservationHandle?
    private var selectedTabObservationHandle: ObservationHandle?
    private var isApplyingSelectionFromModel = false
    private let tabsRebuildCoalescer = UIUpdateCoalescer()

    init(model: WIModel) {
        self.model = model
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

        tabsObservationHandle = model.observeTask(
            \.tabs,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            guard let self else {
                return
            }
            self.tabsRebuildCoalescer.schedule { [weak self] in
                self?.rebuildNativeTabsIfPossible()
            }
        }

        selectedTabObservationHandle = model.observeTask(
            \.selectedTab,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            guard let self else {
                return
            }
            self.syncNativeSelection(with: self.model.selectedTab)
        }
    }

    private func rebuildNativeTabsIfPossible() {
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
        if let cached = tab.cachedCompactUITab {
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
        tab.cachedCompactUITab = nativeTab
        return nativeTab
    }

    private func syncNativeSelection(with tab: WITab?) {
        guard tabs.isEmpty == false else {
            return
        }

        guard
            let targetIdentifier = resolveDisplayedTabIdentifier(from: tab),
            let targetTab = tabs.first(where: { $0.identifier == targetIdentifier })
        else {
            return
        }

        guard selectedTab?.identifier != targetIdentifier else {
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
        return model.tabs.contains(where: { $0.identifier == candidateTab.identifier })
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

        guard model.tabs.contains(where: { $0.identifier == selectedTab.identifier }) else {
            return
        }
        applyUserSelection(selectedTabIdentifier: selectedTab.identifier)
    }

    private func applyUserSelection(selectedTabIdentifier: String) {
        let selectedTab = model.tabs.first(where: { $0.identifier == selectedTabIdentifier })
        model.setSelectedTabFromUI(selectedTab)
    }

    private func resolveDisplayedTabIdentifier(from requestedTab: WITab?) -> String? {
        guard let requestedTab else {
            return model.tabs.first?.identifier
        }
        if model.tabs.contains(where: { $0 === requestedTab }) {
            return requestedTab.identifier
        }
        if model.tabs.contains(where: { $0.identifier == requestedTab.identifier }) {
            return requestedTab.identifier
        }
        return model.tabs.first?.identifier
    }

    private func makeTabRootViewController(for tab: WITab) -> UIViewController? {
        if let cached = tab.cachedContentViewController {
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
        tab.cachedContentViewController = viewController
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
        let host = WICompactTabHostViewController(model: session)
        session.setSelectedTabFromUI(.dom())
        return host
    }
}
#endif
#endif
