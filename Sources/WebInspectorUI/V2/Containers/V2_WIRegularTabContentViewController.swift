#if canImport(UIKit)
import ObservationBridge
import UIKit

@MainActor
final class V2_WIRegularTabContentViewController: UINavigationController {
    private let session: V2_WISession
    private var segmentDisplayItemIDs: [V2_TabDisplayItem.ID] = []
    private var displayedDisplayItemID: V2_TabDisplayItem.ID?
    private let observationScope = ObservationScope()

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

        renderTabsAndSelection(animated: false)
        bindInterface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
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
        guard segmentDisplayItemIDs.indices.contains(sender.selectedSegmentIndex) else {
            return
        }
        session.interface.selectItem(withID: segmentDisplayItemIDs[sender.selectedSegmentIndex])
    }

    private func bindInterface() {
        session.interface.observe(\.tabs) { [weak self] _ in
            self?.renderTabsAndSelection(animated: true)
        }
        .store(in: observationScope)

        session.interface.observe(\.selectedItemID) { [weak self] _ in
            self?.renderSelection(animated: false)
        }
        .store(in: observationScope)
    }

    private func renderTabsAndSelection(animated: Bool) {
        let displayItems = session.interface.displayItems(for: .regular)
        let activeItemIDs = Set(displayItems.map(\.id))
        if let displayedDisplayItemID,
           activeItemIDs.contains(displayedDisplayItemID) == false {
            self.displayedDisplayItemID = nil
        }
        setSegments(for: displayItems)
        renderSelection(animated: false)
    }

    private func setSegments(for displayItems: [V2_TabDisplayItem]) {
        segmentDisplayItemIDs = displayItems.map(\.id)
        segmentedControl.removeAllSegments()
        for (index, displayItem) in displayItems.enumerated() {
            segmentedControl.insertSegment(
                withTitle: session.interface.descriptor(for: displayItem)?.title,
                at: index,
                animated: false
            )
        }
    }

    private func renderSelection(animated: Bool) {
        let selectedDisplayItem = session.interface.resolvedSelection(for: .regular)
        segmentedControl.selectedSegmentIndex = selectedDisplayItem.flatMap {
            segmentDisplayItemIDs.firstIndex(of: $0.id)
        } ?? UISegmentedControl.noSegment
        guard let selectedDisplayItem else {
            displayedDisplayItemID = nil
            setViewControllers([], animated: false)
            return
        }
        guard displayedDisplayItemID != selectedDisplayItem.id || viewControllers.isEmpty else {
            return
        }

        let viewController = rootViewController(for: selectedDisplayItem)
        guard viewControllers.first !== viewController else {
            displayedDisplayItemID = selectedDisplayItem.id
            return
        }
        setViewControllers([viewController], animated: animated)
        displayedDisplayItemID = selectedDisplayItem.id
    }

    private func rootViewController(for displayItem: V2_TabDisplayItem) -> UIViewController {
        let viewController = V2_TabContentFactory.makeViewController(
            for: displayItem,
            session: session,
            hostLayout: .regular,
            tabs: session.interface.tabs
        )
        viewController.navigationItem.style = .browser
        viewController.navigationItem.centerItemGroups = [segmentItemGroup]
        return viewController
    }
}

#endif
