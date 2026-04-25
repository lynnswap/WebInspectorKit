#if canImport(UIKit)
import UIKit

extension V2_WITab {
    public static var dom: V2_WITab {
        V2_WITab(
            title: "DOM",
            image: UIImage(systemName: "chevron.left.forwardslash.chevron.right"),
            identifier: "dom",
            hostLayoutViewControllerProvider: { _, session, hostLayout in
                switch hostLayout {
                case .compact:
                    V2_WICompactTabNavigationController(
                        rootViewController: V2_DOMCompactViewController(session: session)
                    )
                case .regular:
                    V2_WIRegularSplitRootViewController(
                        contentViewController: V2_DOMSplitViewController(session: session)
                    )
                }
            }
        )
    }

    public static var network: V2_WITab {
        V2_WITab(
            title: "Network",
            image: UIImage(systemName: "waveform.path.ecg.rectangle"),
            identifier: "network",
            hostLayoutViewControllerProvider: { _, _, hostLayout in
                switch hostLayout {
                case .compact:
                    V2_WICompactTabNavigationController(
                        rootViewController: V2_NetworkCompactViewController()
                    )
                case .regular:
                    V2_WIRegularSplitRootViewController(
                        contentViewController: V2_NetworkSplitViewController()
                    )
                }
            }
        )
    }

    public static var defaults: [V2_WITab] {
        [.dom, .network]
    }
}

@MainActor
private final class V2_WICompactTabNavigationController: UINavigationController {
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

@MainActor
private final class V2_WIRegularSplitRootViewController: UIViewController {
    private let contentViewController: UIViewController

    init(contentViewController: UIViewController) {
        self.contentViewController = contentViewController
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
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
