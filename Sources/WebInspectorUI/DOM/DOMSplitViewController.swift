#if canImport(UIKit)
import WebInspectorCore
import UIKit

@MainActor
package final class DOMSplitViewController: UISplitViewController {
    private let treeViewController: DOMTreeViewController
    private let elementViewController: DOMElementViewController
    private let inspection: AttachedInspection?
    private let inspector: InspectorSession?
    private var domNavigationItems: DOMNavigationItems?
    private lazy var treeNavigationController = RegularSplitColumnNavigationController(
        rootViewController: treeViewController
    )
    private lazy var elementNavigationController = RegularSplitColumnNavigationController(
        rootViewController: elementViewController
    )

    package convenience init(inspection: AttachedInspection) {
        let inspector = InspectorSession(attachment: inspection)
        self.init(
            treeViewController: DOMTreeViewController(inspection: inspection),
            elementViewController: DOMElementViewController(inspection: inspection),
            inspection: inspection,
            inspector: inspector
        )
    }

    package init(
        treeViewController: DOMTreeViewController,
        elementViewController: DOMElementViewController,
        inspection: AttachedInspection? = nil,
        inspector: InspectorSession? = nil
    ) {
        self.treeViewController = treeViewController
        self.elementViewController = elementViewController
        self.inspection = inspection
        self.inspector = inspector
        super.init(style: .doubleColumn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { splitViewController in
                splitViewController.applyBackgroundFromTraits()
            }
        }
        configureSplitViewLayout()
        configureNavigationItem()
    }

    private func applyBackgroundFromTraits() {
        view.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
    }

    private func configureSplitViewLayout() {
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never

        if #available(iOS 26.0, *) {
            preferredDisplayMode = .secondaryOnly
            setViewController(treeNavigationController, for: .secondary)
            setViewController(elementNavigationController, for: .inspector)
            minimumInspectorColumnWidth = 320
            maximumInspectorColumnWidth = .greatestFiniteMagnitude
            preferredInspectorColumnWidthFraction = 0.3
            show(.inspector)
        } else {
            preferredDisplayMode = .oneBesideSecondary
            setViewController(treeNavigationController, for: .primary)
            setViewController(elementNavigationController, for: .secondary)
            minimumPrimaryColumnWidth = 320
            maximumPrimaryColumnWidth = .greatestFiniteMagnitude
            preferredPrimaryColumnWidthFraction = 0.7
        }
    }

    private func configureNavigationItem() {
        guard let inspector else {
            return
        }
        let navigationItems = DOMNavigationItems(inspector: inspector)
        navigationItems.install(on: navigationItem) { [weak self] in
            self?.treeViewController.domTreeUndoManager ?? self?.undoManager
        }
        domNavigationItems = navigationItems
    }
}

#if DEBUG
extension DOMSplitViewController {
    var domNavigationItemsForTesting: DOMNavigationItems? {
        domNavigationItems
    }
}
#endif

#Preview("DOM Split") {
    DOMSplitViewControllerPreview.makeViewController()
}

@MainActor
private enum DOMSplitViewControllerPreview {
    static func makeViewController() -> DOMSplitViewController {
        let dom = DOMPreviewFixtures.makeDOMSession()
        let inspection = AttachedInspection(dom: dom)
        return DOMSplitViewController(
            treeViewController: DOMTreeViewController(inspection: inspection),
            elementViewController: DOMElementViewController(inspection: inspection)
        )
    }
}
#endif
