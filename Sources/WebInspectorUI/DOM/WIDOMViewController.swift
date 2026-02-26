#if canImport(UIKit)
import UIKit
import ObservationsCompat
import WebInspectorRuntime

@MainActor
public final class WIDOMViewController: UIViewController, WIHostNavigationItemProvider, WICompactNavigationHosting {
    private enum HostKind {
        case compact
        case regular
    }

    private let inspector: WIDOMModel
    private let compactRootViewController: WIDOMTreeViewController
    private let compactNavigationController: UINavigationController
    private let regularHostViewController: WIDOMRegularSplitViewController

    private weak var activeHostViewController: UIViewController?
    private var activeHostKind: HostKind?
    var horizontalSizeClassOverrideForTesting: UIUserInterfaceSizeClass?

    public var onHostNavigationItemsDidChange: (() -> Void)?

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

    public init(inspector: WIDOMModel) {
        self.inspector = inspector
        self.compactRootViewController = WIDOMTreeViewController(
            inspector: inspector,
            showsNavigationControls: true
        )
        let compactNavigationController = UINavigationController(rootViewController: compactRootViewController)
        wiApplyClearNavigationBarStyle(to: compactNavigationController)
        self.compactNavigationController = compactNavigationController
        self.regularHostViewController = WIDOMRegularSplitViewController(inspector: inspector)

        super.init(nibName: nil, bundle: nil)

        self.regularHostViewController.onHostNavigationItemsDidChange = { [weak self] in
            guard let self, self.activeHostKind == .regular else {
                return
            }
            self.onHostNavigationItemsDidChange?()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        rebuildHost(force: true)

        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.rebuildHost()
        }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuildHost()
    }

    public func applyHostNavigationItems(to navigationItem: UINavigationItem) {
        if activeHostKind == nil {
            rebuildHost(force: true)
        }

        guard activeHostKind == .regular else {
            clearHostManagedNavigationControls(from: navigationItem)
            return
        }
        regularHostViewController.applyHostNavigationItems(to: navigationItem)
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
        onHostNavigationItemsDidChange?()
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
        host.view.backgroundColor = .clear
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

    private func clearHostManagedNavigationControls(from navigationItem: UINavigationItem) {
        navigationItem.titleView = nil
        navigationItem.searchController = nil
        navigationItem.additionalOverflowItems = nil
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.setRightBarButtonItems(nil, animated: false)
    }
}

@MainActor
private final class WIDOMRegularSplitViewController: UISplitViewController, UISplitViewControllerDelegate, WIHostNavigationItemProvider {
    private let inspector: WIDOMModel
    private let domTreeViewController: WIDOMTreeViewController
    private let elementDetailsViewController: WIDOMDetailViewController
    private let hiddenPrimaryViewController: UIViewController
    private var hasAppliedInitialRegularColumnWidth = false
    private var hasStartedObservingHostNavigationState = false
    private let hostNavigationUpdateCoalescer = UIUpdateCoalescer()

    var onHostNavigationItemsDidChange: (() -> Void)?

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

    init(inspector: WIDOMModel) {
        self.inspector = inspector
        self.domTreeViewController = WIDOMTreeViewController(
            inspector: inspector,
            showsNavigationControls: false
        )
        self.elementDetailsViewController = WIDOMDetailViewController(
            inspector: inspector,
            showsNavigationControls: false
        )
        let hiddenPrimary = UIViewController()
        hiddenPrimary.view.backgroundColor = .clear
        self.hiddenPrimaryViewController = hiddenPrimary
        super.init(style: .tripleColumn)

        delegate = self
        title = nil
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never
        preferredDisplayMode = .oneBesideSecondary

        setViewController(hiddenPrimaryViewController, for: .primary)
        setViewController(domTreeViewController, for: .supplementary)
        setViewController(elementDetailsViewController, for: .secondary)

        minimumPrimaryColumnWidth = 0
        maximumPrimaryColumnWidth = 1
        preferredPrimaryColumnWidthFraction = 0
        minimumSupplementaryColumnWidth = 320
        maximumSupplementaryColumnWidth = .greatestFiniteMagnitude
        preferredSupplementaryColumnWidthFraction = 0.7
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
            self.scheduleHostNavigationUpdate()
        }

        startObservingHostNavigationStateIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyInitialRegularColumnWidthIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyInitialRegularColumnWidthIfNeeded()
        showPrimaryColumnIfNeeded()
    }

    func applyHostNavigationItems(to navigationItem: UINavigationItem) {
        pickItem.isEnabled = inspector.hasPageWebView
        pickItem.image = UIImage(systemName: pickSymbolName)
        pickItem.tintColor = inspector.isSelectingElement ? .systemBlue : .label
        menuItem.menu = makeDOMSecondaryMenu()

        navigationItem.searchController = nil
        navigationItem.additionalOverflowItems = nil
        navigationItem.setLeftBarButtonItems(nil, animated: false)
        navigationItem.setRightBarButtonItems([pickItem, menuItem], animated: false)
    }

    private var pickSymbolName: String {
        traitCollection.horizontalSizeClass == .compact ? "viewfinder.circle" : "scope"
    }

    private func showPrimaryColumnIfNeeded() {
        guard traitCollection.horizontalSizeClass != .compact else {
            return
        }
        guard viewController(for: .supplementary) != nil else {
            return
        }
        show(.supplementary)
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
        preferredSupplementaryColumnWidth = max(minimumSupplementaryColumnWidth, view.bounds.width * 0.7)
        hasAppliedInitialRegularColumnWidth = true
    }

    private func startObservingHostNavigationStateIfNeeded() {
        guard hasStartedObservingHostNavigationState == false else {
            return
        }
        hasStartedObservingHostNavigationState = true

        inspector.observe(
            \.hasPageWebView,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleHostNavigationUpdate()
        }
        inspector.observe(
            \.isSelectingElement,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleHostNavigationUpdate()
        }
        inspector.selection.observe(
            \.nodeId,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleHostNavigationUpdate()
        }
    }

    private func scheduleHostNavigationUpdate() {
        hostNavigationUpdateCoalescer.schedule { [weak self] in
            self?.onHostNavigationItemsDidChange?()
        }
    }

    private func makeDOMSecondaryMenu() -> UIMenu {
        DOMSecondaryMenuBuilder.makeMenu(
            hasSelection: inspector.selection.nodeId != nil,
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

    func splitViewController(
        _ splitViewController: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        .supplementary
    }
}

#elseif canImport(AppKit)
import AppKit

@MainActor
public final class WIDOMViewController: NSSplitViewController {
    private let inspector: WIDOMModel
    private let domTreeViewController: WIDOMTreeViewController
    private let elementDetailsViewController: WIDOMDetailViewController

    public init(inspector: WIDOMModel) {
        self.inspector = inspector
        self.domTreeViewController = WIDOMTreeViewController(inspector: inspector)
        self.elementDetailsViewController = WIDOMDetailViewController(inspector: inspector)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        let domTreeItem = NSSplitViewItem(viewController: domTreeViewController)
        domTreeItem.minimumThickness = 320
        domTreeItem.maximumThickness = 760
        domTreeItem.preferredThicknessFraction = 0.48
        domTreeItem.canCollapse = false

        let elementItem = NSSplitViewItem(viewController: elementDetailsViewController)
        elementItem.minimumThickness = 300

        splitViewItems = [domTreeItem, elementItem]
    }
}
#endif
