#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorCore
import WebInspectorDataKit
import UIKit

@MainActor
package final class DOMSplitViewController: UISplitViewController {
    private let treeViewController: DOMTreeViewController
    private let elementViewController: DOMElementViewController
    private let context: WebInspectorContext?
    private var domNavigationItems: DOMNavigationItems?
    private lazy var treeNavigationController = RegularSplitColumnNavigationController(
        rootViewController: treeViewController
    )
    private lazy var elementNavigationController = RegularSplitColumnNavigationController(
        rootViewController: elementViewController
    )

    package convenience init(context: WebInspectorContext, inspection: AttachedInspection) {
        self.init(
            treeViewController: DOMTreeViewController(context: context),
            elementViewController: DOMElementViewController(inspection: inspection),
            context: context
        )
    }

    package init(
        treeViewController: DOMTreeViewController,
        elementViewController: DOMElementViewController,
        context: WebInspectorContext? = nil
    ) {
        self.treeViewController = treeViewController
        self.elementViewController = elementViewController
        self.context = context
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
        guard let context else {
            return
        }
        let navigationItems = DOMNavigationItems(context: context)
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
        let context = DOMPreviewFixtures.makeWebInspectorContext()
        return DOMSplitViewController(
            treeViewController: DOMTreeViewController(context: context),
            elementViewController: DOMElementViewController(inspection: inspection),
            context: context
        )
    }
}
#endif
