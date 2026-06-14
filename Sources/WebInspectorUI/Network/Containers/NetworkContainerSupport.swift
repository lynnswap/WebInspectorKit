#if canImport(UIKit)
import UIKit

@available(iOS 26.0, *)
package struct WebInspectorDrawsBackgroundTrait: UITraitDefinition {
    package static let defaultValue = true
}

extension UITraitCollection {
    @available(iOS 26.0, *)
    package var webInspectorDrawsBackground: Bool {
        self[WebInspectorDrawsBackgroundTrait.self]
    }
}

extension UIMutableTraits {
    @available(iOS 26.0, *)
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
        if #available(iOS 26.0, *) {
            return WebInspectorBackgroundPolicy(
                drawsBackground: traitCollection.webInspectorDrawsBackground
            )
        }
        return WebInspectorBackgroundPolicy(drawsBackground: true)
    }

    @MainActor
    package func webInspectorSetDrawsBackgroundTraitOverride(_ drawsBackground: Bool) {
        if #available(iOS 26.0, *) {
            traitOverrides.webInspectorDrawsBackground = drawsBackground
        }
    }

    @available(iOS 26.0, *)
    @MainActor
    package func webInspectorRegisterForBackgroundTraitChanges(_ action: @escaping (Self) -> Void) {
        registerForTraitChanges([WebInspectorDrawsBackgroundTrait.self]) { (viewController: Self, _) in
            action(viewController)
        }
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
    // This policy owns WebInspector view backgrounds, not UIKit chrome. Leave
    // UINavigationBarAppearance to UIKit so each presentation keeps its system material.
}

@MainActor
func webInspectorConfigureScrollEdgeObservedScrollView(
    _ scrollView: UIScrollView,
    backgroundColor: UIColor,
    traitCollection: UITraitCollection
) {
    let resolvedBackgroundColor: UIColor
    if #available(iOS 26.0, *) {
        resolvedBackgroundColor = backgroundColor.resolvedColor(with: traitCollection)
    } else {
        resolvedBackgroundColor = backgroundColor
    }
    if scrollView.backgroundColor != resolvedBackgroundColor {
        scrollView.backgroundColor = resolvedBackgroundColor
    }

    if #available(iOS 26.0, *) {
        // WebInspector paints these scroll view backgrounds directly; automatic
        // edge capture can otherwise form UIKit observation/layout feedback loops.
        let hardStyle = UIScrollEdgeEffect.Style.hard
        if scrollView.topEdgeEffect.style !== hardStyle {
            scrollView.topEdgeEffect.style = hardStyle
        }
        if scrollView.bottomEdgeEffect.style !== hardStyle {
            scrollView.bottomEdgeEffect.style = hardStyle
        }
        if scrollView.topEdgeEffect.isHidden == false {
            scrollView.topEdgeEffect.isHidden = true
        }
        if scrollView.bottomEdgeEffect.isHidden == false {
            scrollView.bottomEdgeEffect.isHidden = true
        }
    }
}

@MainActor
final class RegularSplitColumnNavigationController: UINavigationController {
    private let hidesNavigationBar: Bool

    init(
        rootViewController: UIViewController,
        hidesNavigationBar: Bool = true
    ) {
        self.hidesNavigationBar = hidesNavigationBar
        rootViewController.webInspectorDetachFromContainerForReuse()
        super.init(rootViewController: rootViewController)
        webInspectorApplyNavigationControllerBackground(to: self)
        setNavigationBarHidden(hidesNavigationBar, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNavigationBarHidden(hidesNavigationBar, animated: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        webInspectorApplyNavigationControllerBackground(to: self)
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { navigationController in
                webInspectorApplyNavigationControllerBackground(to: navigationController)
            }
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
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { viewController in
                viewController.applyBackgroundFromTraits()
            }
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
