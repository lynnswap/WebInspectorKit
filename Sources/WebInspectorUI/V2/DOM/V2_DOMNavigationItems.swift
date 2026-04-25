#if canImport(UIKit)
import ObservationBridge
import UIKit
import UIHostingMenu
import WebInspectorRuntime

@MainActor
final class V2_DOMNavigationItems: NSObject {
    private let dom: V2_WIDOMRuntime
    private var observationHandles: Set<ObservationHandle> = []
    private var undoManagerProvider: (@MainActor () -> UndoManager?)?

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

    init(dom: V2_WIDOMRuntime) {
        self.dom = dom
        super.init()

        dom.observeNavigationState { [weak self] in
            self?.updatePickItemAppearance()
        }
        .forEach { $0.store(in: &observationHandles) }
    }

    deinit {
        observationHandles.removeAll()
    }

    func install(
        on navigationItem: UINavigationItem,
        undoManager: @escaping @MainActor () -> UndoManager?
    ) {
        undoManagerProvider = undoManager
        updatePickItemAppearance()
        navigationItem.trailingItemGroups = [
            UIBarButtonItemGroup(
                barButtonItems: [pickItem],
                representativeItem: nil
            )
        ]
        navigationItem.additionalOverflowItems = makeDeferredOverflowItems()
    }

    private func makeDeferredOverflowItems() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else {
                completion([])
                return
            }
            completion(makeOverflowMenu(undoManager: undoManagerProvider?()).children)
        }
    }

    private func makeOverflowMenu(undoManager: UndoManager?) -> UIMenu {
        let hostingMenu = UIHostingMenu(
            rootView: V2_DOMOverflowMenuView(
                dom: dom,
                undoManager: undoManager
            )
        )
        return (try? hostingMenu.menu()) ?? UIMenu()
    }

    @objc
    private func toggleSelectionMode() {
        dom.requestSelectionModeToggle()
        updatePickItemAppearance()
    }

    private func updatePickItemAppearance() {
        pickItem.isEnabled = dom.isPageReadyForSelection
        pickItem.tintColor = dom.isSelectingElement ? .tintColor : .label
    }
}
#endif
