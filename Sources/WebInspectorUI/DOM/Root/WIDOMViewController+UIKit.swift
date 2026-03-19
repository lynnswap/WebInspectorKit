#if canImport(UIKit)
import UIKit
import ObservationBridge
import WebInspectorRuntime

@MainActor
public final class WIDOMViewController: UISplitViewController, UISplitViewControllerDelegate {
    private let inspector: WIDOMModel
    private let compactRootViewController: WIDOMTreeViewController
    private let compactNavigationController: UINavigationController
    private let domTreeViewController: WIDOMTreeViewController
    private let domTreeNavigationController: UINavigationController
    private let elementDetailsViewController: WIDOMDetailViewController
    private let elementDetailsNavigationController: UINavigationController
    private var hasAppliedInitialRegularColumnWidth = false
    private var hasStartedObservingNavigationState = false
    private var navigationObservationHandles: Set<ObservationHandle> = []
    // Keep coalescing because this navigation state is recomputed from multiple observation streams.
    private let navigationStateUpdateCoalescer = UIUpdateCoalescer()

    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass? {
        didSet {
            traitOverrides.horizontalSizeClass = horizontalSizeClassOverrideForTesting ?? .unspecified
        }
    }

    var activeHostKindForTesting: String? {
        let sizeClass = horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass
        return sizeClass == .compact ? "compact" : "regular"
    }

    var activeHostViewControllerForTesting: UIViewController? {
        self
    }

    var splitViewControllerForTesting: UISplitViewController {
        self
    }

    var primaryColumnViewControllerForTesting: UIViewController? {
        viewController(for: .primary)
    }

    var secondaryColumnViewControllerForTesting: UIViewController? {
        viewController(for: .secondary)
    }

    var compactColumnViewControllerForTesting: UIViewController? {
        viewController(for: .compact)
    }

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

    public init(inspector: WIDOMModel) {
        self.inspector = inspector

        let compactRootViewController = WIDOMTreeViewController(
            inspector: inspector,
            showsNavigationControls: true
        )
        self.compactRootViewController = compactRootViewController
        let compactNavigationController = UINavigationController(rootViewController: compactRootViewController)
        wiApplyClearNavigationBarStyle(to: compactNavigationController)
        self.compactNavigationController = compactNavigationController

        let domTreeViewController = WIDOMTreeViewController(
            inspector: inspector,
            showsNavigationControls: false
        )
        self.domTreeViewController = domTreeViewController
        let domTreeNavigationController = UINavigationController(rootViewController: domTreeViewController)
        wiApplyClearNavigationBarStyle(to: domTreeNavigationController)
        domTreeNavigationController.setNavigationBarHidden(true, animated: false)
        self.domTreeNavigationController = domTreeNavigationController

        let elementDetailsViewController = WIDOMDetailViewController(
            inspector: inspector,
            showsNavigationControls: false
        )
        self.elementDetailsViewController = elementDetailsViewController
        let elementDetailsNavigationController = UINavigationController(rootViewController: elementDetailsViewController)
        wiApplyClearNavigationBarStyle(to: elementDetailsNavigationController)
        elementDetailsNavigationController.setNavigationBarHidden(true, animated: false)
        self.elementDetailsNavigationController = elementDetailsNavigationController

        super.init(style: .doubleColumn)

        delegate = self
        title = nil
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never
        preferredDisplayMode = .oneBesideSecondary

        setViewController(domTreeNavigationController, for: .primary)
        setViewController(elementDetailsNavigationController, for: .secondary)
        setViewController(compactNavigationController, for: .compact)

        minimumPrimaryColumnWidth = 320
        maximumPrimaryColumnWidth = .greatestFiniteMagnitude
        preferredPrimaryColumnWidthFraction = 0.7
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            if self.traitCollection.horizontalSizeClass == .compact {
                self.hasAppliedInitialRegularColumnWidth = false
            }
            self.applyInitialRegularColumnWidthIfNeeded()
            self.scheduleNavigationStateUpdate()
        }

        startObservingNavigationStateIfNeeded()
        updateNavigationItemState()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyInitialRegularColumnWidthIfNeeded()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateNavigationItemState()
    }

    public override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        updateNavigationItemState()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyInitialRegularColumnWidthIfNeeded()
    }

    private func updateNavigationItemState() {
        pickItem.isEnabled = inspector.hasPageWebView
        pickItem.image = UIImage(systemName: pickSymbolName)
        pickItem.tintColor = inspector.isSelectingElement ? .systemBlue : .label
        menuItem.menu = makeDOMSecondaryMenu()

        if let hostNavigationItem = parent?.navigationItem,
           parent?.navigationController != nil {
            clearNavigationItemState(on: navigationItem)
            applyNavigationItemState(to: hostNavigationItem)
            return
        }

        applyNavigationItemState(to: navigationItem)
    }

    private func applyNavigationItemState(to navigationItem: UINavigationItem) {
        navigationItem.searchController = nil
        navigationItem.preferredSearchBarPlacement = .automatic
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.setRightBarButtonItems([pickItem, menuItem], animated: false)
        navigationItem.additionalOverflowItems = nil
    }

    private func clearNavigationItemState(on navigationItem: UINavigationItem) {
        navigationItem.searchController = nil
        navigationItem.preferredSearchBarPlacement = .automatic
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.setRightBarButtonItems(nil, animated: false)
        navigationItem.additionalOverflowItems = nil
    }

    private var pickSymbolName: String {
        traitCollection.horizontalSizeClass == .compact ? "viewfinder.circle" : "scope"
    }

    private func applyInitialRegularColumnWidthIfNeeded() {
        guard traitCollection.horizontalSizeClass != .compact else {
            return
        }
        guard hasAppliedInitialRegularColumnWidth == false else {
            return
        }
        guard view.bounds.width > 0 else {
            return
        }
        preferredPrimaryColumnWidth = max(minimumPrimaryColumnWidth, view.bounds.width * 0.7)
        hasAppliedInitialRegularColumnWidth = true
    }

    private func startObservingNavigationStateIfNeeded() {
        guard hasStartedObservingNavigationState == false else {
            return
        }
        hasStartedObservingNavigationState = true

        inspector.observe(
            \.hasPageWebView,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationStateUpdate()
        }
        .store(in: &navigationObservationHandles)
        inspector.observe(
            \.isSelectingElement,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationStateUpdate()
        }
        .store(in: &navigationObservationHandles)
        inspector.session.graphStore.observe(
            \.selectedID,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationStateUpdate()
        }
        .store(in: &navigationObservationHandles)
    }

    private func scheduleNavigationStateUpdate() {
        navigationStateUpdateCoalescer.schedule { [weak self] in
            self?.updateNavigationItemState()
        }
    }

    private func makeDOMSecondaryMenu() -> UIMenu {
        DOMSecondaryMenuBuilder.makeMenu(
            hasSelection: inspector.selectedEntry != nil,
            hasPageWebView: inspector.hasPageWebView,
            onCopyHTML: { [weak self] in
                self?.inspector.copySelection(.html)
            },
            onCopySelectorPath: { [weak self] in
                self?.inspector.copySelection(.selectorPath)
            },
            onCopyXPath: { [weak self] in
                self?.inspector.copySelection(.xpath)
            },
            onReloadInspector: { [weak self] in
                guard let self else {
                    return
                }
                Task {
                    await self.inspector.reloadInspector()
                }
            },
            onReloadPage: { [weak self] in
                self?.inspector.session.reloadPage()
            },
            onDeleteNode: { [weak self] in
                self?.inspector.deleteSelectedNode(undoManager: self?.undoManager)
            }
        )
    }

    @objc
    private func toggleSelectionMode() {
        inspector.toggleSelectionMode()
    }

    public func splitViewController(
        _ splitViewController: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        _ = splitViewController
        _ = proposedTopColumn
        return .compact
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("DOM Root (UIKit)") {
    WIUIKitPreviewContainer {
        let inspector = WIDOMPreviewFixtures.makeInspector(mode: .selected)
        WIDOMPreviewFixtures.bootstrapDOMTreeForPreview(inspector)
        return WIDOMViewController(inspector: inspector)
    }
}
#endif


#endif
