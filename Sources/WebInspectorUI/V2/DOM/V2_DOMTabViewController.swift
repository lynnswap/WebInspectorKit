#if canImport(UIKit)
import UIKit

@MainActor
final class V2_DOMTabViewController: UIViewController {
    private enum ContentKind {
        case compact
        case regular
    }

    private let session: V2_WISession
    private var activeContentKind: ContentKind?
    private var activeViewController: UIViewController?

    private lazy var compactViewController = V2_DOMCompactViewController(session: session)
    private lazy var regularViewController = V2_DOMSplitViewController(session: session)

    init(session: V2_WISession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        rebuildLayout(forceContentReplacement: true)
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (self: Self, _) in
            self.rebuildLayout()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        rebuildLayout()
    }

    private var effectiveContentKind: ContentKind {
        traitCollection.horizontalSizeClass == .compact ? .compact : .regular
    }

    private func rebuildLayout(forceContentReplacement: Bool = false) {
        let targetContentKind = effectiveContentKind
        guard forceContentReplacement || activeContentKind != targetContentKind else {
            return
        }
        installContent(of: targetContentKind)
    }

    private func installContent(of kind: ContentKind) {
        removeActiveContentViewController()

        let viewController = viewController(for: kind)
        addChild(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewController.view)
        NSLayoutConstraint.activate([
            viewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            viewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        viewController.didMove(toParent: self)

        activeContentKind = kind
        activeViewController = viewController
    }

    private func removeActiveContentViewController() {
        guard let activeViewController else {
            return
        }

        activeViewController.willMove(toParent: nil)
        activeViewController.view.removeFromSuperview()
        activeViewController.removeFromParent()
        self.activeViewController = nil
        activeContentKind = nil
    }

    private func viewController(for kind: ContentKind) -> UIViewController {
        switch kind {
        case .compact:
            compactViewController
        case .regular:
            regularViewController
        }
    }
}
#endif
