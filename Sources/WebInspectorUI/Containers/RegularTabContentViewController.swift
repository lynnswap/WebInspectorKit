#if canImport(UIKit)
import ObservationBridge
import UIKit

@MainActor
package final class RegularTabContentViewController: UINavigationController {
    private let session: WebInspectorSession
    private var segmentDisplayItemIDs: [TabDisplayItem.ID] = []
    private var displayedDisplayItemID: TabDisplayItem.ID?
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

    package init(session: WebInspectorSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)

        navigationBar.prefersLargeTitles = false
        webInspectorApplyNavigationControllerBackground(to: self)

        renderTabsAndSelection()
        bindInterface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        applyBackgroundFromTraits()
        registerForTraitChanges([WebInspectorDrawsBackgroundTrait.self]) { (self: Self, _) in
            self.applyBackgroundFromTraits()
        }
    }

    private func applyBackgroundFromTraits() {
        view.backgroundColor = webInspectorBackgroundPolicy.backgroundColor
        webInspectorApplyNavigationControllerBackground(to: self)
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
        observationScope.observe(session.interface) { [weak self] _, interface in
            self?.renderInterface(interface)
        }
    }

    private func renderTabsAndSelection() {
        renderInterface(session.interface)
    }

    private func renderInterface(_ interface: InterfaceModel) {
        let displayItems = interface.displayItems(for: .regular)
        let selectedDisplayItem = interface.resolvedSelection(for: .regular)
        let activeItemIDs = Set(displayItems.map(\.id))
        if let displayedDisplayItemID,
           activeItemIDs.contains(displayedDisplayItemID) == false {
            self.displayedDisplayItemID = nil
        }
        setSegments(for: displayItems)
        renderSelection(selectedDisplayItem)
    }

    private func setSegments(for displayItems: [TabDisplayItem]) {
        let nextItemIDs = displayItems.map(\.id)
        guard segmentDisplayItemIDs != nextItemIDs else {
            return
        }

        segmentDisplayItemIDs = nextItemIDs
        segmentedControl.removeAllSegments()
        for (index, displayItem) in displayItems.enumerated() {
            segmentedControl.insertSegment(
                withTitle: session.interface.descriptor(for: displayItem)?.title,
                at: index,
                animated: false
            )
        }
    }

    private func renderSelection(_ selectedDisplayItem: TabDisplayItem?) {
        let selectedSegmentIndex = selectedDisplayItem.flatMap {
            segmentDisplayItemIDs.firstIndex(of: $0.id)
        } ?? UISegmentedControl.noSegment
        if segmentedControl.selectedSegmentIndex != selectedSegmentIndex {
            segmentedControl.selectedSegmentIndex = selectedSegmentIndex
        }
        guard let selectedDisplayItem else {
            guard displayedDisplayItemID != nil || viewControllers.isEmpty == false else {
                return
            }
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
        setViewControllers([viewController], animated: false)
        displayedDisplayItemID = selectedDisplayItem.id
    }

    private func rootViewController(for displayItem: TabDisplayItem) -> UIViewController {
        let viewController = TabContentFactory.makeViewController(
            for: displayItem,
            session: session,
            hostLayout: .regular,
            tabs: session.interface.tabs
        )
        viewController.navigationItem.style = .browser
        viewController.navigationItem.centerItemGroups = [segmentItemGroup]
        return viewController
    }

    package var segmentedControlForTesting: UISegmentedControl {
        segmentedControl
    }
}
#endif
