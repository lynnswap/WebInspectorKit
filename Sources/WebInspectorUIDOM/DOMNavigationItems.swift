#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import UIKit

@MainActor
package final class DOMNavigationItems: NSObject {
    private typealias UndoManagerProvider = @MainActor () -> UndoManager?

    private let context: WebInspectorContext
    private let onElementPickerActivated: @MainActor () -> Void
    private var statusTask: Task<Void, Never>?
    private var undoManagerProvider: UndoManagerProvider = { nil }

    package struct KeyCommandActions {
        package var undo: Selector
        package var redo: Selector
        package var reload: Selector
        package var delete: Selector
        package var pickElement: Selector

        package init(
            undo: Selector,
            redo: Selector,
            reload: Selector,
            delete: Selector,
            pickElement: Selector
        ) {
            self.undo = undo
            self.redo = redo
            self.reload = reload
            self.delete = delete
            self.pickElement = pickElement
        }
    }

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

    package init(
        context: WebInspectorContext,
        onElementPickerActivated: @escaping @MainActor () -> Void = {}
    ) {
        self.context = context
        self.onElementPickerActivated = onElementPickerActivated
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

    package func makeKeyCommands(actions: KeyCommandActions) -> [UIKeyCommand] {
        [
            UIKeyCommand(
                title: String(localized: "undo", bundle: WebInspectorUILocalization.bundle),
                action: actions.undo,
                input: "z",
                modifierFlags: .command,
                discoverabilityTitle: String(localized: "undo", bundle: WebInspectorUILocalization.bundle)
            ),
            UIKeyCommand(
                title: String(localized: "redo", bundle: WebInspectorUILocalization.bundle),
                action: actions.redo,
                input: "z",
                modifierFlags: [.command, .shift],
                discoverabilityTitle: String(localized: "redo", bundle: WebInspectorUILocalization.bundle)
            ),
            UIKeyCommand(
                title: String(localized: "reload", bundle: WebInspectorUILocalization.bundle),
                action: actions.reload,
                input: "r",
                modifierFlags: .command,
                discoverabilityTitle: String(localized: "reload", bundle: WebInspectorUILocalization.bundle)
            ),
            UIKeyCommand(
                title: String(localized: "inspector.delete_node", bundle: WebInspectorUILocalization.bundle),
                action: actions.delete,
                input: UIKeyCommand.inputDelete,
                modifierFlags: [],
                discoverabilityTitle: String(localized: "inspector.delete_node", bundle: WebInspectorUILocalization.bundle)
            ),
            UIKeyCommand(
                title: String(localized: "inspector.pick_element", defaultValue: "Pick Element", bundle: WebInspectorUILocalization.bundle),
                action: actions.pickElement,
                input: "c",
                modifierFlags: [.command, .shift],
                discoverabilityTitle: String(localized: "inspector.pick_element", defaultValue: "Pick Element", bundle: WebInspectorUILocalization.bundle)
            ),
        ]
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
        ) { [weak self] _ in
            self?.performUndo(undoManager: undoManagerProvider())
        }
    }

    private func makeRedoAction(undoManagerProvider: @escaping UndoManagerProvider) -> UIAction {
        let undoManager = undoManagerProvider()
        return UIAction(
            title: String(localized: "redo", bundle: WebInspectorUILocalization.bundle),
            image: UIImage(systemName: "arrow.uturn.forward"),
            attributes: canRedo(undoManager: undoManager) ? [] : [.disabled]
        ) { [weak self] _ in
            self?.performRedo(undoManager: undoManagerProvider())
        }
    }

    package func performUndoCommand() {
        performUndo(undoManager: undoManagerProvider())
    }

    private func performUndo(undoManager: UndoManager?) {
        guard let undoManager, undoManager.canUndo else {
            return
        }
        undoManager.undo()
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
        ) { [weak self] _ in
            self?.performReloadCommand()
        }
    }

    package func performReloadCommand() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            guard context.status.state == .attached else {
                return
            }
            do {
                try await context.page.reload()
            } catch {
                WebInspectorUIDOMLog.debug("DOM reload failed: \(String(describing: error))")
            }
        }
    }

    private func makeDeleteAction(undoManagerProvider: @escaping UndoManagerProvider) -> UIAction {
        UIAction(
            title: String(localized: "inspector.delete_node", bundle: WebInspectorUILocalization.bundle),
            image: UIImage(systemName: "trash"),
            attributes: context.status.selectedNodeID == nil ? [.disabled, .destructive] : [.destructive]
        ) { [weak self] _ in
            self?.performDeleteCommand()
        }
    }

    package func performDeleteCommand() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await deleteSelectedNodeFromNavigation(undoManager: undoManagerProvider())
        }
    }

    private func deleteSelectedNodeFromNavigation(undoManager: UndoManager?) async {
        guard let selectedNode = context.selectedNode else {
            return
        }
        do {
            let result = try await context.dom.remove([selectedNode.id])
            let undoCommands = try context.domUndoRedoCommands()
            DOMDeletionUndoRegistration.registerDeleteUndo(
                on: undoManager,
                commands: undoCommands,
                deletedNodeCount: result.acceptedNodeIDs.count
            )
        } catch {
            return
        }
    }

    package func performRedoCommand() {
        performRedo(undoManager: undoManagerProvider())
    }

    package func performToggleElementPickerCommand() {
        Task { @MainActor [weak self] in
            await self?.toggleElementPickerState()
        }
    }

    @objc
    private func toggleElementPicker() {
        performToggleElementPickerCommand()
    }

    private func toggleElementPickerState() async {
        do {
            try await context.dom.toggleInspectMode()
            if context.isElementPickerEnabled {
                onElementPickerActivated()
            }
        } catch {
            WebInspectorUIDOMLog.debug("DOM picker toggle failed: \(String(describing: error))")
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

    func toggleElementPickerForTesting() async {
        await toggleElementPickerState()
    }
}
#endif

#endif
