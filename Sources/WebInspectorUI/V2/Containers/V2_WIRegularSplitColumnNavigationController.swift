#if canImport(UIKit)
import UIKit

@MainActor
final class V2_WIRegularSplitColumnNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        rootViewController.wiDetachFromV2ContainerForReuse()
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
