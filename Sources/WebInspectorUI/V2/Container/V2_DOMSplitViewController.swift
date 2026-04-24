#if canImport(UIKit)
import UIKit

@MainActor
final class V2_DOMSplitViewController: UISplitViewController {
    private let compactViewController = V2_DOMSplitViewController.makeCompactViewController()
    private let domTreeViewController = V2_DOMSplitViewController.makeContentViewController()
    private let elementDetailsViewController = V2_DOMSplitViewController.makeContentViewController()

    init() {
        super.init(style: .doubleColumn)
        configureSplitViewLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    private func configureSplitViewLayout() {
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never
        
        setViewController(compactViewController, for: .compact)
        setViewController(nil, for: .primary)
        setViewController(nil, for: .secondary)
        if #available(iOS 26.0, *) {
            setViewController(nil, for: .inspector)
        }

        if #available(iOS 26.0, *) {
            preferredDisplayMode = .secondaryOnly
            setViewController(domTreeViewController, for: .secondary)
            setViewController(elementDetailsViewController, for: .inspector)
            minimumInspectorColumnWidth = 320
            maximumInspectorColumnWidth = .greatestFiniteMagnitude
            preferredInspectorColumnWidthFraction = 0.3
        } else {
            preferredDisplayMode = .oneBesideSecondary
            setViewController(domTreeViewController, for: .primary)
            setViewController(elementDetailsViewController, for: .secondary)
            minimumPrimaryColumnWidth = 320
            maximumPrimaryColumnWidth = .greatestFiniteMagnitude
            preferredPrimaryColumnWidthFraction = 0.7
        }
    }

    private static func makeContentViewController() -> UIViewController {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .clear
        return viewController
    }

    private static func makeCompactViewController() -> UINavigationController {
        let navigationController = UINavigationController(rootViewController: V2_DOMCompactViewController())
        wiApplyClearNavigationBarStyle(to: navigationController)
        return navigationController
    }
}

@MainActor
private final class V2_DOMCompactViewController: UIViewController {
    private let treeViewController = V2_DOMCompactViewController.makeContentViewController()
    private let elementViewController = V2_DOMCompactViewController.makeContentViewController()
    private weak var segmentNavigationItem: UINavigationItem?
    private lazy var segmentBarButtonItem = UIBarButtonItem(customView: segmentControl)
    private lazy var segmentItemGroup = segmentBarButtonItem.creatingFixedGroup()
    private lazy var segmentControl: UISegmentedControl = {
        let control = UISegmentedControl(items: V2_DOMCompactContent.allCases.map(\.title))
        control.selectedSegmentIndex = V2_DOMCompactContent.tree.rawValue
        control.addTarget(self, action: #selector(handleSegmentSelectionChanged), for: .valueChanged)
        return control
    }()

    private static func makeContentViewController() -> UIViewController {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .clear
        return viewController
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        if #available(iOS 26.0, *) {
            segmentBarButtonItem.hidesSharedBackground = true
        }
        installContentViewController(treeViewController)
        installContentViewController(elementViewController)
        selectContent(.tree)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        installSegmentControl()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        removeSegmentControl()
    }

    @objc
    private func handleSegmentSelectionChanged(_ sender: UISegmentedControl) {
        guard let content = V2_DOMCompactContent(rawValue: sender.selectedSegmentIndex) else {
            return
        }
        selectContent(content)
    }

    private func installContentViewController(_ viewController: UIViewController) {
        addChild(viewController)
        viewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(viewController.view)
        NSLayoutConstraint.activate([
            viewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            viewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            viewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            viewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        viewController.didMove(toParent: self)
    }

    private func selectContent(_ content: V2_DOMCompactContent) {
        segmentControl.selectedSegmentIndex = content.rawValue
        treeViewController.view.isHidden = content != .tree
        elementViewController.view.isHidden = content != .element
    }

    private func installSegmentControl() {
        let navigationItem = resolvedSegmentNavigationItem
        if segmentNavigationItem !== navigationItem {
            removeSegmentControl()
            segmentNavigationItem = navigationItem
        }

        var leadingItemGroups = navigationItem.leadingItemGroups
        guard leadingItemGroups.contains(where: { $0 === segmentItemGroup }) == false else {
            return
        }

        leadingItemGroups.insert(segmentItemGroup, at: 0)
        navigationItem.leadingItemGroups = leadingItemGroups
    }

    private func removeSegmentControl() {
        guard let segmentNavigationItem else {
            return
        }

        segmentNavigationItem.leadingItemGroups = segmentNavigationItem.leadingItemGroups
            .filter { $0 !== segmentItemGroup }
        self.segmentNavigationItem = nil
    }

    private var resolvedSegmentNavigationItem: UINavigationItem {
        if let parent,
           parent.navigationController != nil {
            return parent.navigationItem
        }

        return navigationItem
    }
}

private enum V2_DOMCompactContent: Int, CaseIterable {
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

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("V2 DOM Split") {
    V2_DOMSplitViewController()
}
#endif
#endif
