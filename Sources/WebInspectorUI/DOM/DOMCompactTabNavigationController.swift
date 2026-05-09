#if canImport(UIKit)
import UIKit
import WebInspectorRuntime

@MainActor
final class DOMCompactTabNavigationController: WICompactTabNavigationController {
    private let dom: WIDOMRuntime
    private lazy var navigationItems = DOMNavigationItems(dom: dom)

    init(
        rootViewController: UIViewController,
        dom: WIDOMRuntime
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
