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
    public let hostNavigationState = WIHostNavigationState()
    private var regularHostNavigationObservationHandles: [ObservationHandle] = []
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
        bindRegularHostNavigationState()
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
        syncHostNavigationStateFromActiveHost()
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

    private func bindRegularHostNavigationState() {
        let regularState = regularHostViewController.hostNavigationState
        regularHostNavigationObservationHandles.append(
            regularState.observe(\.searchController) { [weak self] _ in
                self?.syncHostNavigationStateFromActiveHost()
            }
        )
        regularHostNavigationObservationHandles.append(
            regularState.observe(\.preferredSearchBarPlacement) { [weak self] _ in
                self?.syncHostNavigationStateFromActiveHost()
            }
        )
        regularHostNavigationObservationHandles.append(
            regularState.observe(\.hidesSearchBarWhenScrolling) { [weak self] _ in
                self?.syncHostNavigationStateFromActiveHost()
            }
        )
        regularHostNavigationObservationHandles.append(
            regularState.observe(\.leftBarButtonItems) { [weak self] _ in
                self?.syncHostNavigationStateFromActiveHost()
            }
        )
        regularHostNavigationObservationHandles.append(
            regularState.observe(\.rightBarButtonItems) { [weak self] _ in
                self?.syncHostNavigationStateFromActiveHost()
            }
        )
        regularHostNavigationObservationHandles.append(
            regularState.observe(\.additionalOverflowItems) { [weak self] _ in
                self?.syncHostNavigationStateFromActiveHost()
            }
        )
    }

    private func syncHostNavigationStateFromActiveHost() {
        guard activeHostKind == .regular else {
            hostNavigationState.clearManagedItems()
            return
        }
        let regularState = regularHostViewController.hostNavigationState
        hostNavigationState.searchController = regularState.searchController
        hostNavigationState.preferredSearchBarPlacement = regularState.preferredSearchBarPlacement
        hostNavigationState.hidesSearchBarWhenScrolling = regularState.hidesSearchBarWhenScrolling
        hostNavigationState.leftBarButtonItems = regularState.leftBarButtonItems
        hostNavigationState.rightBarButtonItems = regularState.rightBarButtonItems
        hostNavigationState.additionalOverflowItems = regularState.additionalOverflowItems
    }
}

@MainActor
private final class WIDOMRegularSplitViewController: UISplitViewController, UISplitViewControllerDelegate, WIHostNavigationItemProvider {
    private let inspector: WIDOMModel
    private let domTreeViewController: WIDOMTreeViewController
    private let domTreeNavigationController: UINavigationController
    private let elementDetailsViewController: WIDOMDetailViewController
    private let elementDetailsNavigationController: UINavigationController
    private var hasAppliedInitialRegularColumnWidth = false
    private var hasStartedObservingHostNavigationState = false
    private let hostNavigationStateUpdateCoalescer = UIUpdateCoalescer()
    let hostNavigationState = WIHostNavigationState()

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
            self.scheduleHostNavigationStateUpdate()
        }

        startObservingHostNavigationStateIfNeeded()
        updateHostNavigationState()
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

    private func updateHostNavigationState() {
        pickItem.isEnabled = inspector.hasPageWebView
        pickItem.image = UIImage(systemName: pickSymbolName)
        pickItem.tintColor = inspector.isSelectingElement ? .systemBlue : .label
        menuItem.menu = makeDOMSecondaryMenu()

        hostNavigationState.searchController = nil
        hostNavigationState.preferredSearchBarPlacement = nil
        hostNavigationState.hidesSearchBarWhenScrolling = false
        hostNavigationState.leftBarButtonItems = nil
        hostNavigationState.rightBarButtonItems = [pickItem, menuItem]
        hostNavigationState.additionalOverflowItems = nil
    }

    private var pickSymbolName: String {
        traitCollection.horizontalSizeClass == .compact ? "viewfinder.circle" : "scope"
    }

    private func showPrimaryColumnIfNeeded() {
        guard traitCollection.horizontalSizeClass != .compact else {
            return
        }
        guard viewController(for: .primary) != nil else {
            return
        }
        show(.primary)
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

    private func startObservingHostNavigationStateIfNeeded() {
        guard hasStartedObservingHostNavigationState == false else {
            return
        }
        hasStartedObservingHostNavigationState = true

        inspector.observe(
            \.hasPageWebView,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleHostNavigationStateUpdate()
        }
        inspector.observe(
            \.isSelectingElement,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleHostNavigationStateUpdate()
        }
        inspector.selection.observe(
            \.nodeId,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.scheduleHostNavigationStateUpdate()
        }
    }

    private func scheduleHostNavigationStateUpdate() {
        hostNavigationStateUpdateCoalescer.schedule { [weak self] in
            self?.updateHostNavigationState()
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
        .primary
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
