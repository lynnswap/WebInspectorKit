#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
package final class DOMSplitViewController: UISplitViewController {
    private let treeViewController: DOMTreeViewController
    private let elementViewController: DOMElementViewController
    private let session: InspectorSession?
    private var domNavigationItems: DOMNavigationItems?
    private lazy var treeNavigationController = RegularSplitColumnNavigationController(
        rootViewController: treeViewController
    )
    private lazy var elementNavigationController = RegularSplitColumnNavigationController(
        rootViewController: elementViewController
    )

    package convenience init(session: InspectorSession) {
        self.init(
            treeViewController: DOMTreeViewController(session: session),
            elementViewController: DOMElementViewController(session: session),
            session: session
        )
    }

    package init(
        treeViewController: DOMTreeViewController,
        elementViewController: DOMElementViewController,
        session: InspectorSession? = nil
    ) {
        self.treeViewController = treeViewController
        self.elementViewController = elementViewController
        self.session = session
        super.init(style: .doubleColumn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        configureSplitViewLayout()
        configureNavigationItem()
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
        guard let session else {
            return
        }
        let navigationItems = DOMNavigationItems(session: session)
        navigationItems.install(on: navigationItem) { [weak self] in
            self?.treeViewController.domTreeUndoManager ?? self?.undoManager
        }
        domNavigationItems = navigationItems
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("DOM Split") {
    let dom = DOMPreviewFixtures.makeDOMSession()
    return DOMSplitViewController(
        treeViewController: DOMTreeViewController(dom: dom),
        elementViewController: DOMElementViewController(dom: dom)
    )
}
#endif
#endif
