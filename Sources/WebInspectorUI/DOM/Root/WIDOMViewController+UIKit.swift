#if canImport(UIKit)
import UIKit
import ObservationBridge
import WebInspectorRuntime

@MainActor
public final class WIDOMViewController: UISplitViewController, UISplitViewControllerDelegate {
    enum RegularLayoutMode {
        case automatic
        case legacyPrimarySecondary
        case secondaryWithInspector
    }

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
    private var isSelectionActionPending = false
    // Keep coalescing because this navigation state is recomputed from multiple observation streams.
    private let navigationStateUpdateCoalescer = UIUpdateCoalescer()

    var regularLayoutModeOverrideForTesting: RegularLayoutMode = .automatic {
        didSet {
            hasAppliedInitialRegularColumnWidth = false
            configureSplitViewLayout()
            if isViewLoaded {
                applyRegularLayoutPresentationIfNeeded()
            }
        }
    }

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

    var inspectorColumnViewControllerForTesting: UIViewController? {
        guard #available(iOS 26.0, *) else {
            return nil
        }
        return viewController(for: .inspector)
    }

    var isInspectorColumnVisibleForTesting: Bool {
        guard #available(iOS 26.0, *) else {
            return false
        }
        return isShowing(.inspector)
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
        configureSplitViewLayout()
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
            self.applyRegularLayoutPresentationIfNeeded()
            self.scheduleNavigationStateUpdate()
        }

        startObservingNavigationStateIfNeeded()
        updateNavigationItemState()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyRegularLayoutPresentationIfNeeded()
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
        applyRegularLayoutPresentationIfNeeded()
    }

    private func updateNavigationItemState() {
        pickItem.isEnabled = inspector.hasPageWebView && !isSelectionActionPending
        pickItem.image = UIImage(systemName: pickSymbolName)
        pickItem.tintColor = (inspector.isSelectingElement || isSelectionActionPending) ? .systemBlue : .label
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
        navigationItem.setRightBarButtonItems([menuItem, pickItem], animated: false)
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

    private var resolvedRegularLayoutMode: RegularLayoutMode {
        switch regularLayoutModeOverrideForTesting {
        case .automatic:
            if #available(iOS 26.0, *) {
                return .secondaryWithInspector
            }
            return .legacyPrimarySecondary
        case .legacyPrimarySecondary:
            return .legacyPrimarySecondary
        case .secondaryWithInspector:
            return .secondaryWithInspector
        }
    }

    private func configureSplitViewLayout() {
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never

        setViewController(compactNavigationController, for: .compact)
        setViewController(nil, for: .primary)
        setViewController(nil, for: .secondary)
        if #available(iOS 26.0, *) {
            setViewController(nil, for: .inspector)
        }

        switch resolvedRegularLayoutMode {
        case .automatic:
            break
        case .legacyPrimarySecondary:
            preferredDisplayMode = .oneBesideSecondary
            setViewController(domTreeNavigationController, for: .primary)
            setViewController(elementDetailsNavigationController, for: .secondary)
            minimumPrimaryColumnWidth = 320
            maximumPrimaryColumnWidth = .greatestFiniteMagnitude
            preferredPrimaryColumnWidthFraction = 0.7
        case .secondaryWithInspector:
            preferredDisplayMode = .secondaryOnly
            setViewController(domTreeNavigationController, for: .secondary)
            if #available(iOS 26.0, *) {
                setViewController(elementDetailsNavigationController, for: .inspector)
                minimumInspectorColumnWidth = 320
                preferredInspectorColumnWidthFraction = 0.3
                maximumInspectorColumnWidth = 420
            }
        }
    }

    private func applyRegularLayoutPresentationIfNeeded() {
        guard traitCollection.horizontalSizeClass != .compact else {
            return
        }
        guard view.bounds.width > 0 else {
            return
        }

        switch resolvedRegularLayoutMode {
        case .automatic:
            return
        case .legacyPrimarySecondary:
            guard hasAppliedInitialRegularColumnWidth == false else {
                return
            }
            preferredPrimaryColumnWidth = max(minimumPrimaryColumnWidth, view.bounds.width * 0.7)
            hasAppliedInitialRegularColumnWidth = true
        case .secondaryWithInspector:
            guard #available(iOS 26.0, *) else {
                return
            }
            guard isShowing(.inspector) == false else {
                return
            }
            show(.inspector)
        }
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
            \.selectedEntry,
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
                self?.copySelection(.html)
            },
            onCopySelectorPath: { [weak self] in
                self?.copySelection(.selectorPath)
            },
            onCopyXPath: { [weak self] in
                self?.copySelection(.xpath)
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
                self?.deleteSelectedNode()
            }
        )
    }

    @objc
    private func toggleSelectionMode() {
        guard isSelectionActionPending == false else {
            return
        }

        isSelectionActionPending = true
        updateNavigationItemState()

        Task.immediateIfAvailable { [weak self, inspector] in
            defer {
                if let self {
                    self.isSelectionActionPending = false
                    self.scheduleNavigationStateUpdate()
                }
            }
            if inspector.isSelectingElement {
                await inspector.cancelSelectionMode()
            } else {
                _ = try? await inspector.beginSelectionMode()
            }
        }
    }

    private func deleteSelectedNode() {
        let inspector = inspector
        let undoManager = undoManager
        Task.immediateIfAvailable {
            await inspector.deleteSelectedNode(undoManager: undoManager)
        }
    }

    private func copySelection(_ kind: DOMSelectionCopyKind) {
        let inspector = inspector
        Task.immediateIfAvailable {
            do {
                let text = try await inspector.copySelection(kind)
                guard !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            } catch {
                return
            }
        }
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
