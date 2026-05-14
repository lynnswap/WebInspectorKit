#if canImport(UIKit)
import UIKit

extension UIViewController {
    func v2WIDetachFromContainerForReuse() {
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

@MainActor
func v2WIApplyClearNavigationBarStyle(to navigationController: UINavigationController) {
    navigationController.view.backgroundColor = .clear
    navigationController.navigationBar.isTranslucent = true

    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.backgroundColor = .clear
    appearance.backgroundEffect = nil
    appearance.shadowColor = nil

    navigationController.navigationBar.standardAppearance = appearance
    navigationController.navigationBar.scrollEdgeAppearance = appearance
    navigationController.navigationBar.compactAppearance = appearance
    navigationController.navigationBar.compactScrollEdgeAppearance = appearance
}

@MainActor
final class V2_RegularSplitColumnNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        rootViewController.v2WIDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        v2WIApplyClearNavigationBarStyle(to: self)
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

@MainActor
package final class V2_RegularSplitRootViewController: UIViewController {
    private let contentViewController: UIViewController

    package init(contentViewController: UIViewController) {
        contentViewController.v2WIDetachFromContainerForReuse()
        self.contentViewController = contentViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        installContentViewController()
    }

    private func installContentViewController() {
        guard contentViewController.parent == nil else {
            return
        }

        addChild(contentViewController)
        contentViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentViewController.view)
        NSLayoutConstraint.activate([
            contentViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            contentViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        contentViewController.didMove(toParent: self)
        applyContentNavigationItem()
    }

    private func applyContentNavigationItem() {
        navigationItem.leadingItemGroups = contentViewController.navigationItem.leadingItemGroups
        navigationItem.trailingItemGroups = contentViewController.navigationItem.trailingItemGroups
        navigationItem.additionalOverflowItems = contentViewController.navigationItem.additionalOverflowItems
    }
}
#endif
