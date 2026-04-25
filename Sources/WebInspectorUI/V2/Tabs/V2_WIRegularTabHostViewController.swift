#if canImport(UIKit)
import ObservationBridge
import UIKit

@MainActor
final class V2_WIRegularTabContentViewController: UINavigationController {
    private let session: V2_WISession
    private let interface: V2_WIInterfaceModel
    private var observationHandles: Set<ObservationHandle> = []
    private var rootViewControllerByTabID: [V2_WITab.ID: UIViewController] = [:]
    private var isApplyingSegmentSelection = false

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
        navigationBar.prefersLargeTitles = false
        wiApplyClearNavigationBarStyle(to: self)
        installSegments()
        bindModel()
        render()
    }

    @objc
    private func handleSegmentSelectionChanged(_ sender: UISegmentedControl) {
        guard isApplyingSegmentSelection == false else {
            return
        }
        let selectedIndex = sender.selectedSegmentIndex
        guard selectedIndex != UISegmentedControl.noSegment,
              interface.tabs.indices.contains(selectedIndex) else {
            return
        }

        interface.selectTab(interface.tabs[selectedIndex].id)
    }

    private func bindModel() {
        observationHandles.removeAll()
        interface.observe(\.selectedTab) { [weak self] _ in
            self?.syncSelection()
        }
        .store(in: &observationHandles)
    }

    private func render() {
        guard isViewLoaded else {
            return
        }

        syncSelection()
    }

    private func installSegments() {
        segmentedControl.removeAllSegments()
        for (index, tab) in interface.tabs.enumerated() {
            segmentedControl.insertSegment(withTitle: tab.title, at: index, animated: false)
        }
    }

    private func syncSelection() {
        syncSegmentSelection()
        displaySelectedTab()
    }

    private func syncSegmentSelection() {
        guard let selectedIndex = selectedSegmentIndex else {
            return
        }
        guard segmentedControl.selectedSegmentIndex != selectedIndex else {
            return
        }

        isApplyingSegmentSelection = true
        segmentedControl.selectedSegmentIndex = selectedIndex
        isApplyingSegmentSelection = false
    }

    private var selectedSegmentIndex: Int? {
        interface.tabs.firstIndex { $0.id == interface.selectedTab }
    }

    private func displaySelectedTab() {
        guard let selectedTab = interface.selectedTabModel else {
            return
        }
        let viewController = rootViewController(for: selectedTab)
        guard viewControllers.first !== viewController else {
            updateNavigationItem(for: viewController)
            return
        }

        setViewControllers([viewController], animated: false)
        updateNavigationItem(for: viewController)
    }

    private func rootViewController(for tab: V2_WITab) -> UIViewController {
        if let viewController = rootViewControllerByTabID[tab.id] {
            return viewController
        }

        let viewController = tab.makeViewController(session: session, hostLayout: .regular)
        rootViewControllerByTabID[tab.id] = viewController
        return viewController
    }

    private func updateNavigationItem(for viewController: UIViewController) {
        viewController.navigationItem.style = .browser
        viewController.navigationItem.centerItemGroups = [segmentItemGroup]
    }
}

#endif
