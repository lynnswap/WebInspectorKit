#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
final class V2_DOMSplitViewController: UISplitViewController {
    private let dom: V2_WIDOMRuntime
    private let treeViewController: V2_DOMTreeViewController
    private let elementViewController: V2_DOMElementViewController
    private lazy var navigationItems = V2_DOMNavigationItems(dom: dom)
    private lazy var domTreeViewController = V2_WIRegularSplitColumnNavigationController(
        rootViewController: treeViewController
    )
    private lazy var elementDetailsViewController = V2_WIRegularSplitColumnNavigationController(
        rootViewController: elementViewController
    )

    init(
        dom: V2_WIDOMRuntime,
        treeViewController: V2_DOMTreeViewController,
        elementViewController: V2_DOMElementViewController
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

#Preview("V2 DOM Split") {
    let dom = V2_WIDOMRuntime()
    V2_DOMSplitViewController(
        dom: dom,
        treeViewController: V2_DOMTreeViewController(dom: dom),
        elementViewController: V2_DOMElementViewController(dom: dom)
    )
}
#endif
#endif
