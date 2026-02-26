#if canImport(UIKit)
import UIKit

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
    private let navigationUpdateCoalescer = UIUpdateCoalescer()
    private weak var activeNavigationItemProvider: (any WIHostNavigationItemProvider)?

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
            self.scheduleNavigationUIUpdate()
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
        activeNavigationItemProvider?.onHostNavigationItemsDidChange = nil
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
        activeNavigationItemProvider?.onHostNavigationItemsDidChange = nil
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
        if let provider = selectedContentViewController as? (any WIHostNavigationItemProvider) {
            provider.applyHostNavigationItems(to: navigationItem)
        } else {
            clearHostManagedNavigationControls(from: navigationItem, preserveTitleView: true)
        }
    }

    private func synchronizeNavigationProvider() {
        let provider = selectedContentViewController as? (any WIHostNavigationItemProvider)

        let currentID = activeNavigationItemProvider.map { ObjectIdentifier($0) }
        let newID = provider.map { ObjectIdentifier($0) }
        guard currentID != newID else {
            return
        }

        activeNavigationItemProvider?.onHostNavigationItemsDidChange = nil
        activeNavigationItemProvider = provider
        activeNavigationItemProvider?.onHostNavigationItemsDidChange = { [weak self] in
            self?.scheduleNavigationUIUpdate()
        }
    }

    private func scheduleNavigationUIUpdate() {
        navigationUpdateCoalescer.schedule { [weak self] in
            self?.updateNavigationUI()
        }
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
    }
}
#endif
