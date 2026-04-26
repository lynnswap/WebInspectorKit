#if canImport(UIKit)
import UIKit

@MainActor
final class V2_WIRegularTabContentViewController: UINavigationController {
    private let session: V2_WISession
    private var tabCoordinator: V2_WITabHostCoordinator?
    private var segmentDisplayTabIDs: [V2_WIDisplayTab.ID] = []
    private var displayedDisplayTabID: V2_WIDisplayTab.ID?

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
        super.init(nibName: nil, bundle: nil)

        navigationBar.prefersLargeTitles = false
        wiApplyClearNavigationBarStyle(to: self)

        tabCoordinator = V2_WITabHostCoordinator(
            interface: session.interface,
            hostLayout: .regular,
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
    }

    @objc
    private func handleSegmentSelectionChanged(_ sender: UISegmentedControl) {
        guard sender.selectedSegmentIndex != UISegmentedControl.noSegment else {
            return
        }
        guard segmentDisplayTabIDs.indices.contains(sender.selectedSegmentIndex) else {
            return
        }
        tabCoordinator?.selectDisplayTab(withID: segmentDisplayTabIDs[sender.selectedSegmentIndex])
    }

    private func setSegments(for displayTabs: [V2_WIDisplayTab]) {
        segmentDisplayTabIDs = displayTabs.map(\.id)
        segmentedControl.removeAllSegments()
        for (index, displayTab) in displayTabs.enumerated() {
            segmentedControl.insertSegment(withTitle: displayTab.title, at: index, animated: false)
        }
    }

    private func rootViewController(for displayTab: V2_WIDisplayTab) -> UIViewController {
        let viewController = V2_WITabContentFactory.makeViewController(
            for: displayTab,
            session: session,
            hostLayout: .regular
        )
        viewController.navigationItem.style = .browser
        viewController.navigationItem.centerItemGroups = [segmentItemGroup]
        return viewController
    }
}

extension V2_WIRegularTabContentViewController: V2_WITabHostRendering {
    func renderTabs(_ displayTabs: [V2_WIDisplayTab], animated: Bool) {
        let activeTabIDs = Set(displayTabs.map(\.id))
        if let displayedDisplayTabID,
           activeTabIDs.contains(displayedDisplayTabID) == false {
            self.displayedDisplayTabID = nil
        }
        setSegments(for: displayTabs)
    }

    func renderSelection(_ selectedDisplayTab: V2_WIDisplayTab?, animated: Bool) {
        segmentedControl.selectedSegmentIndex = selectedDisplayTab.flatMap {
            segmentDisplayTabIDs.firstIndex(of: $0.id)
        } ?? UISegmentedControl.noSegment
        guard let selectedDisplayTab else {
            displayedDisplayTabID = nil
            setViewControllers([], animated: false)
            return
        }
        guard displayedDisplayTabID != selectedDisplayTab.id || viewControllers.isEmpty else {
            return
        }

        let viewController = rootViewController(for: selectedDisplayTab)
        guard viewControllers.first !== viewController else {
            displayedDisplayTabID = selectedDisplayTab.id
            return
        }
        setViewControllers([viewController], animated: animated)
        displayedDisplayTabID = selectedDisplayTab.id
    }
}

#endif
