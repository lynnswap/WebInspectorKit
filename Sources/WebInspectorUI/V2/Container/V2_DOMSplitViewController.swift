#if canImport(UIKit)
import UIKit

@MainActor
final class V2_DOMSplitViewController: UISplitViewController {
    private let domTreeNavigationController = V2_DOMSplitViewController.makeNavigationController(hidesNavigationBar: true)
    private let elementDetailsNavigationController = V2_DOMSplitViewController.makeNavigationController(hidesNavigationBar: true)

    init() {
        super.init(style: .doubleColumn)
        configureSplitViewLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    private func configureSplitViewLayout() {
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never
        
        // When in compact mode, DOMSplitViewController only displays the DOM tree.
        setViewController(domTreeNavigationController, for: .compact)
        setViewController(nil, for: .primary)
        setViewController(nil, for: .secondary)
        if #available(iOS 26.0, *) {
            setViewController(nil, for: .inspector)
        }

        if #available(iOS 26.0, *) {
            preferredDisplayMode = .secondaryOnly
            setViewController(domTreeNavigationController, for: .secondary)
            setViewController(elementDetailsNavigationController, for: .inspector)
            minimumInspectorColumnWidth = 320
            maximumInspectorColumnWidth = .greatestFiniteMagnitude
            preferredInspectorColumnWidthFraction = 0.3
        } else {
            preferredDisplayMode = .oneBesideSecondary
            setViewController(domTreeNavigationController, for: .primary)
            setViewController(elementDetailsNavigationController, for: .secondary)
            minimumPrimaryColumnWidth = 320
            maximumPrimaryColumnWidth = .greatestFiniteMagnitude
            preferredPrimaryColumnWidthFraction = 0.7
        }
    }

    private static func makeNavigationController(hidesNavigationBar: Bool) -> UINavigationController {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .clear
        let navigationController = UINavigationController(rootViewController: viewController)
        wiApplyClearNavigationBarStyle(to: navigationController)
        navigationController.setNavigationBarHidden(hidesNavigationBar, animated: false)
        return navigationController
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("V2 DOM Split") {
    V2_DOMSplitViewController()
}
#endif
#endif
