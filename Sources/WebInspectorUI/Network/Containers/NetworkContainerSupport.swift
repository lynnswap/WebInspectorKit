#if canImport(UIKit)
import UIKit

package struct WebInspectorDrawsBackgroundTrait: UITraitDefinition {
    package static let defaultValue = true
}

extension UITraitCollection {
    package var webInspectorDrawsBackground: Bool {
        self[WebInspectorDrawsBackgroundTrait.self]
    }
}

extension UIMutableTraits {
    package var webInspectorDrawsBackground: Bool {
        get { self[WebInspectorDrawsBackgroundTrait.self] }
        set { self[WebInspectorDrawsBackgroundTrait.self] = newValue }
    }
}

@MainActor
package struct WebInspectorBackgroundPolicy: Equatable {
    package var drawsBackground: Bool

    package init(drawsBackground: Bool) {
        self.drawsBackground = drawsBackground
    }

    package var backgroundColor: UIColor {
        drawsBackground ? .systemBackground : .clear
    }
}

extension UIViewController {
    @MainActor
    package var webInspectorBackgroundPolicy: WebInspectorBackgroundPolicy {
        WebInspectorBackgroundPolicy(
            drawsBackground: traitCollection.webInspectorDrawsBackground
        )
    }

    func webInspectorDetachFromContainerForReuse() {
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
func webInspectorApplyNavigationControllerBackground(to navigationController: UINavigationController) {
    let backgroundPolicy = navigationController.webInspectorBackgroundPolicy
    navigationController.view.backgroundColor = backgroundPolicy.backgroundColor
}

@MainActor
final class RegularSplitColumnNavigationController: UINavigationController {
    override init(rootViewController: UIViewController) {
        rootViewController.webInspectorDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        webInspectorApplyNavigationControllerBackground(to: self)
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

    override func viewDidLoad() {
        super.viewDidLoad()
        webInspectorApplyNavigationControllerBackground(to: self)
        registerForTraitChanges([WebInspectorDrawsBackgroundTrait.self]) { (self: Self, _) in
            webInspectorApplyNavigationControllerBackground(to: self)
        }
    }
}

@MainActor
package final class RegularSplitRootViewController: UIViewController {
    private let contentViewController: UIViewController

    package init(contentViewController: UIViewController) {
        contentViewController.webInspectorDetachFromContainerForReuse()
        self.contentViewController = contentViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        registerForTraitChanges([WebInspectorDrawsBackgroundTrait.self]) { (self: Self, _) in
            self.applyBackgroundFromTraits()
        }
        installContentViewController()
    }

    private func applyBackgroundFromTraits() {
        view.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
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
