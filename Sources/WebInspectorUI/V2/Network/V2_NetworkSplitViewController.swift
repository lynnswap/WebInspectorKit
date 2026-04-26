#if canImport(UIKit)
import UIKit

@MainActor
final class V2_NetworkSplitViewController: UISplitViewController {
    private let listViewController: V2_NetworkListViewController
    private let primaryViewController: V2_NetworkListColumnNavigationController
    private let secondaryViewController = V2_WIRegularSplitColumnNavigationController(
        rootViewController: V2_NetworkSplitViewController.makeEmptyViewController()
    )

    init(listViewController: V2_NetworkListViewController) {
        self.listViewController = listViewController
        primaryViewController = V2_NetworkListColumnNavigationController(
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

@MainActor
private final class V2_NetworkListColumnNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        rootViewController.wiDetachFromV2ContainerForReuse()
        super.init(rootViewController: rootViewController)
        wiApplyClearNavigationBarStyle(to: self)
        navigationBar.prefersLargeTitles = false
        setNavigationBarHidden(false, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNavigationBarHidden(false, animated: false)
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
