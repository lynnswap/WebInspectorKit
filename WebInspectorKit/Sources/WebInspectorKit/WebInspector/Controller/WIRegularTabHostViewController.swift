#if canImport(UIKit)
import UIKit
import ObservationsCompat

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

    private static let domTabID = WIUIKitTabLayoutPolicy.domTabID
    private static let networkTabID = "wi_network"

    var onSelectedTabIDChange: ((WITabDescriptor.ID) -> Void)?

    private var tabDescriptors: [WITabDescriptor] = []
    private var context: WITabContext?
    private var tabRootByTabID: [WITabDescriptor.ID: TabRoot] = [:]
    private var selectedTabID: WITabDescriptor.ID?
    private var isApplyingSegmentSelection = false
    private var hasStartedObservingDOMState = false
    private let domNavigationUpdateCoalescer = UIUpdateCoalescer()
    private weak var lastBuiltInNavigationItem: UINavigationItem?

    private let placeholderViewController: UIViewController

    private lazy var segmentedControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [])
        control.addTarget(self, action: #selector(handleSegmentSelectionChanged(_:)), for: .valueChanged)
        control.accessibilityIdentifier = "WI.Regular.TabSwitcher"
        return control
    }()

    private lazy var pickItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: pickSymbolName),
            style: .plain,
            target: self,
            action: #selector(toggleSelectionMode)
        )
        item.accessibilityIdentifier = "WI.DOM.PickButton"
        return item
    }()

    private lazy var menuItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: makeDOMSecondaryMenu()
        )
        item.accessibilityIdentifier = "WI.DOM.MenuButton"
        return item
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
        startObservingDOMStateIfNeeded()

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
        clearHostManagedNavigationControls(from: currentNavigationItem)
    }

    var displayedTabIDsForTesting: [WITabDescriptor.ID] {
        tabDescriptors.map(\.id)
    }

    private var pickSymbolName: String {
        traitCollection.horizontalSizeClass == .compact ? "viewfinder.circle" : "scope"
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

        guard viewControllers.first !== tabRoot.rootViewController else {
            return
        }

        setViewControllers([tabRoot.rootViewController], animated: false)
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

        guard let selectedTabID else {
            if lastBuiltInNavigationItem === navigationItem {
                clearHostManagedNavigationControls(from: navigationItem, preserveTitleView: true)
            }
            lastBuiltInNavigationItem = nil
            return
        }

        guard selectedTabID == Self.domTabID else {
            if selectedTabID == Self.networkTabID,
               let networkTab = selectedContentViewController as? NetworkTabViewController {
                networkTab.applyNavigationItems(to: navigationItem)
                lastBuiltInNavigationItem = navigationItem
            } else if lastBuiltInNavigationItem === navigationItem {
                clearHostManagedNavigationControls(from: navigationItem, preserveTitleView: true)
                lastBuiltInNavigationItem = nil
            } else {
                lastBuiltInNavigationItem = nil
            }
            return
        }

        applyDOMNavigationControls(to: navigationItem)
        lastBuiltInNavigationItem = navigationItem
    }

    private func applyDOMNavigationControls(to navigationItem: UINavigationItem) {
        guard let context else {
            clearHostManagedNavigationControls(from: navigationItem)
            return
        }

        let domInspector = context.controller.dom
        pickItem.isEnabled = domInspector.hasPageWebView
        pickItem.image = UIImage(systemName: pickSymbolName)
        pickItem.tintColor = domInspector.isSelectingElement ? .systemBlue : .label
        menuItem.menu = makeDOMSecondaryMenu()

        navigationItem.searchController = nil
        navigationItem.additionalOverflowItems = nil
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.setRightBarButtonItems([pickItem, menuItem], animated: false)
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

    private func startObservingDOMStateIfNeeded() {
        guard hasStartedObservingDOMState == false else {
            return
        }
        guard let domInspector = context?.controller.dom else {
            return
        }
        hasStartedObservingDOMState = true

        domInspector.observe(
            \.hasPageWebView,
            retention: .automatic,
            removeDuplicates: true
        ) { [weak self] _ in
            self?.scheduleDOMNavigationUpdateIfNeeded()
        }
        domInspector.observe(
            \.isSelectingElement,
            retention: .automatic,
            removeDuplicates: true
        ) { [weak self] _ in
            self?.scheduleDOMNavigationUpdateIfNeeded()
        }
        domInspector.selection.observe(
            \.nodeId,
            retention: .automatic,
            removeDuplicates: true
        ) { [weak self] _ in
            self?.scheduleDOMNavigationUpdateIfNeeded()
        }
    }

    private func scheduleDOMNavigationUpdateIfNeeded() {
        domNavigationUpdateCoalescer.schedule { [weak self] in
            guard self?.selectedTabID == Self.domTabID else {
                return
            }
            self?.updateNavigationUI()
        }
    }

    private func makeDOMSecondaryMenu() -> UIMenu {
        guard let domInspector = context?.controller.dom else {
            return UIMenu(title: "")
        }

        return DOMSecondaryMenuBuilder.makeMenu(
            hasSelection: domInspector.selection.nodeId != nil,
            hasPageWebView: domInspector.hasPageWebView,
            onCopyHTML: { [weak self] in
                self?.context?.controller.dom.copySelection(.html)
            },
            onCopySelectorPath: { [weak self] in
                self?.context?.controller.dom.copySelection(.selectorPath)
            },
            onCopyXPath: { [weak self] in
                self?.context?.controller.dom.copySelection(.xpath)
            },
            onReloadInspector: { [weak self] in
                guard let self else {
                    return
                }
                Task {
                    await self.context?.controller.dom.reloadInspector()
                }
            },
            onReloadPage: { [weak self] in
                self?.context?.controller.dom.session.reloadPage()
            },
            onDeleteNode: { [weak self] in
                self?.context?.controller.dom.deleteSelectedNode(undoManager: self?.undoManager)
            }
        )
    }

    @objc
    private func toggleSelectionMode() {
        context?.controller.dom.toggleSelectionMode()
    }
}
#endif
