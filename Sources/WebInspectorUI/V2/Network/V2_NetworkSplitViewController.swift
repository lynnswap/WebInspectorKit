#if canImport(UIKit)
import UIKit

@MainActor
final class V2_NetworkSplitViewController: UISplitViewController {
    private let primaryViewController: V2_WIRegularSplitColumnNavigationController
    private let secondaryViewController = V2_WIRegularSplitColumnNavigationController(
        rootViewController: V2_NetworkSplitViewController.makeEmptyViewController()
    )

    init(listViewController: V2_NetworkListViewController) {
        primaryViewController = V2_WIRegularSplitColumnNavigationController(
            rootViewController: listViewController
        )
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
        preferredDisplayMode = .oneBesideSecondary

        setViewController(primaryViewController, for: .primary)
        setViewController(secondaryViewController, for: .secondary)
    }

    private static func makeEmptyViewController() -> UIViewController {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .clear
        return viewController
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI
import WebInspectorRuntime

#Preview("V2 Network Split") {
    let network = V2_WINetworkRuntime()
    V2_NetworkSplitViewController(
        listViewController: V2_NetworkListViewController(inspector: network.model)
    )
}
#endif
#endif
