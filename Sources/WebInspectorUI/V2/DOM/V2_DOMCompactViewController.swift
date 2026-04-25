#if canImport(UIKit)
import ObservationBridge
import UIKit

@MainActor
enum V2_DOMCompactContent: Equatable, CaseIterable {
    case tree
    case element

    var title: String {
        switch self {
        case .tree:
            "Tree"
        case .element:
            "Element"
        }
    }
}

@MainActor
final class V2_DOMCompactViewController: UIViewController {
    private let session: V2_WISession
    private let interface: V2_WIInterfaceModel
    private lazy var navigationItems = V2_DOMNavigationItems(dom: session.runtime.dom)
    private lazy var treeViewController = V2_DOMTreeViewController(dom: session.runtime.dom)
    private lazy var elementViewController = V2_DOMElementViewController(dom: session.runtime.dom)
    private var observationHandles: Set<ObservationHandle> = []

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
        let control = UISegmentedControl(items: V2_DOMCompactContent.allCases.map(\.title))
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
        navigationItem.style = .browser
        navigationItem.leadingItemGroups = [segmentItemGroup]
        navigationItems.install(on: navigationItem) { [weak self] in
            self?.undoManager
        }
        bindModel()
        render()
    }

    @objc
    private func handleSegmentSelectionChanged(_ sender: UISegmentedControl) {
        guard sender.selectedSegmentIndex != UISegmentedControl.noSegment else {
            return
        }
        interface.dom.selectCompactContent(at: sender.selectedSegmentIndex)
    }

    private func bindModel() {
        observationHandles.removeAll()
        interface.dom.observe(\.selectedCompactContent) { [weak self] _ in
            self?.render()
        }
        .store(in: &observationHandles)
    }

    private func render() {
        guard isViewLoaded else {
            return
        }

        syncSegmentSelection()
        displaySelectedContent()
    }

    private func syncSegmentSelection() {
        let selectedIndex = interface.dom.selectedCompactContentIndex ?? UISegmentedControl.noSegment
        guard segmentedControl.selectedSegmentIndex != selectedIndex else {
            return
        }

        segmentedControl.selectedSegmentIndex = selectedIndex
    }

    private func displaySelectedContent() {
        let viewController = viewController(for: interface.dom.selectedCompactContent)
        guard children.first !== viewController else {
            return
        }

        removeDisplayedViewController()
        addChild(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewController.view)
        NSLayoutConstraint.activate([
            viewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            viewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        viewController.didMove(toParent: self)
    }

    private func removeDisplayedViewController() {
        guard let viewController = children.first else {
            return
        }

        viewController.willMove(toParent: nil)
        viewController.view.removeFromSuperview()
        viewController.removeFromParent()
    }

    private func viewController(for content: V2_DOMCompactContent) -> UIViewController {
        switch content {
        case .tree:
            treeViewController
        case .element:
            elementViewController
        }
    }
}
#endif
