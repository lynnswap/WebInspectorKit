#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
final class V2_DOMCompactTabNavigationController: V2_WICompactTabNavigationController {
    private let dom: V2_WIDOMRuntime
    private lazy var navigationItems = V2_DOMNavigationItems(dom: dom)

    init(
        rootViewController: UIViewController,
        dom: V2_WIDOMRuntime
    ) {
        self.dom = dom
        super.init(rootViewController: rootViewController)

        rootViewController.navigationItem.style = .browser
        navigationItems.install(on: rootViewController.navigationItem) { [weak self] in
            self?.undoManager
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
#endif
