#if canImport(UIKit)
import UIKit

@MainActor
final class V2_WICompactTabBarController: UITabBarController, UITabBarControllerDelegate {
    private let session: V2_WISession
    private var tabCoordinator: V2_WITabHostCoordinator?
    private let tabTransitionAnimator = V2_WINoAnimationTabTransitionAnimator()
    private var nativeTabByTabID: [V2_WIDisplayTab.ID: UITab] = [:]

    init(session: V2_WISession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)

        delegate = self
        tabCoordinator = V2_WITabHostCoordinator(
            interface: session.interface,
            hostLayout: .compact,
            renderer: self
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        tabBar.scrollEdgeAppearance = tabBar.standardAppearance
    }

    func tabBarController(
        _ tabBarController: UITabBarController,
        animationControllerForTransitionFrom fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        tabTransitionAnimator
    }

    func tabBarController(
        _ tabBarController: UITabBarController,
        didSelectTab selectedTab: UITab,
        previousTab: UITab?
    ) {
        tabCoordinator?.selectDisplayTab(withID: selectedTab.identifier)
    }

    private func nativeTabs(for displayTabs: [V2_WIDisplayTab]) -> [UITab] {
        let activeTabIDs = Set(displayTabs.map(\.id))
        nativeTabByTabID = nativeTabByTabID.filter { activeTabIDs.contains($0.key) }
        return displayTabs.map(nativeTab(for:))
    }

    private func nativeTab(for displayTab: V2_WIDisplayTab) -> UITab {
        let tabID = displayTab.id
        if let nativeTab = nativeTabByTabID[tabID] {
            return nativeTab
        }

        let session = session
        let nativeTab = UITab(
            title: displayTab.title,
            image: displayTab.image,
            identifier: tabID
        ) { _ in
            V2_WITabContentFactory.makeViewController(
                for: displayTab,
                session: session,
                hostLayout: .compact
            )
        }
        nativeTabByTabID[tabID] = nativeTab
        return nativeTab
    }
}

extension V2_WICompactTabBarController: V2_WITabHostRendering {
    func renderTabs(_ displayTabs: [V2_WIDisplayTab], animated: Bool) {
        setTabs(nativeTabs(for: displayTabs), animated: animated)
    }

    func renderSelection(_ selectedDisplayTab: V2_WIDisplayTab?, animated: Bool) {
        selectedTab = tabs.first { $0.identifier == selectedDisplayTab?.id }
    }
}

@MainActor
private final class V2_WINoAnimationTabTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        0
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        guard
            let toViewController = transitionContext.viewController(forKey: .to),
            let toView = transitionContext.view(forKey: .to) ?? toViewController.view
        else {
            transitionContext.completeTransition(false)
            return
        }

        toView.frame = transitionContext.finalFrame(for: toViewController)
        transitionContext.containerView.addSubview(toView)
        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
    }
}
#endif
