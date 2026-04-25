#if canImport(UIKit)
import ObservationBridge
import UIKit

@MainActor
final class V2_WICompactTabBarController: UITabBarController, UITabBarControllerDelegate {
    private let session: V2_WISession
    private let interface: V2_WIInterfaceModel
    private let tabTransitionAnimator = V2_WINoAnimationTabTransitionAnimator()
    private var tabObservationHandles: Set<ObservationHandle> = []
    private var nativeTabByTabID: [V2_WITab.ID: UITab] = [:]

    init(session: V2_WISession) {
        self.session = session
        self.interface = session.interface
        super.init(nibName: nil, bundle: nil)

        delegate = self
        let tabs = nativeTabs(for: interface.tabs)
        setTabs(tabs, animated: false)
        selectedTab = tabs.first { $0.identifier == interface.selectedTab?.id }

        interface.observe(\.tabs) { [weak self] _ in
            guard let self else {
                return
            }
            let tabs = nativeTabs(for: interface.tabs)
            setTabs(tabs, animated: true)
            selectedTab = tabs.first { $0.identifier == interface.selectedTab?.id }
        }
        .store(in: &tabObservationHandles)

        interface.observe(\.selectedTab) { [weak self] selectedTab in
            guard let self else {
                return
            }
            self.selectedTab = self.tabs.first { $0.identifier == selectedTab?.id }
        }
        .store(in: &tabObservationHandles)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        tabObservationHandles.removeAll()
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
        interface.selectTab(withID: selectedTab.identifier)
    }

    private func nativeTabs(for tabs: [V2_WITab]) -> [UITab] {
        let activeTabIDs = Set(tabs.map(\.id))
        nativeTabByTabID = nativeTabByTabID.filter { activeTabIDs.contains($0.key) }
        return tabs.map(nativeTab(for:))
    }

    private func nativeTab(for tab: V2_WITab) -> UITab {
        if let nativeTab = nativeTabByTabID[tab.id] {
            return nativeTab
        }

        let session = session
        let nativeTab = UITab(
            title: tab.title,
            image: tab.image,
            identifier: tab.id
        ) { _ in
            V2_WITabContentFactory.makeViewController(
                for: tab,
                session: session,
                hostLayout: .compact
            )
        }
        nativeTabByTabID[tab.id] = nativeTab
        return nativeTab
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
