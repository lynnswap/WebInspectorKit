#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import UIKit

@MainActor
package final class DOMNavigationItems: NSObject {
    private typealias UndoManagerProvider = @MainActor () -> UndoManager?

    private let context: WebInspectorContext
    private var statusTask: Task<Void, Never>?
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

    package init(context: WebInspectorContext) {
        self.context = context
        super.init()
        startObservingInspection()
    }

    isolated deinit {
        statusTask?.cancel()
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
        statusTask = Task { @MainActor [weak self, context] in
            for await status in context.statusUpdates {
                self?.renderPickItem(status: status)
            }
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
            title: String(localized: "undo", bundle: WebInspectorUILocalization.bundle),
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
            title: String(localized: "redo", bundle: WebInspectorUILocalization.bundle),
            image: UIImage(systemName: "arrow.uturn.forward"),
            attributes: canRedo(undoManager: undoManager) ? [] : [.disabled]
        ) { _ in
            Task { @MainActor [weak self] in
                self?.performRedo(undoManager: undoManagerProvider())
            }
        }
    }

    private func canRedo(undoManager: UndoManager?) -> Bool {
        undoManager?.canRedo == true || DOMDeletionUndoRegistration.canRedo(on: undoManager)
    }

    private func performRedo(undoManager: UndoManager?) {
        guard let undoManager else {
            return
        }
        if undoManager.canRedo {
            undoManager.redo()
        } else {
            DOMDeletionUndoRegistration.redo(on: undoManager)
        }
    }

    private func makeReloadAction() -> UIAction {
        UIAction(
            title: String(localized: "reload", bundle: WebInspectorUILocalization.bundle),
            image: UIImage(systemName: "arrow.clockwise"),
            attributes: context.status.state == .attached ? [] : [.disabled]
        ) { [weak context] _ in
            Task { @MainActor in
                try? await context?.reloadPage()
            }
        }
    }

    private func makeDeleteAction(undoManagerProvider: @escaping UndoManagerProvider) -> UIAction {
        UIAction(
            title: String(localized: "inspector.delete_node", bundle: WebInspectorUILocalization.bundle),
            image: UIImage(systemName: "trash"),
            attributes: context.status.selectedNodeID == nil ? [.disabled, .destructive] : [.destructive]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.deleteSelectedNodeFromNavigation(
                    undoManager: undoManagerProvider()
                )
            }
        }
    }

    private func deleteSelectedNodeFromNavigation(undoManager: UndoManager?) async {
        guard let selectedNode = context.selectedNode else {
            return
        }
        do {
            let undoCommands = try context.domUndoRedoCommands()
            try await context.delete(selectedNode)
            DOMDeletionUndoRegistration.registerDeleteUndo(
                on: undoManager,
                commands: undoCommands,
                deletedNodeCount: 1
            )
        } catch {
            return
        }
    }

    @objc
    private func toggleElementPicker() {
        Task { @MainActor [weak context] in
            guard let context else {
                return
            }
            try? await context.setElementPickerEnabled(!context.isElementPickerEnabled)
        }
    }

    private func updatePickItemAppearance() {
        renderPickItem(
            status: context.status
        )
    }

    private func renderPickItem(status: WebInspectorContext.Status) {
        renderPickItem(
            isEnabled: status.state == .attached,
            isSelectingElement: status.isElementPickerEnabled
        )
    }

    private func renderPickItem(isEnabled: Bool, isSelectingElement: Bool) {
        if pickItem.isEnabled != isEnabled {
            pickItem.isEnabled = isEnabled
        }
        let tintColor: UIColor = isSelectingElement ? .tintColor : .label
        if pickItem.tintColor != tintColor {
            pickItem.tintColor = tintColor
        }
    }
}

#if DEBUG
extension DOMNavigationItems {
    var statusObservationTaskForTesting: Task<Void, Never>? {
        statusTask
    }

    var pickItemForTesting: UIBarButtonItem {
        pickItem
    }

    func deleteSelectedNodeForTesting(undoManager: UndoManager?) async {
        await deleteSelectedNodeFromNavigation(undoManager: undoManager)
    }

    func canRedoForTesting(undoManager: UndoManager?) -> Bool {
        canRedo(undoManager: undoManager)
    }

    func redoForTesting(undoManager: UndoManager?) {
        performRedo(undoManager: undoManager)
    }
}
#endif

#endif
