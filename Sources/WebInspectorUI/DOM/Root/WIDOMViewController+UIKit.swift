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

    private let inspector: WIDOMInspector
    private let compactRootViewController: WIDOMTreeViewController
    private let compactNavigationController: UINavigationController
    private let domTreeViewController: WIDOMTreeViewController
    private let domTreeNavigationController: UINavigationController
    private let elementDetailsViewController: WIDOMDetailViewController
    private let elementDetailsNavigationController: UINavigationController
    private var hasAppliedInitialRegularColumnWidth = false
    private var hasStartedObservingPickItemState = false
    private var pickItemObservationHandles: Set<ObservationHandle> = []

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

    var resolvedSecondaryMenuForTesting: UIMenu {
        makeDOMSecondaryMenu()
    }

    var usesDeferredSecondaryMenuForTesting: Bool {
        menuItem.menu?.children.contains(where: { $0 is UIDeferredMenuElement }) == true
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
            menu: makeDeferredDOMSecondaryMenu()
        )
        item.accessibilityIdentifier = "WI.DOM.MenuButton"
        return item
    }()

    public init(inspector: WIDOMInspector) {
        self.inspector = inspector

        let compactRootViewController = WIDOMTreeViewController(
            inspector: inspector
        )
        self.compactRootViewController = compactRootViewController
        let compactNavigationController = UINavigationController(rootViewController: compactRootViewController)
        wiApplyClearNavigationBarStyle(to: compactNavigationController)
        self.compactNavigationController = compactNavigationController

        let domTreeViewController = WIDOMTreeViewController(
            inspector: inspector
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
            self.updatePickItemAppearance()
            self.applyNavigationPlacement()
        }

        startObservingPickItemStateIfNeeded()
        updatePickItemAppearance()
        applyNavigationPlacement()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyRegularLayoutPresentationIfNeeded()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyNavigationPlacement()
    }

    public override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        applyNavigationPlacement()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyRegularLayoutPresentationIfNeeded()
    }

    private func updatePickItemAppearance() {
        pickItem.isEnabled = inspector.hasPageWebView
        pickItem.image = UIImage(systemName: pickSymbolName)
        pickItem.tintColor = inspector.isSelectingElement ? .systemBlue : .label
    }

    private func applyNavigationPlacement() {
        for navigationItem in managedNavigationItems() {
            clearNavigationItemState(on: navigationItem)
        }

        installNavigationItems(on: resolveActiveNavigationItem())
    }

    private func installNavigationItems(on navigationItem: UINavigationItem) {
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

    private func startObservingPickItemStateIfNeeded() {
        guard hasStartedObservingPickItemState == false else {
            return
        }
        hasStartedObservingPickItemState = true

        inspector.observe(
            \.hasPageWebView,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.updatePickItemAppearance()
        }
        .store(in: &pickItemObservationHandles)
        inspector.observe(
            \.isSelectingElement,
            options: [.removeDuplicates]
        ) { [weak self] _ in
            self?.updatePickItemAppearance()
        }
        .store(in: &pickItemObservationHandles)
    }

    private func resolveActiveNavigationItem() -> UINavigationItem {
        if traitCollection.horizontalSizeClass == .compact {
            return compactRootViewController.navigationItem
        }
        if let hostNavigationItem,
           parent?.navigationController != nil {
            return hostNavigationItem
        }
        return navigationItem
    }

    private var hostNavigationItem: UINavigationItem? {
        parent?.navigationItem
    }

    private func managedNavigationItems() -> [UINavigationItem] {
        var items: [UINavigationItem] = [
            navigationItem,
            compactRootViewController.navigationItem
        ]
        if let hostNavigationItem,
           items.contains(where: { $0 === hostNavigationItem }) == false {
            items.append(hostNavigationItem)
        }
        return items
    }

    private func makeDeferredDOMSecondaryMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion((self?.makeDOMSecondaryMenu() ?? UIMenu()).children)
            }
        ])
    }

    private func makeDOMSecondaryMenu() -> UIMenu {
        DOMSecondaryMenuBuilder.makeMenu(
            hasSelection: inspector.document.selectedNode != nil,
            hasPageWebView: inspector.hasPageWebView,
            onCopyHTML: { [weak self] in
                self?.copySelectedHTML()
            },
            onCopySelectorPath: { [weak self] in
                self?.copySelectedSelectorPath()
            },
            onCopyXPath: { [weak self] in
                self?.copySelectedXPath()
            },
            onReloadInspector: { [weak self] in
                guard let self else { return }
                Task { _ = await self.inspector.reloadDocument() }
            },
            onReloadPage: { [weak self] in
                guard let self else { return }
                Task { _ = await self.inspector.reloadPage() }
            },
            onDeleteNode: { [weak self] in
                self?.deleteSelection()
            }
        )
    }

    @objc
    private func toggleSelectionMode() {
        inspector.requestSelectionModeToggle()
        updatePickItemAppearance()
    }

    private func deleteSelection() {
        let inspector = inspector
        let undoManager = undoManager
        let selectedNodeID = inspector.document.selectedNode?.id
        Task {
            _ = await inspector.deleteNode(nodeID: selectedNodeID, undoManager: undoManager)
        }
    }

    func invokeDeleteSelectionForTesting() {
        deleteSelection()
    }

    private func copySelectedHTML() {
        let inspector = inspector
        Task.immediateIfAvailable {
            do {
                let text = try await inspector.copySelectedHTML()
                guard !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            } catch {
                return
            }
        }
    }

    private func copySelectedSelectorPath() {
        let inspector = inspector
        Task.immediateIfAvailable {
            do {
                let text = try await inspector.copySelectedSelectorPath()
                guard !text.isEmpty else {
                    return
                }
                UIPasteboard.general.string = text
            } catch {
                return
            }
        }
    }

    private func copySelectedXPath() {
        let inspector = inspector
        Task.immediateIfAvailable {
            do {
                let text = try await inspector.copySelectedXPath()
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
