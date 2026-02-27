#if canImport(UIKit)
import UIKit
import ObservationsCompat
import WebInspectorRuntime

@MainActor
final class WIRegularTabHostViewController: UINavigationController, WIUIKitInspectorHostProtocol {
    private struct TabRoot {
        let contentViewController: UIViewController
        let rootViewController: UIViewController
    }

    private final class HostedRootViewController: UIViewController {
        let contentViewController: UIViewController

        init(contentViewController: UIViewController) {
            self.contentViewController = contentViewController
            super.init(nibName: nil, bundle: nil)
            view.backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidLoad() {
            super.viewDidLoad()

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

    var onSelectedTabIDChange: ((WITabDescriptor.ID) -> Void)?

    private var tabDescriptors: [WITabDescriptor] = []
    private var context: WITabContext?
    private var tabRootByTabID: [WITabDescriptor.ID: TabRoot] = [:]
    private var selectedTabID: WITabDescriptor.ID?
    private var isApplyingSegmentSelection = false
    private weak var activeNavigationItemProvider: (any WIHostNavigationItemProvider)?
    private var activeNavigationState: WIHostNavigationState?
    private var navigationStateObservationHandles: [ObservationHandle] = []

    private let placeholderViewController: UIViewController

    private lazy var segmentedControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [])
        control.addTarget(self, action: #selector(handleSegmentSelectionChanged(_:)), for: .valueChanged)
        control.accessibilityIdentifier = "WI.Regular.TabSwitcher"
        return control
    }()

    init() {
        let placeholder = UIViewController()
        placeholder.view.backgroundColor = .clear
        placeholder.navigationItem.title = ""
        self.placeholderViewController = placeholder
        super.init(rootViewController: placeholder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        navigationBar.prefersLargeTitles = false
        wiApplyClearNavigationBarStyle(to: self)

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.updateNavigationUI()
        }

        updateNavigationUI()
    }

    func setTabDescriptors(_ descriptors: [WITabDescriptor], context: WITabContext) {
        invalidateCachedViewControllers()
        tabDescriptors = descriptors
        self.context = context

        if selectedTabID == nil || tabDescriptors.contains(where: { $0.id == selectedTabID }) == false {
            selectedTabID = tabDescriptors.first?.id
        }

        rebuildSegmentedControl()
        displaySelectedTabIfNeeded()
        updateNavigationUI()
    }

    func setSelectedTabID(_ tabID: WITabDescriptor.ID?) {
        guard tabDescriptors.isEmpty == false else {
            selectedTabID = nil
            selectSegmentForCurrentSelection()
            displaySelectedTabIfNeeded()
            updateNavigationUI()
            return
        }

        let resolvedTabID: WITabDescriptor.ID
        if let tabID, tabDescriptors.contains(where: { $0.id == tabID }) {
            resolvedTabID = tabID
        } else {
            resolvedTabID = tabDescriptors[0].id
        }

        let wasNormalized = tabID != resolvedTabID
        guard selectedTabID != resolvedTabID || wasNormalized else {
            return
        }

        selectedTabID = resolvedTabID
        selectSegmentForCurrentSelection()
        displaySelectedTabIfNeeded()
        updateNavigationUI()

        if wasNormalized {
            onSelectedTabIDChange?(resolvedTabID)
        }
    }

    func prepareForRemoval() {
        onSelectedTabIDChange = nil
        unbindNavigationProviderState()
        activeNavigationItemProvider = nil
        clearHostManagedNavigationControls(from: currentNavigationItem)
    }

    var displayedTabIDsForTesting: [WITabDescriptor.ID] {
        tabDescriptors.map(\.id)
    }

    @objc
    private func handleSegmentSelectionChanged(_ sender: UISegmentedControl) {
        guard isApplyingSegmentSelection == false else {
            return
        }
        let selectedIndex = sender.selectedSegmentIndex
        guard selectedIndex >= 0, tabDescriptors.indices.contains(selectedIndex) else {
            return
        }

        let tabID = tabDescriptors[selectedIndex].id
        guard selectedTabID != tabID else {
            return
        }

        selectedTabID = tabID
        displaySelectedTabIfNeeded()
        updateNavigationUI()
        onSelectedTabIDChange?(tabID)
    }

    private func invalidateCachedViewControllers() {
        unbindNavigationProviderState()
        activeNavigationItemProvider = nil
        tabRootByTabID.removeAll()
        if viewControllers.first !== placeholderViewController {
            setViewControllers([placeholderViewController], animated: false)
        }
    }

    private func rebuildSegmentedControl() {
        segmentedControl.removeAllSegments()
        for (index, descriptor) in tabDescriptors.enumerated() {
            segmentedControl.insertSegment(withTitle: descriptor.title, at: index, animated: false)
        }
        segmentedControl.isEnabled = tabDescriptors.isEmpty == false
        selectSegmentForCurrentSelection()
    }

    private func selectSegmentForCurrentSelection() {
        guard let selectedTabID,
              let selectedIndex = tabDescriptors.firstIndex(where: { $0.id == selectedTabID }) else {
            isApplyingSegmentSelection = true
            segmentedControl.selectedSegmentIndex = UISegmentedControl.noSegment
            isApplyingSegmentSelection = false
            return
        }

        isApplyingSegmentSelection = true
        segmentedControl.selectedSegmentIndex = selectedIndex
        isApplyingSegmentSelection = false
    }

    private func displaySelectedTabIfNeeded() {
        guard let selectedDescriptor = selectedDescriptor else {
            if viewControllers.first !== placeholderViewController {
                setViewControllers([placeholderViewController], animated: false)
            }
            synchronizeNavigationProvider()
            return
        }
        guard let context else {
            return
        }

        let tabRoot: TabRoot
        if let cached = tabRootByTabID[selectedDescriptor.id] {
            tabRoot = cached
        } else {
            let created = makeTabRoot(for: selectedDescriptor, context: context)
            tabRootByTabID[selectedDescriptor.id] = created
            tabRoot = created
        }

        if viewControllers.first !== tabRoot.rootViewController {
            setViewControllers([tabRoot.rootViewController], animated: false)
        }
        synchronizeNavigationProvider()
    }

    private func makeTabRoot(
        for descriptor: WITabDescriptor,
        context: WITabContext
    ) -> TabRoot {
        let contentViewController = descriptor.makeViewController(context: context)
        let rootViewController: UIViewController
        if contentViewController is UISplitViewController {
            rootViewController = HostedRootViewController(contentViewController: contentViewController)
        } else {
            rootViewController = contentViewController
        }
        rootViewController.view.backgroundColor = .clear
        return TabRoot(
            contentViewController: contentViewController,
            rootViewController: rootViewController
        )
    }

    private var selectedDescriptor: WITabDescriptor? {
        guard let selectedTabID else {
            return nil
        }
        return tabDescriptors.first(where: { $0.id == selectedTabID })
    }

    private var selectedContentViewController: UIViewController? {
        guard let selectedTabID else {
            return nil
        }
        return tabRootByTabID[selectedTabID]?.contentViewController
    }

    private var currentNavigationItem: UINavigationItem {
        viewControllers.first?.navigationItem ?? placeholderViewController.navigationItem
    }

    private func updateNavigationUI() {
        let navigationItem = currentNavigationItem
        let desiredTitleView: UIView? = tabDescriptors.isEmpty ? nil : segmentedControl
        if navigationItem.titleView !== desiredTitleView {
            navigationItem.titleView = desiredTitleView
        }

        guard selectedTabID != nil else {
            clearHostManagedNavigationControls(from: navigationItem, preserveTitleView: true)
            return
        }

        synchronizeNavigationProvider()
        if activeNavigationState == nil {
            clearHostManagedNavigationControls(from: navigationItem, preserveTitleView: true)
            return
        }
        applyAllManagedNavigationItems(to: navigationItem)
    }

    private func synchronizeNavigationProvider() {
        let provider = selectedContentViewController as? (any WIHostNavigationItemProvider)

        let currentID = activeNavigationItemProvider.map { ObjectIdentifier($0) }
        let newID = provider.map { ObjectIdentifier($0) }
        guard currentID != newID else {
            return
        }

        unbindNavigationProviderState()
        activeNavigationItemProvider = provider
        bindNavigationProviderState()
    }

    private func bindNavigationProviderState() {
        guard let state = activeNavigationItemProvider?.hostNavigationState else {
            activeNavigationState = nil
            return
        }
        activeNavigationState = state
        navigationStateObservationHandles.append(
            state.observe(\.searchController) { [weak self] _ in
                self?.applySearchControllerIfNeeded()
            }
        )
        navigationStateObservationHandles.append(
            state.observe(\.preferredSearchBarPlacement) { [weak self] _ in
                self?.applySearchBarPlacementIfNeeded()
            }
        )
        navigationStateObservationHandles.append(
            state.observe(\.hidesSearchBarWhenScrolling) { [weak self] _ in
                self?.applyHidesSearchBarWhenScrollingIfNeeded()
            }
        )
        navigationStateObservationHandles.append(
            state.observe(\.leftBarButtonItems) { [weak self] _ in
                self?.applyLeftBarButtonItemsIfNeeded()
            }
        )
        navigationStateObservationHandles.append(
            state.observe(\.rightBarButtonItems) { [weak self] _ in
                self?.applyRightBarButtonItemsIfNeeded()
            }
        )
        navigationStateObservationHandles.append(
            state.observe(\.additionalOverflowItems) { [weak self] _ in
                self?.applyAdditionalOverflowItemsIfNeeded()
            }
        )
    }

    private func unbindNavigationProviderState() {
        for handle in navigationStateObservationHandles {
            handle.cancel()
        }
        navigationStateObservationHandles.removeAll()
        activeNavigationState = nil
    }

    private func applyAllManagedNavigationItems(to navigationItem: UINavigationItem) {
        applySearchControllerIfNeeded(navigationItem: navigationItem)
        applySearchBarPlacementIfNeeded(navigationItem: navigationItem)
        applyHidesSearchBarWhenScrollingIfNeeded(navigationItem: navigationItem)
        applyLeftBarButtonItemsIfNeeded(navigationItem: navigationItem)
        applyRightBarButtonItemsIfNeeded(navigationItem: navigationItem)
        applyAdditionalOverflowItemsIfNeeded(navigationItem: navigationItem)
    }

    private func applySearchControllerIfNeeded(navigationItem: UINavigationItem? = nil) {
        guard let state = activeNavigationState else {
            return
        }
        let targetNavigationItem = navigationItem ?? currentNavigationItem
        if targetNavigationItem.searchController !== state.searchController {
            targetNavigationItem.searchController = state.searchController
        }
    }

    private func applySearchBarPlacementIfNeeded(navigationItem: UINavigationItem? = nil) {
        guard let state = activeNavigationState else {
            return
        }
        let targetNavigationItem = navigationItem ?? currentNavigationItem
        let desiredPlacement = state.preferredSearchBarPlacement ?? .automatic
        if targetNavigationItem.preferredSearchBarPlacement != desiredPlacement {
            targetNavigationItem.preferredSearchBarPlacement = desiredPlacement
        }
    }

    private func applyHidesSearchBarWhenScrollingIfNeeded(navigationItem: UINavigationItem? = nil) {
        guard let state = activeNavigationState else {
            return
        }
        let targetNavigationItem = navigationItem ?? currentNavigationItem
        if targetNavigationItem.hidesSearchBarWhenScrolling != state.hidesSearchBarWhenScrolling {
            targetNavigationItem.hidesSearchBarWhenScrolling = state.hidesSearchBarWhenScrolling
        }
    }

    private func applyLeftBarButtonItemsIfNeeded(navigationItem: UINavigationItem? = nil) {
        guard let state = activeNavigationState else {
            return
        }
        let targetNavigationItem = navigationItem ?? currentNavigationItem
        guard
            WINavigationDiff.areBarButtonItemsEquivalent(
                targetNavigationItem.leftBarButtonItems,
                state.leftBarButtonItems
            ) == false
        else {
            return
        }
        targetNavigationItem.setLeftBarButtonItems(state.leftBarButtonItems, animated: false)
    }

    private func applyRightBarButtonItemsIfNeeded(navigationItem: UINavigationItem? = nil) {
        guard let state = activeNavigationState else {
            return
        }
        let targetNavigationItem = navigationItem ?? currentNavigationItem
        guard
            WINavigationDiff.areBarButtonItemsEquivalent(
                targetNavigationItem.rightBarButtonItems,
                state.rightBarButtonItems
            ) == false
        else {
            return
        }
        targetNavigationItem.setRightBarButtonItems(state.rightBarButtonItems, animated: false)
    }

    private func applyAdditionalOverflowItemsIfNeeded(navigationItem: UINavigationItem? = nil) {
        guard let state = activeNavigationState else {
            return
        }
        let targetNavigationItem = navigationItem ?? currentNavigationItem
        guard
            WINavigationDiff.isSameOverflowItem(
                targetNavigationItem.additionalOverflowItems,
                state.additionalOverflowItems
            ) == false
        else {
            return
        }
        targetNavigationItem.additionalOverflowItems = state.additionalOverflowItems
    }

    private func clearHostManagedNavigationControls(
        from navigationItem: UINavigationItem,
        preserveTitleView: Bool = false
    ) {
        if preserveTitleView == false {
            navigationItem.titleView = nil
        }
        navigationItem.searchController = nil
        navigationItem.additionalOverflowItems = nil
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.setRightBarButtonItems(nil, animated: false)
        navigationItem.preferredSearchBarPlacement = .automatic
        navigationItem.hidesSearchBarWhenScrolling = false
    }

}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("Regular Tab Host (UIKit)") {
    WIUIKitPreviewContainer {
        let session = WISession()
        let host = WIRegularTabHostViewController()
        let context = WITabContext(controller: session, horizontalSizeClass: .regular)
        host.setTabDescriptors([.dom(), .network()], context: context)
        host.setSelectedTabID("wi_dom")
        return host
    }
}
#endif
#endif
