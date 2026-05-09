#if canImport(UIKit)
import UIKit

@MainActor
final class WIRegularSplitColumnNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        rootViewController.wiDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        wiApplyClearNavigationBarStyle(to: self)
        setNavigationBarHidden(true, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNavigationBarHidden(true, animated: false)
    }
}
#endif
