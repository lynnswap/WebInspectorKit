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
            commandCount: deletedNodeCount,
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
    private let commandCount: Int
    private let actionName: String

    init(
        commands: WebInspectorContext.DOMUndoRedoCommands,
        undoManager: UndoManager,
        commandCount: Int,
        actionName: String
    ) {
        self.commands = commands
        self.undoManager = undoManager
        self.commandCount = commandCount
        self.actionName = actionName
    }

    func registerUndo() {
        registerUndoAction { target in
            target.performUndo()
        }
    }

    private func performUndo() {
        undoManager?.domUndoCommandTargetStore.markRedoPending(self)
        Task { @MainActor [self] in
#if DEBUG
            defer {
                undoManager?.domUndoCommandTargetStore.recordOperationCompletionForTesting()
            }
#endif
            do {
                try await undoDeletedNodes()
                registerRedo()
            } catch {
                undoManager?.domUndoCommandTargetStore.release(self)
            }
        }
    }

    private func performRedo() {
        Task { @MainActor [self] in
#if DEBUG
            defer {
                undoManager?.domUndoCommandTargetStore.recordOperationCompletionForTesting()
            }
#endif
            do {
                try await redoDeletedNodes()
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
        undoManager.domUndoCommandTargetStore.registerInternalUndoAction {
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
    }

    private func undoDeletedNodes() async throws {
        for _ in 0..<commandCount {
            try await commands.undo()
        }
    }

    private func redoDeletedNodes() async throws {
        for _ in 0..<commandCount {
            try await commands.redo()
        }
    }

    func redo() {
        performRedo()
    }
}

#if DEBUG
extension DOMDeletionUndoRegistration {
    static func operationCompletionCountForTesting(on undoManager: UndoManager?) -> Int {
        guard let undoManager else {
            return 0
        }
        return undoManager.domUndoCommandTargetStore.operationCompletionCountForTesting
    }

    static func waitForOperationCompletionForTesting(
        after baseline: Int,
        on undoManager: UndoManager?
    ) async -> Bool {
        guard let undoManager else {
            return false
        }
        return await undoManager.domUndoCommandTargetStore.waitForOperationCompletionForTesting(after: baseline)
    }

    static func waitForRedoAvailabilityForTesting(
        _ isAvailable: Bool,
        on undoManager: UndoManager?
    ) async -> Bool {
        guard let undoManager else {
            return false
        }
        return await undoManager.domUndoCommandTargetStore.waitForRedoAvailabilityForTesting(isAvailable)
    }
}
#endif

private final class DOMUndoGroupCloseObserver {
    private let observer: NSObjectProtocol

    init(undoManager: UndoManager, onGroupClosed: @escaping @MainActor @Sendable () -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSUndoManagerDidCloseUndoGroup,
            object: undoManager,
            queue: nil
        ) { _ in
            Task { @MainActor in
                onGroupClosed()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(observer)
    }
}

#if DEBUG
@MainActor
private struct DOMUndoRedoAvailabilityWaiter {
    var isAvailable: Bool
    var continuation: CheckedContinuation<Bool, Never>
}

@MainActor
private struct DOMUndoOperationCompletionWaiter {
    var baseline: Int
    var continuation: CheckedContinuation<Bool, Never>
}
#endif

@MainActor
private final class DOMUndoCommandTargetStore {
    private weak var undoManager: UndoManager?
    private var groupCloseObserver: DOMUndoGroupCloseObserver?
    private var retainedTargets: [DOMUndoCommandTarget] = []
    private var pendingRedoTargets: [DOMUndoCommandTarget] = []
    private var redoTargets: [DOMUndoCommandTarget] = []
    private var internalUndoRegistrationDepth = 0
#if DEBUG
    private var redoAvailabilityWaitersForTesting: [DOMUndoRedoAvailabilityWaiter] = []
    private var operationCompletionWaitersForTesting: [DOMUndoOperationCompletionWaiter] = []
    private(set) var operationCompletionCountForTesting = 0
#endif

    init(undoManager: UndoManager) {
        self.undoManager = undoManager
        groupCloseObserver = DOMUndoGroupCloseObserver(undoManager: undoManager) { [weak self] in
            self?.clearRedoTargetsIfExternalUndoGroupClosed()
        }
    }

    var canRedo: Bool {
        !redoTargets.isEmpty
    }

    func retain(_ target: DOMUndoCommandTarget) {
        retainedTargets.append(target)
    }

    func release(_ target: DOMUndoCommandTarget) {
        retainedTargets.removeAll { $0 === target }
        pendingRedoTargets.removeAll { $0 === target }
        redoTargets.removeAll { $0 === target }
#if DEBUG
        resolveRedoAvailabilityWaitersForTesting()
#endif
    }

    func markRedoPending(_ target: DOMUndoCommandTarget) {
        guard retainedTargets.contains(where: { $0 === target }),
              pendingRedoTargets.contains(where: { $0 === target }) == false else {
            return
        }
        pendingRedoTargets.append(target)
    }

    func registerRedo(_ target: DOMUndoCommandTarget) {
        guard retainedTargets.contains(where: { $0 === target }),
              pendingRedoTargets.contains(where: { $0 === target }) else {
            return
        }
        pendingRedoTargets.removeAll { $0 === target }
        redoTargets.append(target)
#if DEBUG
        resolveRedoAvailabilityWaitersForTesting()
#endif
    }

    func redo() {
        guard let target = redoTargets.popLast() else {
            return
        }
        target.redo()
#if DEBUG
        resolveRedoAvailabilityWaitersForTesting()
#endif
    }

    func registerInternalUndoAction(_ body: () -> Void) {
        internalUndoRegistrationDepth += 1
        defer {
            internalUndoRegistrationDepth -= 1
        }
        body()
    }

    private func clearRedoTargetsIfExternalUndoGroupClosed() {
        // UndoManager.canRedo also posts checkpoints, so mirror native redo
        // invalidation from group-close notifications instead.
        guard internalUndoRegistrationDepth == 0,
              undoManager?.isUndoing != true,
              undoManager?.isRedoing != true else {
            return
        }
        clearRedoTargets()
    }

    func clearRedoTargets() {
        let staleRedoTargets = redoTargets + pendingRedoTargets
        redoTargets.removeAll(keepingCapacity: true)
        pendingRedoTargets.removeAll(keepingCapacity: true)
        retainedTargets.removeAll { target in
            staleRedoTargets.contains { $0 === target }
        }
#if DEBUG
        resolveRedoAvailabilityWaitersForTesting()
#endif
    }

#if DEBUG
    func waitForRedoAvailabilityForTesting(_ isAvailable: Bool) async -> Bool {
        if canRedo == isAvailable {
            return true
        }
        return await withCheckedContinuation { continuation in
            if canRedo == isAvailable {
                continuation.resume(returning: true)
            } else {
                redoAvailabilityWaitersForTesting.append(DOMUndoRedoAvailabilityWaiter(
                    isAvailable: isAvailable,
                    continuation: continuation
                ))
            }
        }
    }

    func waitForOperationCompletionForTesting(after baseline: Int) async -> Bool {
        if operationCompletionCountForTesting > baseline {
            return true
        }
        return await withCheckedContinuation { continuation in
            if operationCompletionCountForTesting > baseline {
                continuation.resume(returning: true)
            } else {
                operationCompletionWaitersForTesting.append(DOMUndoOperationCompletionWaiter(
                    baseline: baseline,
                    continuation: continuation
                ))
            }
        }
    }

    func recordOperationCompletionForTesting() {
        operationCompletionCountForTesting += 1
        resolveOperationCompletionWaitersForTesting()
    }

    private func resolveRedoAvailabilityWaitersForTesting() {
        var unresolved: [DOMUndoRedoAvailabilityWaiter] = []
        for waiter in redoAvailabilityWaitersForTesting {
            if canRedo == waiter.isAvailable {
                waiter.continuation.resume(returning: true)
            } else {
                unresolved.append(waiter)
            }
        }
        redoAvailabilityWaitersForTesting = unresolved
    }

    private func resolveOperationCompletionWaitersForTesting() {
        var unresolved: [DOMUndoOperationCompletionWaiter] = []
        for waiter in operationCompletionWaitersForTesting {
            if operationCompletionCountForTesting > waiter.baseline {
                waiter.continuation.resume(returning: true)
            } else {
                unresolved.append(waiter)
            }
        }
        operationCompletionWaitersForTesting = unresolved
    }
#endif
}

@MainActor
private enum DOMUndoCommandTargetStores {
    static let stores = NSMapTable<UndoManager, DOMUndoCommandTargetStore>.weakToStrongObjects()

    static func store(for undoManager: UndoManager) -> DOMUndoCommandTargetStore {
        if let store = stores.object(forKey: undoManager) {
            return store
        }
        let store = DOMUndoCommandTargetStore(undoManager: undoManager)
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
