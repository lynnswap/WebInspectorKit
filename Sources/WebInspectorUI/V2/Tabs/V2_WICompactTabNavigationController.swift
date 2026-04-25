#if canImport(UIKit)
import UIKit

@MainActor
class V2_WICompactTabNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
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
