#if canImport(UIKit)
import ObservationBridge
import UIKit

@MainActor
final class V2_WIRegularTabContentViewController: UINavigationController {
    private let session: V2_WISession
    private let interface: V2_WIInterfaceModel
    private var observationHandles: Set<ObservationHandle> = []
    private var rootViewControllerByTabID: [V2_WITab.ID: UIViewController] = [:]

    private lazy var segmentBarButtonItem: UIBarButtonItem = {
        let item = UIBarButtonItem(customView: segmentedControl)
        if #available(iOS 26.0, *) {
            item.hidesSharedBackground = true
        }
        return item
    }()
    private lazy var segmentItemGroup = UIBarButtonItemGroup(
        barButtonItems: [segmentBarButtonItem],
        representativeItem: nil
    )
    private lazy var segmentedControl: UISegmentedControl = {
        let control = UISegmentedControl(items: [])
        control.addTarget(self, action: #selector(handleSegmentSelectionChanged(_:)), for: .valueChanged)
        return control
    }()

    init(session: V2_WISession) {
        self.session = session
        self.interface = session.interface
        super.init(nibName: nil, bundle: nil)

        navigationBar.prefersLargeTitles = false
        wiApplyClearNavigationBarStyle(to: self)

        setSegments(for: interface.tabs)
        segmentedControl.selectedSegmentIndex = interface.selectedTabIndex ?? UISegmentedControl.noSegment
        if let selectedTab = interface.selectedTab {
            setViewControllers([rootViewController(for: selectedTab)], animated: false)
        }

        interface.observe(\.tabs) { [weak self] tabs in
            guard let self else {
                return
            }
            let activeTabIDs = Set(tabs.map(\.id))
            rootViewControllerByTabID = rootViewControllerByTabID.filter { activeTabIDs.contains($0.key) }
            setSegments(for: tabs)
            segmentedControl.selectedSegmentIndex = interface.selectedTabIndex ?? UISegmentedControl.noSegment
            if let selectedTab = interface.selectedTab {
                setViewControllers([rootViewController(for: selectedTab)], animated: true)
            }
        }
        .store(in: &observationHandles)

        interface.observe(\.selectedTab) { [weak self] selectedTab in
            guard let self else {
                return
            }
            segmentedControl.selectedSegmentIndex = interface.selectedTabIndex ?? UISegmentedControl.noSegment
            guard let selectedTab else {
                setViewControllers([], animated: false)
                return
            }
            let viewController = rootViewController(for: selectedTab)
            guard viewControllers.first !== viewController else {
                return
            }
            setViewControllers([viewController], animated: false)
        }
        .store(in: &observationHandles)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationHandles.removeAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    @objc
    private func handleSegmentSelectionChanged(_ sender: UISegmentedControl) {
        guard sender.selectedSegmentIndex != UISegmentedControl.noSegment else {
            return
        }
        interface.selectTab(at: sender.selectedSegmentIndex)
    }

    private func setSegments(for tabs: [V2_WITab]) {
        segmentedControl.removeAllSegments()
        for (index, tab) in tabs.enumerated() {
            segmentedControl.insertSegment(withTitle: tab.title, at: index, animated: false)
        }
    }

    private func rootViewController(for tab: V2_WITab) -> UIViewController {
        if let viewController = rootViewControllerByTabID[tab.id] {
            return viewController
        }

        let viewController = V2_WITabContentFactory.makeViewController(
            for: tab,
            session: session,
            hostLayout: .regular
        )
        viewController.navigationItem.style = .browser
        viewController.navigationItem.centerItemGroups = [segmentItemGroup]
        rootViewControllerByTabID[tab.id] = viewController
        return viewController
    }
}

#endif
