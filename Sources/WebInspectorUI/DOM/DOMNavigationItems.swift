#if canImport(UIKit)
import ObservationBridge
import WebInspectorCore
import UIKit

@MainActor
package final class DOMNavigationItems: NSObject {
    private typealias UndoManagerProvider = @MainActor () -> UndoManager?

    private let inspector: InspectorSession
    private let observationScope = ObservationScope()
    private var undoManagerProvider: UndoManagerProvider = { nil }

    private lazy var pickItem: UIBarButtonItem = {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "scope"),
            style: .plain,
            target: self,
            action: #selector(toggleElementPicker)
        )
        item.accessibilityIdentifier = "WebInspector.DOM.PickButton"
        return item
    }()

    package init(inspector: InspectorSession) {
        self.inspector = inspector
        super.init()
        startObservingInspection()
    }

    isolated deinit {
        observationScope.cancelAll()
    }

    package func install(
        on navigationItem: UINavigationItem,
        undoManager: @escaping @MainActor () -> UndoManager?
    ) {
        undoManagerProvider = undoManager
        updatePickItemAppearance()
        navigationItem.trailingItemGroups = [
            UIBarButtonItemGroup(
                barButtonItems: [pickItem],
                representativeItem: nil
            ),
        ]
        navigationItem.additionalOverflowItems = makeDeferredOverflowItems()
    }

    private func startObservingInspection() {
        observationScope.observe(inspector.attachment.dom) { [weak self] _, _ in
            self?.renderPickItem()
        }
    }

    private func makeDeferredOverflowItems() -> UIDeferredMenuElement {
        UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else {
                completion([])
                return
            }
            completion(makeOverflowMenu(undoManagerProvider: undoManagerProvider).children)
        }
    }

    private func makeOverflowMenu(undoManagerProvider: @escaping UndoManagerProvider) -> UIMenu {
        UIMenu(children: [
            UIMenu(options: .displayInline, children: [
                makeUndoAction(undoManagerProvider: undoManagerProvider),
                makeRedoAction(undoManagerProvider: undoManagerProvider),
            ]),
            UIMenu(options: .displayInline, children: [
                makeReloadAction(),
            ]),
            UIMenu(options: .displayInline, children: [
                makeDeleteAction(undoManagerProvider: undoManagerProvider),
            ]),
        ])
    }

    private func makeUndoAction(undoManagerProvider: @escaping UndoManagerProvider) -> UIAction {
        let undoManager = undoManagerProvider()
        return UIAction(
            title: String(localized: "undo", bundle: .module),
            image: UIImage(systemName: "arrow.uturn.backward"),
            attributes: undoManager?.canUndo == true ? [] : [.disabled]
        ) { _ in
            Task { @MainActor in
                guard let undoManager = undoManagerProvider(), undoManager.canUndo else {
                    return
                }
                undoManager.undo()
            }
        }
    }

    private func makeRedoAction(undoManagerProvider: @escaping UndoManagerProvider) -> UIAction {
        let undoManager = undoManagerProvider()
        return UIAction(
            title: String(localized: "redo", bundle: .module),
            image: UIImage(systemName: "arrow.uturn.forward"),
            attributes: undoManager?.canRedo == true ? [] : [.disabled]
        ) { _ in
            Task { @MainActor in
                guard let undoManager = undoManagerProvider(), undoManager.canRedo else {
                    return
                }
                undoManager.redo()
            }
        }
    }

    private func makeReloadAction() -> UIAction {
        UIAction(
            title: String(localized: "reload", bundle: .module),
            image: UIImage(systemName: "arrow.clockwise"),
            attributes: (inspector.hasInspectablePageWebView || inspector.attachment.dom.canReloadDocument) ? [] : [.disabled]
        ) { [weak inspector] _ in
            Task { @MainActor in
                guard let inspector else {
                    return
                }
                if inspector.hasInspectablePageWebView {
                    try? await inspector.reloadPage()
                } else {
                    try? await inspector.attachment.dom.reloadDocument()
                }
            }
        }
    }

    private func makeDeleteAction(undoManagerProvider: @escaping UndoManagerProvider) -> UIAction {
        UIAction(
            title: String(localized: "inspector.delete_node", bundle: .module),
            image: UIImage(systemName: "trash"),
            attributes: inspector.attachment.dom.canDeleteSelectedNode ? [.destructive] : [.disabled, .destructive]
        ) { [weak inspector] _ in
            Task { @MainActor in
                try? await inspector?.attachment.dom.deleteSelectedNode(undoManager: undoManagerProvider())
            }
        }
    }

    @objc
    private func toggleElementPicker() {
        Task { @MainActor [weak inspector] in
            await inspector?.attachment.dom.toggleElementPicker()
        }
    }

    private func updatePickItemAppearance() {
        renderPickItem()
    }

    private func renderPickItem() {
        let dom = inspector.attachment.dom
        let isEnabled = dom.canBeginElementPicker
        if pickItem.isEnabled != isEnabled {
            pickItem.isEnabled = isEnabled
        }
        let tintColor: UIColor = dom.isSelectingElement ? .tintColor : .label
        if pickItem.tintColor != tintColor {
            pickItem.tintColor = tintColor
        }
    }
}

#if DEBUG
extension DOMNavigationItems {
    package var pickItemForTesting: UIBarButtonItem {
        pickItem
    }

    package func overflowMenuForTesting(undoManager: UndoManager? = nil) -> UIMenu {
        makeOverflowMenu(undoManagerProvider: { undoManager })
    }
}
#endif
#endif
