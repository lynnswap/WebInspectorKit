#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import ObservationBridge
import UIKit

@MainActor
package final class DOMNavigationItems: NSObject {
    private typealias UndoManagerProvider = @MainActor () -> UndoManager?

    private let context: WebInspectorModelContext
    private let panelModel: DOMPanelModel
    private var containerStateTask: Task<Void, Never>?
    private var panelObservation: PortableObservationTracking.Token?
    private var undoManagerProvider: UndoManagerProvider = { nil }
    private var containerState: WebInspectorModelContainer.State

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

    package init(model: DOMPanelModel) {
        context = model.context
        panelModel = model
        containerState = model.context.container.state
        super.init()
        startObservingInspection()
    }

    isolated deinit {
        containerStateTask?.cancel()
        panelObservation?.cancel()
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
        panelObservation = withPortableContinuousObservation { [weak self, weak panelModel] _ in
            guard let self,
                  let panelModel else {
                return
            }
            renderPickItem(
                isEnabled: containerState == .attached,
                isSelectingElement: panelModel.isPickingElement
            )
        }
        let updates = context.container.stateUpdates
        containerStateTask = Task { @MainActor [weak self] in
            for await state in updates {
                guard let self else {
                    return
                }
                containerState = state
                updatePickItemAppearance()
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
            attributes: context.container.state == .attached ? [] : [.disabled]
        ) { [weak self] _ in
            self?.performReloadCommand()
        }
    }

    package func performReloadCommand() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await context.reload()
            } catch {
                WebInspectorUIDOMLog.debug("DOM reload failed: \(String(describing: error))")
            }
        }
    }

    private func makeDeleteAction(undoManagerProvider: @escaping UndoManagerProvider) -> UIAction {
        UIAction(
            title: String(localized: "inspector.delete_node", bundle: WebInspectorUILocalization.bundle),
            image: UIImage(systemName: "trash"),
            attributes: currentSelectedNode == nil ? [.disabled, .destructive] : [.destructive]
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
        guard let selectedNode = currentSelectedNode else {
            return
        }
        do {
            let result = try await context.removeDOMNodes([selectedNode])
            guard let undo = result.undo else {
                return
            }
            DOMDeletionUndoRegistration.registerDeleteUndo(
                on: undoManager,
                capability: undo,
                deletedNodeCount: result.appliedNodeIDs.count
            )
        } catch {
            return
        }
    }

    package func performRedoCommand() {
        performRedo(undoManager: undoManagerProvider())
    }

    package func performToggleElementPickerCommand() {
        toggleElementPicker()
    }

    @objc
    private func toggleElementPicker() {
        panelModel.toggleElementPicker()
    }

    private func updatePickItemAppearance() {
        renderPickItem(
            isEnabled: containerState == .attached,
            isSelectingElement: panelModel.isPickingElement
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

    private var currentSelectedNode: DOMNode? {
        panelModel.selectedNode
    }
}

#if DEBUG
extension DOMNavigationItems {
    var statusObservationTaskForTesting: Task<Void, Never>? {
        containerStateTask
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
