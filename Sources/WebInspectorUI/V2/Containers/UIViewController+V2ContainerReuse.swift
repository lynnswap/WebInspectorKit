#if canImport(UIKit)
import UIKit

extension UIViewController {
    func wiDetachFromV2ContainerForReuse() {
        if let navigationController = parent as? UINavigationController,
           navigationController.viewControllers.contains(where: { $0 === self }) {
            navigationController.setViewControllers(
                navigationController.viewControllers.filter { $0 !== self },
                animated: false
            )
        }

        guard parent != nil else {
            return
        }

        willMove(toParent: nil)
        view.removeFromSuperview()
        removeFromParent()
    }
}
#endif
