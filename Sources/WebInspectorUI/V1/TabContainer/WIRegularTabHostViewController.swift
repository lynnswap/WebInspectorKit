#if canImport(UIKit)
import UIKit
import ObservationBridge
import WebInspectorRuntime

@MainActor
final class WIRegularTabHostViewController: UINavigationController {
    private let inspector: WIInspectorController
    private let renderCache: WIUIKitTabRenderCache
    private var tabObservationHandles: Set<ObservationHandle> = []
    private var isApplyingSegmentSelection = false

    private var tabs: [WITab] {
        inspector.tabs.filter { $0.identifier != WITab.elementTabID }
    }

    private lazy var segmentedControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [])
        control.addTarget(self, action: #selector(handleSegmentSelectionChanged(_:)), for: .valueChanged)
        control.accessibilityIdentifier = "WI.Regular.TabSwitcher"
        return control
    }()

    init(
        inspector: WIInspectorController,
        renderCache: WIUIKitTabRenderCache
    ) {
        self.inspector = inspector
        self.renderCache = renderCache
        super.init(nibName: nil, bundle: nil)

        normalizeModelSelectionToDisplayedTabIfNeeded()
        if let initialTab = selectedTabForDisplay(),
           let initialRoot = makeTabRootViewController(for: initialTab) {
            setViewControllers([wrappedForRegularNavigationIfNeeded(initialRoot)], animated: false)
        }
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
        view.backgroundColor = .clear
        navigationBar.prefersLargeTitles = false
        wiApplyClearNavigationBarStyle(to: self)

        bindModel()
        rebuildLayout()
    }

    func prepareForRemoval() {
        tabObservationHandles.removeAll()
        detachDisplayedRootViewControllerIfNeeded()
    }

    var displayedTabIDsForTesting: [String] {
        tabs.map(\.identifier)
    }

    var displayedRootViewControllerForTesting: UIViewController? {
        if let container = viewControllers.first as? WIRegularSplitRootContainerViewController {
            return container.contentViewController
        }
        return viewControllers.first
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

        let selectedTab = visibleTabs[selectedIndex]
        inspector.setSelectedTab(selectedTab)
    }

    func handleSegmentSelectionChangedForTesting(_ sender: UISegmentedControl) {
        handleSegmentSelectionChanged(sender)
    }

    private func bindModel() {
        tabObservationHandles.removeAll()

        inspector.observe(
            \.tabs
        ) { [weak self] _ in
            self?.rebuildLayout()
        }
        .store(in: &tabObservationHandles)

        inspector.observe(
            \.selectedTab
        ) { [weak self] _ in
            guard let self else {
                return
            }
            self.applySelectedTabProjection()
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

    private func rebuildSegmentedControl(selectedTab: WITab?) {
        let visibleTabs = tabs
        segmentedControl.removeAllSegments()
        for (index, tab) in visibleTabs.enumerated() {
            segmentedControl.insertSegment(withTitle: tab.title, at: index, animated: false)
        }
        segmentedControl.isEnabled = visibleTabs.isEmpty == false
        selectSegment(for: selectedTab)
    }

    private func selectSegment(for selectedTab: WITab?) {
        guard let selectedTab else {
            isApplyingSegmentSelection = true
            segmentedControl.selectedSegmentIndex = UISegmentedControl.noSegment
            isApplyingSegmentSelection = false
            return
        }

        let visibleTabs = tabs
        let selectedIndex = visibleTabs.firstIndex(where: { $0 === selectedTab })
            ?? visibleTabs.firstIndex(where: { $0.identifier == selectedTab.identifier })
            ?? UISegmentedControl.noSegment
        isApplyingSegmentSelection = true
        segmentedControl.selectedSegmentIndex = selectedIndex
        isApplyingSegmentSelection = false
    }

    private func displaySelectionIfNeeded(selectedTab: WITab?) {
        guard let selectedTab else {
            detachDisplayedRootViewControllerIfNeeded()
            return
        }

        let rootViewController = makeTabRootViewController(for: selectedTab) ?? UIViewController()
        let presentedViewController = wrappedForRegularNavigationIfNeeded(rootViewController)

        if viewControllers.first !== presentedViewController {
            setViewControllers([presentedViewController], animated: false)
        }
    }

    private func detachDisplayedRootViewControllerIfNeeded() {
        guard viewControllers.isEmpty == false else {
            return
        }
        viewControllers.first?.navigationItem.titleView = nil
        setViewControllers([], animated: false)
    }

    private func wrappedForRegularNavigationIfNeeded(_ viewController: UIViewController) -> UIViewController {
        guard viewController is UISplitViewController else {
            return viewController
        }
        if let existingContainer = viewControllers.first as? WIRegularSplitRootContainerViewController,
           existingContainer.contentViewController === viewController {
            return existingContainer
        }
        return WIRegularSplitRootContainerViewController(contentViewController: viewController)
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
            domViewController.horizontalSizeClassOverrideForTesting = .regular
        }
        if let networkViewController = viewController as? WINetworkViewController {
            networkViewController.horizontalSizeClassOverrideForTesting = .regular
        }
    }

    private func updateNavigationUI() {
        let navigationItem = viewControllers.first?.navigationItem ?? self.navigationItem
        let desiredTitleView: UIView? = tabs.isEmpty ? nil : segmentedControl
        if navigationItem.titleView !== desiredTitleView {
            navigationItem.titleView = desiredTitleView
        }
    }

    private func normalizeModelSelectionToDisplayedTabIfNeeded() {
        guard let displayedTab = selectedTabForDisplay() else {
            return
        }
        guard inspector.selectedTab !== displayedTab else {
            return
        }
        inspector.setSelectedTab(displayedTab)
    }

    private func selectedTabForDisplay() -> WITab? {
        let visibleTabs = tabs
        guard visibleTabs.isEmpty == false else {
            return nil
        }
        guard let selectedTab = inspector.selectedTab else {
            return visibleTabs.first
        }
        if let exactMatch = visibleTabs.first(where: { $0 === selectedTab }) {
            return exactMatch
        }
        if let identifierMatch = visibleTabs.first(where: { $0.identifier == selectedTab.identifier }) {
            return identifierMatch
        }
        if selectedTab.identifier == WITab.elementTabID,
           let domTab = visibleTabs.first(where: { $0.identifier == WITab.domTabID }) {
            return domTab
        }
        return visibleTabs.first
    }
}

@MainActor
private final class WIRegularSplitRootContainerViewController: UIViewController {
    let contentViewController: UIViewController

    init(contentViewController: UIViewController) {
        self.contentViewController = contentViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        installContentViewControllerIfNeeded()
    }

    private func installContentViewControllerIfNeeded() {
        guard contentViewController.parent == nil else {
            return
        }

        addChild(contentViewController)
        contentViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentViewController.view)
        NSLayoutConstraint.activate([
            contentViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            contentViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        contentViewController.didMove(toParent: self)
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Regular Tab Host (UIKit)") {
    WIUIKitPreviewContainer {
        let session = WIInspectorController()
        session.setTabs([.dom(), .network()])
        let host = WIRegularTabHostViewController(
            inspector: session,
            renderCache: WIUIKitTabRenderCache()
        )
        session.setSelectedTab(.dom())
        return host
    }
}
#endif
#endif
