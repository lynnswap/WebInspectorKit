#if canImport(UIKit)
import UIKit
import ObservationBridge
import WebInspectorShell

@MainActor
final class WIRegularTabHostViewController: UINavigationController {
    private let model: WIInspectorController
    private let requestedTabs: [WIInspectorTab]
    private let renderCache: WIUIKitTabRenderCache
    private var tabObservationHandles: Set<ObservationHandle> = []
    private var isApplyingSegmentSelection = false

    private let placeholderViewController: UIViewController

    private var tabs: [WIInspectorTab] {
        requestedTabs.filter { $0.panelKind != .domDetail }
    }

    private lazy var segmentedControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [])
        control.addTarget(self, action: #selector(handleSegmentSelectionChanged(_:)), for: .valueChanged)
        control.accessibilityIdentifier = "WI.Regular.TabSwitcher"
        return control
    }()

    init(model: WIInspectorController, tabs: [WIInspectorTab], renderCache: WIUIKitTabRenderCache) {
        self.model = model
        requestedTabs = tabs
        self.renderCache = renderCache
        let placeholder = UIViewController()
        placeholder.navigationItem.title = ""
        self.placeholderViewController = placeholder
        super.init(rootViewController: placeholder)

        normalizeModelSelectionToDisplayedTabIfNeeded()
        if let initialTab = selectedTabForDisplay(),
           let initialRoot = makeTabRootViewController(for: initialTab) {
            setViewControllers([initialRoot], animated: false)
        }
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
        navigationBar.prefersLargeTitles = false
        wiApplyClearNavigationBarStyle(to: self)

        bindModel()
        rebuildLayout()
    }

    func prepareForRemoval() {
        tabObservationHandles.removeAll()
    }

    var displayedTabIDsForTesting: [String] {
        tabs.map(\.identifier)
    }

    @objc
    private func handleSegmentSelectionChanged(_ sender: UISegmentedControl) {
        guard isApplyingSegmentSelection == false else {
            return
        }
        let selectedIndex = sender.selectedSegmentIndex
        let visibleTabs = tabs
        guard selectedIndex >= 0, visibleTabs.indices.contains(selectedIndex) else {
            return
        }

        model.setSelectedPanelFromUI(visibleTabs[selectedIndex].configuration)
    }

    func handleSegmentSelectionChangedForTesting(_ sender: UISegmentedControl) {
        handleSegmentSelectionChanged(sender)
    }

    private func bindModel() {
        tabObservationHandles.removeAll()

        model.observe(
            \.selectedPanelConfiguration,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.applySelectedTabProjection()
        }
        .store(in: &tabObservationHandles)
    }

    private func rebuildLayout() {
        renderCache.prune(activeTabs: tabs)
        normalizeModelSelectionToDisplayedTabIfNeeded()
        let selectedTab = selectedTabForDisplay()
        rebuildSegmentedControl(selectedTab: selectedTab)
        displaySelectionIfNeeded(selectedTab: selectedTab)
        updateNavigationUI()
    }

    private func applySelectedTabProjection() {
        renderCache.prune(activeTabs: tabs)
        normalizeModelSelectionToDisplayedTabIfNeeded()
        let selectedTab = selectedTabForDisplay()
        selectSegment(for: selectedTab)
        displaySelectionIfNeeded(selectedTab: selectedTab)
        updateNavigationUI()
    }

    private func rebuildSegmentedControl(selectedTab: WIInspectorTab?) {
        let visibleTabs = tabs
        segmentedControl.removeAllSegments()
        for (index, tab) in visibleTabs.enumerated() {
            segmentedControl.insertSegment(withTitle: tab.title, at: index, animated: false)
        }
        segmentedControl.isEnabled = visibleTabs.isEmpty == false
        selectSegment(for: selectedTab)
    }

    private func selectSegment(for selectedTab: WIInspectorTab?) {
        guard let selectedTab else {
            isApplyingSegmentSelection = true
            segmentedControl.selectedSegmentIndex = UISegmentedControl.noSegment
            isApplyingSegmentSelection = false
            return
        }

        let visibleTabs = tabs
        let selectedIndex = visibleTabs.firstIndex(where: { $0 === selectedTab })
            ?? {
                let identifierMatches = visibleTabs.enumerated().filter {
                    $0.element.identifier == selectedTab.identifier
                }
                guard identifierMatches.count == 1 else {
                    return nil
                }
                return identifierMatches.first?.offset
            }()
            ?? UISegmentedControl.noSegment
        isApplyingSegmentSelection = true
        segmentedControl.selectedSegmentIndex = selectedIndex
        isApplyingSegmentSelection = false
    }

    private func displaySelectionIfNeeded(selectedTab: WIInspectorTab?) {
        guard let selectedTab else {
            if viewControllers.first !== placeholderViewController {
                setViewControllers([placeholderViewController], animated: false)
            }
            return
        }

        let rootViewController = makeTabRootViewController(for: selectedTab) ?? UIViewController()

        if viewControllers.first !== rootViewController {
            setViewControllers([rootViewController], animated: false)
        }
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
            domViewController.horizontalSizeClassOverrideForTesting = .regular
        }
        if let networkViewController = viewController as? WINetworkViewController {
            networkViewController.horizontalSizeClassOverrideForTesting = .regular
        }
    }

    private func updateNavigationUI() {
        let navigationItem = viewControllers.first?.navigationItem ?? placeholderViewController.navigationItem
        let desiredTitleView: UIView? = tabs.isEmpty ? nil : segmentedControl
        if navigationItem.titleView !== desiredTitleView {
            navigationItem.titleView = desiredTitleView
        }
    }

    private func normalizeModelSelectionToDisplayedTabIfNeeded() {
        guard let displayedTab = selectedTabForDisplay() else {
            return
        }
        guard model.selectedPanelConfiguration != displayedTab.configuration else {
            return
        }
        model.setSelectedPanelFromUI(displayedTab.configuration)
    }

    private func selectedTabForDisplay() -> WIInspectorTab? {
        let visibleTabs = tabs
        guard visibleTabs.isEmpty == false else {
            return nil
        }
        guard let selectedPanelConfiguration = model.selectedPanelConfiguration else {
            return visibleTabs.first
        }
        if let exactMatch = visibleTabs.first(where: { $0.configuration == selectedPanelConfiguration }) {
            return exactMatch
        }
        let identifierMatches = visibleTabs.filter {
            $0.configuration.identifier == selectedPanelConfiguration.identifier
        }
        if identifierMatches.count == 1, let identifierMatch = identifierMatches.first {
            return identifierMatch
        }
        if selectedPanelConfiguration.kind == .domDetail,
           let domTab = visibleTabs.first(where: { $0.panelKind == .domTree }) {
            return domTab
        }
        return visibleTabs.first
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Regular Tab Host (UIKit)") {
    WIUIKitPreviewContainer {
        let session = WIInspectorController()
        let tabs: [WIInspectorTab] = [.dom(), .network()]
        session.configurePanels(tabs.map(\.configuration))
        let host = WIRegularTabHostViewController(model: session, tabs: tabs, renderCache: WIUIKitTabRenderCache())
        session.setSelectedPanelFromUI(tabs.first?.configuration)
        return host
    }
}
#endif
#endif
