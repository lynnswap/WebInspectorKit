#if canImport(UIKit)
import ObservationBridge
import UIKit
import UIHostingMenu

@MainActor
final class V2_DOMSplitViewController: UISplitViewController {
    private let session: V2_WISession
    private var observationHandles: Set<ObservationHandle> = []
    private lazy var domTreeViewController = V2_WIRegularSplitColumnNavigationController(
        rootViewController: V2_DOMTreeViewController(dom: session.runtime.dom)
    )
    private lazy var elementDetailsViewController = V2_WIRegularSplitColumnNavigationController(
        rootViewController: V2_DOMElementViewController(dom: session.runtime.dom)
    )
    private lazy var pickItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "scope"),
            style: .plain,
            target: self,
            action: #selector(toggleSelectionMode)
        )
        item.accessibilityIdentifier = "WI.DOM.PickButton"
        return item
    }()
    private lazy var deferredSecondaryOverflowItems = makeDeferredSecondaryOverflowItems()

    init(session: V2_WISession = V2_WISession()) {
        self.session = session
        super.init(style: .doubleColumn)
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
        configureSplitViewLayout()
        configureNavigationItem()
        bindNavigationState()
    }

    private func configureSplitViewLayout() {
        preferredSplitBehavior = .tile
        presentsWithGesture = false
        displayModeButtonVisibility = .never

        if #available(iOS 26.0, *) {
            preferredDisplayMode = .secondaryOnly
            setViewController(domTreeViewController, for: .secondary)
            setViewController(elementDetailsViewController, for: .inspector)
            minimumInspectorColumnWidth = 320
            maximumInspectorColumnWidth = .greatestFiniteMagnitude
            preferredInspectorColumnWidthFraction = 0.3
            show(.inspector)
        } else {
            preferredDisplayMode = .oneBesideSecondary
            setViewController(domTreeViewController, for: .primary)
            setViewController(elementDetailsViewController, for: .secondary)
            minimumPrimaryColumnWidth = 320
            maximumPrimaryColumnWidth = .greatestFiniteMagnitude
            preferredPrimaryColumnWidthFraction = 0.7
        }
    }

    private func configureNavigationItem() {
        updatePickItemAppearance()
        navigationItem.trailingItemGroups = [
            UIBarButtonItemGroup(
                barButtonItems: [pickItem],
                representativeItem: nil
            )
        ]
        navigationItem.additionalOverflowItems = deferredSecondaryOverflowItems
    }

    private func bindNavigationState() {
        observationHandles.removeAll()
        session.runtime.dom.observeNavigationState { [weak self] in
            self?.updatePickItemAppearance()
        }
        .forEach { $0.store(in: &observationHandles) }
    }

    private func makeDeferredSecondaryOverflowItems() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else {
                completion([])
                return
            }
            completion(makeSecondaryMenu(undoManager: undoManager).children)
        }
    }

    private func makeSecondaryMenu(undoManager: UndoManager?) -> UIMenu {
        let hostingMenu = UIHostingMenu(
            rootView: V2_DOMOverflowMenuView(
                dom: session.runtime.dom,
                undoManager: undoManager
            )
        )
        return (try? hostingMenu.menu()) ?? UIMenu()
    }

    @objc
    private func toggleSelectionMode() {
        session.runtime.dom.requestSelectionModeToggle()
        updatePickItemAppearance()
    }

    private func updatePickItemAppearance() {
        let dom = session.runtime.dom
        pickItem.isEnabled = dom.isPageReadyForSelection
        pickItem.tintColor = dom.isSelectingElement ? .systemBlue : .label
    }
}

#if DEBUG && canImport(SwiftUI)
import SwiftUI

#Preview("V2 DOM Split") {
    V2_DOMSplitViewController()
}
#endif
#endif
