#if canImport(UIKit)
import WebInspectorUIBase
import WebInspectorDataKit
import UIKit

@MainActor
enum DOMDeletionUndoRegistration {
    static func registerDeleteUndo(
        on undoManager: UndoManager?,
        commands: WebInspectorContext.DOMUndoRedoCommands,
        deletedNodeCount: Int
    ) {
        guard let undoManager, deletedNodeCount > 0 else {
            return
        }
        let target = DOMUndoCommandTarget(
            commands: commands,
            undoManager: undoManager,
            actionName: deletedNodeCount == 1
                ? String(localized: "inspector.delete_node", bundle: WebInspectorUILocalization.bundle)
                : String(localized: "inspector.delete_nodes", bundle: WebInspectorUILocalization.bundle)
        )
        undoManager.domUndoCommandTargetStore.clearRedoTargets()
        undoManager.domUndoCommandTargetStore.retain(target)
        target.registerUndo()
    }

    static func canRedo(on undoManager: UndoManager?) -> Bool {
        undoManager?.domUndoCommandTargetStore.canRedo == true
    }

    static func redo(on undoManager: UndoManager?) {
        undoManager?.domUndoCommandTargetStore.redo()
    }
}

@MainActor
private final class DOMUndoCommandTarget: NSObject {
    private let commands: WebInspectorContext.DOMUndoRedoCommands
    private weak var undoManager: UndoManager?
    private let actionName: String

    init(commands: WebInspectorContext.DOMUndoRedoCommands, undoManager: UndoManager, actionName: String) {
        self.commands = commands
        self.undoManager = undoManager
        self.actionName = actionName
    }

    func registerUndo() {
        registerUndoAction { target in
            target.performUndo()
        }
    }

    private func performUndo() {
        Task { @MainActor [self] in
            do {
                try await commands.undo()
                registerRedo()
            } catch {
                undoManager?.domUndoCommandTargetStore.release(self)
            }
        }
    }

    private func performRedo() {
        Task { @MainActor [self] in
            do {
                try await commands.redo()
                registerUndo()
            } catch {
                undoManager?.domUndoCommandTargetStore.release(self)
            }
        }
    }

    private func registerRedo() {
        undoManager?.domUndoCommandTargetStore.registerRedo(self)
    }

    private func registerUndoAction(_ handler: @escaping @MainActor (DOMUndoCommandTarget) -> Void) {
        guard let undoManager else {
            return
        }
        let createsGroup = undoManager.groupingLevel == 0
        if createsGroup {
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: self) { target in
            handler(target)
        }
        undoManager.setActionName(actionName)
        if createsGroup {
            undoManager.endUndoGrouping()
        }
    }

    func redo() {
        performRedo()
    }
}

@MainActor
private final class DOMUndoCommandTargetStore {
    private var retainedTargets: [DOMUndoCommandTarget] = []
    private var redoTargets: [DOMUndoCommandTarget] = []

    var canRedo: Bool {
        !redoTargets.isEmpty
    }

    func retain(_ target: DOMUndoCommandTarget) {
        retainedTargets.append(target)
    }

    func release(_ target: DOMUndoCommandTarget) {
        retainedTargets.removeAll { $0 === target }
        redoTargets.removeAll { $0 === target }
    }

    func registerRedo(_ target: DOMUndoCommandTarget) {
        guard retainedTargets.contains(where: { $0 === target }) else {
            return
        }
        redoTargets.append(target)
    }

    func redo() {
        guard let target = redoTargets.popLast() else {
            return
        }
        target.redo()
    }

    func clearRedoTargets() {
        let staleRedoTargets = redoTargets
        redoTargets.removeAll(keepingCapacity: true)
        retainedTargets.removeAll { target in
            staleRedoTargets.contains { $0 === target }
        }
    }
}

@MainActor
private enum DOMUndoCommandTargetStores {
    static let stores = NSMapTable<UndoManager, DOMUndoCommandTargetStore>.weakToStrongObjects()

    static func store(for undoManager: UndoManager) -> DOMUndoCommandTargetStore {
        if let store = stores.object(forKey: undoManager) {
            return store
        }
        let store = DOMUndoCommandTargetStore()
        stores.setObject(store, forKey: undoManager)
        return store
    }
}

@MainActor
private extension UndoManager {
    var domUndoCommandTargetStore: DOMUndoCommandTargetStore {
        DOMUndoCommandTargetStores.store(for: self)
    }
}
#endif
