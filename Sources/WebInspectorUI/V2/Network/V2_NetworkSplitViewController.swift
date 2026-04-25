#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
final class V2_NetworkCompactViewController: V2_NetworkListViewController {
    init(network: V2_WINetworkRuntime) {
        super.init(inspector: network.model)
    }
}

@MainActor
final class V2_NetworkSplitViewController: UISplitViewController {
    private let primaryViewController: V2_WIRegularSplitColumnNavigationController
    private let secondaryViewController = V2_WIRegularSplitColumnNavigationController(
        rootViewController: V2_NetworkSplitViewController.makeEmptyViewController()
    )

    init(network: V2_WINetworkRuntime) {
        primaryViewController = V2_WIRegularSplitColumnNavigationController(
            rootViewController: V2_NetworkListViewController(inspector: network.model)
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

#Preview("V2 Network Split") {
    V2_NetworkSplitViewController(network: V2_WINetworkRuntime())
}
#endif
#endif
