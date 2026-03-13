#if canImport(UIKit)
import UIKit
import ObservationBridge
import WebInspectorCore

@MainActor
public final class WIDOMViewController: UIViewController, WICompactNavigationHosting {
    private enum HostKind {
        case compact
        case regular
    }

    private let store: WIDOMStore
    private let compactRootViewController: WIDOMTreeViewController
    private let compactNavigationController: UINavigationController
    private let regularHostViewController: WIDOMRegularSplitViewController

    private weak var activeHostViewController: UIViewController?
    private var activeHostKind: HostKind?
    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass?

    private var effectiveHorizontalSizeClass: UIUserInterfaceSizeClass {
        horizontalSizeClassOverrideForTesting ?? traitCollection.horizontalSizeClass
    }

    var activeHostKindForTesting: String? {
        switch activeHostKind {
        case .compact:
            return "compact"
        case .regular:
            return "regular"
        case nil:
            return nil
        }
    }

    var activeHostViewControllerForTesting: UIViewController? {
        activeHostViewController
    }

    var providesCompactNavigationController: Bool {
        true
    }

    public init(store: WIDOMStore) {
        self.store = store
        store.setUIBridge(WIDOMPlatformBridge.shared)
        self.compactRootViewController = WIDOMTreeViewController(
            store: store,
            showsNavigationControls: true
        )
        let compactNavigationController = UINavigationController(rootViewController: compactRootViewController)
        wiApplyClearNavigationBarStyle(to: compactNavigationController)
        self.compactNavigationController = compactNavigationController
        self.regularHostViewController = WIDOMRegularSplitViewController(store: store)

        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        rebuildHost(force: true)

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.rebuildHost()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuildHost()
    }

    private func rebuildHost(force: Bool = false) {
        let targetHostKind: HostKind = effectiveHorizontalSizeClass == .compact ? .compact : .regular
        guard force || activeHostKind != targetHostKind else {
            return
        }
        activeHostKind = targetHostKind

        let nextHost: UIViewController
        switch targetHostKind {
        case .compact:
            nextHost = compactNavigationController
        case .regular:
            nextHost = regularHostViewController
        }
        installHost(nextHost)
    }

    private func installHost(_ host: UIViewController) {
        if let current = activeHostViewController, current !== host {
            current.willMove(toParent: nil)
            current.view.removeFromSuperview()
            current.removeFromParent()
            activeHostViewController = nil
        }

        guard activeHostViewController !== host else {
            return
        }

        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        activeHostViewController = host
    }

}

@MainActor
private final class WIDOMRegularSplitViewController: UISplitViewController, UISplitViewControllerDelegate {
    private let store: WIDOMStore
    private let domTreeViewController: WIDOMTreeViewController
    private let domTreeNavigationController: UINavigationController
    private let elementDetailsViewController: WIDOMDetailViewController
    private let elementDetailsNavigationController: UINavigationController
    private var hasAppliedInitialRegularColumnWidth = false
    private var hasStartedObservingNavigationState = false
    private var navigationObservationHandles: Set<ObservationHandle> = []
    // Keep coalescing because this navigation state is recomputed from multiple observation streams.
    private let navigationStateUpdateCoalescer = UIUpdateCoalescer()

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

    init(store: WIDOMStore) {
        self.store = store
        store.setUIBridge(WIDOMPlatformBridge.shared)
        let domTreeViewController = WIDOMTreeViewController(
            store: store,
            showsNavigationControls: false
        )
        self.domTreeViewController = domTreeViewController
        let domTreeNavigationController = UINavigationController(rootViewController: domTreeViewController)
        wiApplyClearNavigationBarStyle(to: domTreeNavigationController)
        domTreeNavigationController.setNavigationBarHidden(true, animated: false)
        self.domTreeNavigationController = domTreeNavigationController

        let elementDetailsViewController = WIDOMDetailViewController(
            store: store,
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

        minimumPrimaryColumnWidth = 320
        maximumPrimaryColumnWidth = .greatestFiniteMagnitude
        preferredPrimaryColumnWidthFraction = 0.7
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
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

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyInitialRegularColumnWidthIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyInitialRegularColumnWidthIfNeeded()
    }

    private func updateNavigationItemState() {
        pickItem.isEnabled = store.hasPageWebView
        pickItem.image = UIImage(systemName: pickSymbolName)
        pickItem.tintColor = store.isSelectingElement ? .systemBlue : .label
        menuItem.menu = makeDOMSecondaryMenu()

        applyNavigationItemState(to: navigationItem)
        if let hostNavigationItem = parent?.navigationItem {
            applyNavigationItemState(to: hostNavigationItem)
        }
    }

    private func applyNavigationItemState(to navigationItem: UINavigationItem) {
        navigationItem.searchController = nil
        navigationItem.preferredSearchBarPlacement = .automatic
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.setRightBarButtonItems([pickItem, menuItem], animated: false)
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

        store.observe(
            \.hasPageWebView,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationStateUpdate()
        }
        .store(in: &navigationObservationHandles)
        store.observe(
            \.isSelectingElement,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleNavigationStateUpdate()
        }
        .store(in: &navigationObservationHandles)
        store.session.graphStore.observe(
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
            hasSelection: store.selectedEntry != nil,
            hasPageWebView: store.hasPageWebView,
            onCopyHTML: { [weak self] in
                self?.store.copySelection(.html)
            },
            onCopySelectorPath: { [weak self] in
                self?.store.copySelection(.selectorPath)
            },
            onCopyXPath: { [weak self] in
                self?.store.copySelection(.xpath)
            },
            onReloadInspector: { [weak self] in
                guard let self else {
                    return
                }
                Task {
                    await self.store.reloadFrontend()
                }
            },
            onReloadPage: { [weak self] in
                self?.store.session.reloadPage()
            },
            onDeleteNode: { [weak self] in
                self?.store.deleteSelectedNode(undoManager: self?.undoManager)
            }
        )
    }

    @objc
    private func toggleSelectionMode() {
        store.toggleSelectionMode()
    }

    func splitViewController(
        _ splitViewController: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        .primary
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
#Preview("DOM Root (UIKit)") {
    let store = WIDOMPreviewFixtures.makeStore(mode: .selected)
    WIDOMPreviewFixtures.bootstrapDOMTreeForPreview(store)
    return WIDOMViewController(store: store)
}
#endif


#endif
