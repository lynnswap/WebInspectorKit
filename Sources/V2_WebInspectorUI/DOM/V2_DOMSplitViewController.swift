#if canImport(UIKit)
import UIKit
import V2_WebInspectorRuntime

@MainActor
package final class V2_DOMSplitViewController: UISplitViewController {
    private let treeViewController: V2_DOMTreeViewController
    private let elementViewController: V2_DOMElementViewController
    private lazy var treeNavigationController = V2_RegularSplitColumnNavigationController(
        rootViewController: treeViewController
    )
    private lazy var elementNavigationController = V2_RegularSplitColumnNavigationController(
        rootViewController: elementViewController
    )

    package convenience init(session: V2_InspectorSession) {
        self.init(
            treeViewController: V2_DOMTreeViewController(session: session),
            elementViewController: V2_DOMElementViewController(dom: session.dom)
        )
    }

    package init(
        treeViewController: V2_DOMTreeViewController,
        elementViewController: V2_DOMElementViewController
    ) {
        self.treeViewController = treeViewController
        self.elementViewController = elementViewController
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
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("V2 DOM Split") {
    let dom = V2_DOMPreviewFixtures.makeDOMSession()
    return V2_DOMSplitViewController(
        treeViewController: V2_DOMTreeViewController(dom: dom),
        elementViewController: V2_DOMElementViewController(dom: dom)
    )
}
#endif
#endif
