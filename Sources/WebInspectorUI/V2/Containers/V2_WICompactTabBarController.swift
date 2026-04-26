#if canImport(UIKit)
import ObservationBridge
import UIKit

@MainActor
final class V2_WICompactTabBarController: UITabBarController, UITabBarControllerDelegate {
    private let session: V2_WISession
    private let tabTransitionAnimator = V2_WINoAnimationTabTransitionAnimator()
    private var nativeTabByItemID: [V2_TabDisplayItem.ID: UITab] = [:]
    private var observationHandles: Set<ObservationHandle> = []
    private var isRenderingSelection = false

    init(session: V2_WISession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)

        delegate = self
        renderTabsAndSelection(animated: false)
        bindInterface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observationHandles.removeAll()
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
        guard isRenderingSelection == false else {
            return
        }
        session.interface.selectItem(withID: selectedTab.identifier)
    }

    private func bindInterface() {
        session.interface.observe(\.tabs) { [weak self] _ in
            self?.renderTabsAndSelection(animated: true)
        }
        .store(in: &observationHandles)

        session.interface.observe(\.selectedItemID) { [weak self] _ in
            self?.renderSelection()
        }
        .store(in: &observationHandles)
    }

    private func renderTabsAndSelection(animated: Bool) {
        let displayItems = session.interface.displayItems(for: .compact)
        renderSelectionFromInterface {
            setTabs(nativeTabs(for: displayItems), animated: animated)
            renderSelection()
        }
    }

    private func renderSelection() {
        let selectedDisplayItem = session.interface.resolvedSelection(for: .compact)
        let nextSelectedTab = tabs.first { $0.identifier == selectedDisplayItem?.id }
        guard selectedTab?.identifier != nextSelectedTab?.identifier else {
            return
        }
        renderSelectionFromInterface {
            selectedTab = nextSelectedTab
        }
    }

    private func renderSelectionFromInterface(_ render: () -> Void) {
        let wasRenderingSelection = isRenderingSelection
        isRenderingSelection = true
        defer {
            isRenderingSelection = wasRenderingSelection
        }
        render()
    }

    private func nativeTabs(for displayItems: [V2_TabDisplayItem]) -> [UITab] {
        let activeItemIDs = Set(displayItems.map(\.id))
        nativeTabByItemID = nativeTabByItemID.filter { activeItemIDs.contains($0.key) }
        return displayItems.map(nativeTab(for:))
    }

    private func nativeTab(for displayItem: V2_TabDisplayItem) -> UITab {
        let itemID = displayItem.id
        if let nativeTab = nativeTabByItemID[itemID] {
            return nativeTab
        }

        let descriptor = session.interface.descriptor(for: displayItem)
        let tabs = session.interface.tabs
        let session = session
        let nativeTab = UITab(
            title: descriptor?.title ?? "",
            image: descriptor?.image,
            identifier: itemID
        ) { _ in
            V2_TabContentFactory.makeViewController(
                for: displayItem,
                session: session,
                hostLayout: .compact,
                tabs: tabs
            )
        }
        nativeTabByItemID[itemID] = nativeTab
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
