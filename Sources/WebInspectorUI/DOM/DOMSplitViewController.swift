#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
final class DOMSplitViewController: UISplitViewController {
    private let dom: WIDOMRuntime
    private let treeViewController: DOMTreeViewController
    private let elementViewController: DOMElementViewController
    private lazy var navigationItems = DOMNavigationItems(dom: dom)
    private lazy var domTreeViewController = WIRegularSplitColumnNavigationController(
        rootViewController: treeViewController
    )
    private lazy var elementDetailsViewController = WIRegularSplitColumnNavigationController(
        rootViewController: elementViewController
    )

    init(
        dom: WIDOMRuntime,
        treeViewController: DOMTreeViewController,
        elementViewController: DOMElementViewController
    ) {
        self.dom = dom
        self.treeViewController = treeViewController
        self.elementViewController = elementViewController
        super.init(style: .doubleColumn)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
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
            setViewController(domTreeViewController, for: .secondary)
            setViewController(elementDetailsViewController, for: .inspector)
            minimumInspectorColumnWidth = 320
            maximumInspectorColumnWidth = .greatestFiniteMagnitude
            preferredInspectorColumnWidthFraction = 0.3
            show(.inspector)
        } else {
            preferredDisplayMode = .oneBesideSecondary
            setViewController(domTreeViewController, for: .primary)
            setViewController(elementDetailsViewController, for: .secondary)
            minimumPrimaryColumnWidth = 320
            maximumPrimaryColumnWidth = .greatestFiniteMagnitude
            preferredPrimaryColumnWidthFraction = 0.7
        }
    }

    private func configureNavigationItem() {
        navigationItems.install(on: navigationItem) { [weak self] in
            self?.undoManager
        }
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("DOM Split") {
    let dom = WIDOMRuntime()
    DOMSplitViewController(
        dom: dom,
        treeViewController: DOMTreeViewController(dom: dom),
        elementViewController: DOMElementViewController(dom: dom)
    )
}
#endif
#endif
