#if canImport(UIKit)
import ObservationBridge
import UIKit
import WebInspectorUIBase

@MainActor
package final class CompactTabBarController: UITabBarController, UITabBarControllerDelegate {
    private let session: WebInspectorSession
    private let tabTransitionAnimator = NoAnimationTabTransitionAnimator()
    private var nativeTabByItemID: [WebInspectorTab.DisplayItem.ID: UITab] = [:]
    private var renderedContentRevision: Int?
    private var interfaceObservation: PortableObservationTracking.Token?
    private var isRenderingSelection = false

    package init(session: WebInspectorSession) {
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

    isolated deinit {
        interfaceObservation?.cancel()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        if #available(iOS 26.0, *) {
            webInspectorRegisterForBackgroundTraitChanges { tabBarController in
                tabBarController.applyBackgroundFromTraits()
            }
        }
        tabBar.scrollEdgeAppearance = tabBar.standardAppearance
    }

    private func applyBackgroundFromTraits() {
        view.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
    }

    package func tabBarController(
        _ tabBarController: UITabBarController,
        animationControllerForTransitionFrom fromVC: UIViewController,
        to toVC: UIViewController
    ) -> (any UIViewControllerAnimatedTransitioning)? {
        tabTransitionAnimator
    }

    package func tabBarController(
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
        interfaceObservation = withPortableContinuousObservation { [weak self] event in
            guard let self else { return }
            renderInterface(session.interface, animated: event.kind != .initial)
        }
    }

    private func renderTabsAndSelection(animated: Bool) {
        renderInterface(session.interface, animated: animated)
    }

    private func renderInterface(_ interface: InterfaceModel, animated: Bool) {
        let displayItems = interface.displayItems(for: .compact)
        let selectedDisplayItem = interface.resolvedSelection(for: .compact)
        let contentRevision = interface.contextBoundContentRevision
        let shouldRebuildContent = renderedContentRevision.map { $0 != contentRevision } ?? false
        renderSelectionFromInterface {
            if shouldRebuildContent {
                nativeTabByItemID.removeAll()
            }
            setTabsIfNeeded(for: displayItems, animated: animated, force: shouldRebuildContent)
            renderSelection(selectedDisplayItem)
            renderedContentRevision = contentRevision
        }
    }

    private func setTabsIfNeeded(
        for displayItems: [WebInspectorTab.DisplayItem],
        animated: Bool,
        force: Bool = false
    ) {
        let nextItemIDs = displayItems.map(\.id)
        guard force || tabs.map(\.identifier) != nextItemIDs else {
            return
        }
        setTabs(nativeTabs(for: displayItems), animated: animated)
    }

    private func renderSelection(_ selectedDisplayItem: WebInspectorTab.DisplayItem?) {
        let nextSelectedTab = tabs.first { $0.identifier == selectedDisplayItem?.id }
        guard selectedTab?.identifier != nextSelectedTab?.identifier else {
            return
        }
        selectedTab = nextSelectedTab
    }

    private func renderSelectionFromInterface(_ render: () -> Void) {
        let wasRenderingSelection = isRenderingSelection
        isRenderingSelection = true
        defer {
            isRenderingSelection = wasRenderingSelection
        }
        render()
    }

    private func nativeTabs(for displayItems: [WebInspectorTab.DisplayItem]) -> [UITab] {
        let activeItemIDs = Set(displayItems.map(\.id))
        nativeTabByItemID = nativeTabByItemID.filter { activeItemIDs.contains($0.key) }
        return displayItems.map(nativeTab(for:))
    }

    private func nativeTab(for displayItem: WebInspectorTab.DisplayItem) -> UITab {
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
            WebInspectorTab.ContentFactory.makeViewController(
                for: displayItem,
                session: session,
                hostLayout: .compact,
                tabs: tabs
            )
        }
        nativeTabByItemID[itemID] = nativeTab
        return nativeTab
    }

    package var currentUITabsForTesting: [UITab] {
        tabs
    }

    package var displayedTabIdentifiersForTesting: [String] {
        tabs.map(\.identifier)
    }
}

@MainActor
private final class NoAnimationTabTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
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
