#if canImport(UIKit)
import UIKit
import ObservationsCompat
import WebInspectorRuntime

@MainActor
final class WIRegularTabHostViewController: UINavigationController {
    private let model: WIModel
    private var tabsObservationHandle: ObservationHandle?
    private var selectedTabObservationHandle: ObservationHandle?
    private var isApplyingSegmentSelection = false

    private let placeholderViewController: UIViewController

    private var tabs: [WITab] {
        model.tabs.filter { $0.identifier != WITab.elementTabID }
    }

    private lazy var segmentedControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [])
        control.addTarget(self, action: #selector(handleSegmentSelectionChanged(_:)), for: .valueChanged)
        control.accessibilityIdentifier = "WI.Regular.TabSwitcher"
        return control
    }()

    init(model: WIModel) {
        self.model = model
        let placeholder = UIViewController()
        placeholder.navigationItem.title = ""
        self.placeholderViewController = placeholder
        super.init(rootViewController: placeholder)

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
        tabsObservationHandle?.cancel()
        selectedTabObservationHandle?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = false
        wiApplyClearNavigationBarStyle(to: self)

        bindModel()
        rebuildLayout()
    }

    func prepareForRemoval() {
        tabsObservationHandle?.cancel()
        tabsObservationHandle = nil
        selectedTabObservationHandle?.cancel()
        selectedTabObservationHandle = nil
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

        model.setSelectedTabFromUI(visibleTabs[selectedIndex])
    }

    func handleSegmentSelectionChangedForTesting(_ sender: UISegmentedControl) {
        handleSegmentSelectionChanged(sender)
    }

    private func bindModel() {
        tabsObservationHandle?.cancel()
        selectedTabObservationHandle?.cancel()

        tabsObservationHandle = model.observeTask([\.tabs]) { [weak self] in
            self?.rebuildLayout()
        }

        selectedTabObservationHandle = model.observeTask([\.selectedTab]) { [weak self] in
            self?.applySelectedTabProjection()
        }
    }

    private func rebuildLayout() {
        let selectedTab = selectedTabForDisplay()
        rebuildSegmentedControl(selectedTab: selectedTab)
        displaySelectionIfNeeded(selectedTab: selectedTab)
        updateNavigationUI()
    }

    private func applySelectedTabProjection() {
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

    private func selectedTabForDisplay() -> WITab? {
        let visibleTabs = tabs
        guard visibleTabs.isEmpty == false else {
            return nil
        }
        guard let selectedTab = model.selectedTab else {
            return visibleTabs.first
        }
        if let exactMatch = visibleTabs.first(where: { $0 === selectedTab }) {
            return exactMatch
        }
        if let identifierMatch = visibleTabs.first(where: { $0.identifier == selectedTab.identifier }) {
            return identifierMatch
        }
        return visibleTabs.first
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Regular Tab Host (UIKit)") {
    WIUIKitPreviewContainer {
        let session = WIModel()
        session.setTabs([.dom(), .network()])
        let host = WIRegularTabHostViewController(model: session)
        session.setSelectedTabFromUI(.dom())
        return host
    }
}
#endif
#endif
