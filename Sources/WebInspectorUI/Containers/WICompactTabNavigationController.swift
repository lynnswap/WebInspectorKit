#if canImport(UIKit)
import UIKit

@MainActor
class WICompactTabNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        rootViewController.wiDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        view.backgroundColor = .clear
        navigationBar.prefersLargeTitles = false
        wiApplyClearNavigationBarStyle(to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
#endif
