#if canImport(UIKit)
import ObservationBridge
import UIKit

@MainActor
final class V2_WICompactTabBarController: UITabBarController, UITabBarControllerDelegate {
    private let session: V2_WISession
    private let interface: V2_WIInterfaceModel
    private var tabObservationHandles: Set<ObservationHandle> = []
    private var viewControllerByTabID: [V2_WITab.ID: UIViewController] = [:]

    init(session: V2_WISession) {
        self.session = session
        self.interface = session.interface
        super.init(nibName: nil, bundle: nil)
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
        delegate = self
        tabBar.scrollEdgeAppearance = tabBar.standardAppearance
        installNativeTabs()
        bindModel()
        render()
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab candidateTab: UITab) -> Bool {
        interface.containsTab(withID: candidateTab.identifier)
    }

    func tabBarController(
        _ tabBarController: UITabBarController,
        didSelectTab selectedTab: UITab,
        previousTab: UITab?
    ) {
        guard interface.containsTab(withID: selectedTab.identifier) else {
            return
        }
        interface.selectTab(selectedTab.identifier)
    }

    private func bindModel() {
        tabObservationHandles.removeAll()
        interface.observe(\.selectedTab) { [weak self] _ in
            self?.syncNativeSelection()
        }
        .store(in: &tabObservationHandles)
    }

    private func render() {
        guard isViewLoaded else {
            return
        }

        syncNativeSelection()
    }

    private func installNativeTabs() {
        setTabs(interface.tabs.map(makeNativeTab), animated: false)
    }

    private func makeNativeTab(for tab: V2_WITab) -> UITab {
        let viewController = viewController(for: tab)
        return UITab(
            title: tab.title,
            image: tab.image,
            identifier: tab.id
        ) { _ in
            viewController
        }
    }

    private func syncNativeSelection() {
        guard let nativeTab = nativeTab(for: interface.selectedTab),
              selectedTab !== nativeTab else {
            return
        }
        selectedTab = nativeTab
    }

    private func nativeTab(for tabID: V2_WITab.ID?) -> UITab? {
        guard let tabID else {
            return nil
        }
        return tabs.first { $0.identifier == tabID }
    }

    private func viewController(for tab: V2_WITab) -> UIViewController {
        if let viewController = viewControllerByTabID[tab.id] {
            return viewController
        }

        let viewController = tab.makeViewController(session: session)
        viewControllerByTabID[tab.id] = viewController
        return viewController
    }
}
#endif
