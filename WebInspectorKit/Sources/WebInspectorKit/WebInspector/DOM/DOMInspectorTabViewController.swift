#if canImport(UIKit)
import UIKit

@MainActor
final class DOMInspectorTabViewController: UISplitViewController, UISplitViewControllerDelegate {
    private let domTreeViewController: DOMTreeTabViewController
    private let elementDetailsViewController: ElementDetailsTabViewController
    private let hiddenPrimaryViewController: UIViewController
    private var hasAppliedInitialRegularColumnWidth = false

    init(inspector: WIDOMTabViewModel) {
        self.domTreeViewController = DOMTreeTabViewController(
            inspector: inspector,
            showsNavigationControls: false
        )
        self.elementDetailsViewController = ElementDetailsTabViewController(
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
        }
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

    func splitViewController(
        _ splitViewController: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        return .supplementary
    }
}

#elseif canImport(AppKit)
import AppKit

@MainActor
final class DOMInspectorTabViewController: NSSplitViewController {
    private let inspector: WIDOMTabViewModel
    private let domTreeViewController: DOMTreeTabViewController
    private let elementDetailsViewController: ElementDetailsTabViewController

    init(inspector: WIDOMTabViewModel) {
        self.inspector = inspector
        self.domTreeViewController = DOMTreeTabViewController(inspector: inspector)
        self.elementDetailsViewController = ElementDetailsTabViewController(inspector: inspector)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
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
