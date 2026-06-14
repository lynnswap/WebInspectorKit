import Foundation
import WebInspectorTransport

@MainActor
final class DOMSessionHighlightController {
    var targetID: ProtocolTarget.ID?
}

@MainActor
final class DOMSessionElementPickerController {
    final class Session {
        let targetID: ProtocolTarget.ID

        init(targetID: ProtocolTarget.ID) {
            self.targetID = targetID
        }
    }

    private enum Phase {
        case idle
        case enabling(Session)
        case accepting(Session)

        var session: Session? {
            switch self {
            case .idle:
                nil
            case let .enabling(session), let .accepting(session):
                session
            }
        }

        func acceptingSession() -> Session? {
            guard case let .accepting(session) = self else {
                return nil
            }
            return session
        }
    }

    private var phase: Phase = .idle
    private var completionSession: Session?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    var targetID: ProtocolTarget.ID? {
        phase.session?.targetID
    }

    var isSelecting: Bool {
        phase.session != nil
    }

    func begin(targetID: ProtocolTarget.ID) -> Session {
        let session = Session(targetID: targetID)
        phase = .enabling(session)
        return session
    }

    @discardableResult
    func beginAcceptingInspectEvents(for session: Session) -> Bool {
        guard case let .enabling(currentSession) = phase,
              currentSession === session else {
            return false
        }
        phase = .accepting(session)
        return true
    }

    func currentAcceptingSession() -> Session? {
        phase.acceptingSession()
    }

    func isCurrentAcceptingSession(_ session: Session) -> Bool {
        guard let currentSession = phase.acceptingSession() else {
            return false
        }
        return currentSession === session
    }

    @discardableResult
    func beginCompletion(for session: Session) -> Bool {
        guard isCurrentAcceptingSession(session) else {
            return false
        }
        completionSession = session
        return true
    }

    func finishCompletion(for session: Session) {
        guard completionSession === session else {
            return
        }
        completionSession = nil
        resumeIdleWaitersIfNeeded()
    }

    @discardableResult
    func clear() -> ProtocolTarget.ID? {
        let targetID = phase.session?.targetID
        phase = .idle
        resumeIdleWaitersIfNeeded()
        return targetID
    }

    func waitUntilIdle() async {
        guard phase.session != nil || completionSession != nil else {
            return
        }
        await withCheckedContinuation { continuation in
            if phase.session == nil && completionSession == nil {
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
            }
        }
    }

    private func resumeIdleWaitersIfNeeded() {
        guard phase.session == nil && completionSession == nil else {
            return
        }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

@MainActor
final class DOMSessionDocumentRequestController {
    private var handlesByTargetID: [ProtocolTarget.ID: DOMSessionDocumentRequestHandle] = [:]

    func activeHandle(for targetID: ProtocolTarget.ID) -> DOMSessionDocumentRequestHandle? {
        handlesByTargetID[targetID]
    }

    func register(_ handle: DOMSessionDocumentRequestHandle) {
        handlesByTargetID[handle.targetID] = handle
    }

    func isActive(_ handle: DOMSessionDocumentRequestHandle) -> Bool {
        handlesByTargetID[handle.targetID] === handle
    }

    func finish(_ handle: DOMSessionDocumentRequestHandle) {
        guard isActive(handle) else {
            return
        }
        handlesByTargetID.removeValue(forKey: handle.targetID)
    }

    func cancel(targetID: ProtocolTarget.ID) {
        let handle = handlesByTargetID.removeValue(forKey: targetID)
        handle?.cancel()
    }

    func cancelAll() {
        let handles = Array(handlesByTargetID.values)
        handlesByTargetID.removeAll()
        for handle in handles {
            handle.cancel()
        }
    }

    func waitUntilIdle(targetID: ProtocolTarget.ID? = nil) async {
        while let handle = activeHandle(matching: targetID) {
            await handle.wait()
        }
    }

    private func activeHandle(matching targetID: ProtocolTarget.ID?) -> DOMSessionDocumentRequestHandle? {
        if let targetID {
            return handlesByTargetID[targetID]
        }
        return handlesByTargetID.values.first
    }
}

@MainActor
final class DOMSessionElementStyleHydrationController {
    @MainActor
    private final class Refresh {
        let identity: CSSNodeStyles.Identity
        fileprivate var task: Task<Void, Never>?

        init(identity: CSSNodeStyles.Identity) {
            self.identity = identity
        }

        func wait() async {
            await task?.value
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }

    @MainActor
    private final class PropertyUpdateRequest {
        let propertyID: CSSProperty.ID
        fileprivate var task: Task<Void, Never>?

        init(propertyID: CSSProperty.ID) {
            self.propertyID = propertyID
        }

        func wait() async {
            await task?.value
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }

    private(set) var isActive = false
    private var activeRefresh: Refresh?
    private var propertyUpdateRequests: [CSSProperty.ID: PropertyUpdateRequest] = [:]

    @discardableResult
    func setActive(_ isActive: Bool) -> Bool {
        guard self.isActive != isActive else {
            return false
        }
        self.isActive = isActive
        return true
    }

    func isRefreshing(identity: CSSNodeStyles.Identity) -> Bool {
        activeRefresh?.identity == identity
    }

    @discardableResult
    func startRefresh(
        identity: CSSNodeStyles.Identity,
        operation: @escaping @MainActor (CSSNodeStyles.Identity) async -> Void
    ) -> CSSNodeStyles.Identity? {
        let cancelledIdentity = cancelRefresh()
        let refresh = Refresh(identity: identity)
        activeRefresh = refresh
        refresh.task = Task { @MainActor [weak self, weak refresh] in
            guard let refresh else {
                return
            }
            defer {
                self?.finishRefresh(refresh)
            }
            await operation(refresh.identity)
        }
        return cancelledIdentity
    }

    @discardableResult
    func cancelRefresh() -> CSSNodeStyles.Identity? {
        guard let refresh = activeRefresh else {
            return nil
        }
        activeRefresh = nil
        refresh.cancel()
        return refresh.identity
    }

    @discardableResult
    func startPropertyUpdate(
        propertyID: CSSProperty.ID,
        operation: @escaping @MainActor (CSSProperty.ID) async -> Void
    ) -> Bool {
        guard propertyUpdateRequests[propertyID] == nil else {
            return false
        }
        let request = PropertyUpdateRequest(propertyID: propertyID)
        propertyUpdateRequests[propertyID] = request
        request.task = Task { @MainActor [weak self, weak request] in
            guard let request else {
                return
            }
            defer {
                self?.finishPropertyUpdate(request)
            }
            await operation(request.propertyID)
        }
        return true
    }

    func cancelPropertyUpdates() {
        let requests = Array(propertyUpdateRequests.values)
        propertyUpdateRequests.removeAll()
        for request in requests {
            request.cancel()
        }
    }

    func waitUntilRefreshIdle() async {
        while let refresh = activeRefresh {
            await refresh.wait()
        }
    }

    func waitUntilIdle() async {
        while activeRefresh != nil || propertyUpdateRequests.isEmpty == false {
            if let request = propertyUpdateRequests.values.first {
                await request.wait()
            }
            if let refresh = activeRefresh {
                await refresh.wait()
            }
        }
    }

    func waitUntilPropertyUpdatesIdle() async {
        while let request = propertyUpdateRequests.values.first {
            await request.wait()
        }
    }

    private func finishRefresh(_ refresh: Refresh) {
        guard activeRefresh === refresh else {
            return
        }
        activeRefresh = nil
    }

    private func finishPropertyUpdate(_ request: PropertyUpdateRequest) {
        guard propertyUpdateRequests[request.propertyID] === request else {
            return
        }
        propertyUpdateRequests.removeValue(forKey: request.propertyID)
    }
}

@MainActor
final class DOMSessionDeleteUndoController {
    weak var undoManager: UndoManager?
    var states: [DOMSessionDeleteUndoState] = []
    let operationQueue = DOMSessionDeleteUndoOperationQueue()

    func remember(_ undoManager: UndoManager) {
        self.undoManager = undoManager
    }

    func track(_ state: DOMSessionDeleteUndoState) {
        guard states.contains(where: { $0 === state }) == false else {
            return
        }
        states.append(state)
    }

    func clear(using undoManager: UndoManager? = nil, undoTarget: AnyObject) {
        let manager = undoManager ?? self.undoManager
        manager?.removeAllActions(withTarget: undoTarget)
        if let manager, manager === self.undoManager {
            self.undoManager = nil
        }
        states.removeAll()
        operationQueue.invalidate()
    }

    func stateIsCurrent(
        _ state: DOMSessionDeleteUndoState,
        currentDocumentID: DOMDocument.ID?,
        undoManager: UndoManager,
        undoTarget: AnyObject,
        operation: String,
        recordError: (InspectorSession.Error?) -> Void
    ) -> Bool {
        guard currentDocumentID == state.documentID else {
            clear(using: undoManager, undoTarget: undoTarget)
            recordError(InspectorSession.Error("DOM document changed before \(operation)."))
            return false
        }
        return true
    }

    func updateDocumentID(
        for state: DOMSessionDeleteUndoState,
        currentDocumentID: DOMDocument.ID?,
        undoManager: UndoManager,
        undoTarget: AnyObject,
        recordError: (InspectorSession.Error?) -> Void
    ) {
        guard let currentDocumentID else {
            clear(using: undoManager, undoTarget: undoTarget)
            recordError(InspectorSession.Error("DOM document is unavailable after delete undo operation."))
            return
        }
        var updatedTrackedState = false
        for trackedState in states where trackedState.documentTargetID == state.documentTargetID {
            trackedState.documentID = currentDocumentID
            updatedTrackedState = true
        }
        if updatedTrackedState == false {
            state.documentID = currentDocumentID
        }
    }
}

@MainActor
final class DOMSessionDeleteUndoState {
    let documentTargetID: ProtocolTarget.ID
    let commandTargetID: ProtocolTarget.ID
    var documentID: DOMDocument.ID
    var actionName: String

    init(
        documentTargetID: ProtocolTarget.ID,
        commandTargetID: ProtocolTarget.ID,
        documentID: DOMDocument.ID,
        actionName: String = "Delete Node"
    ) {
        self.documentTargetID = documentTargetID
        self.commandTargetID = commandTargetID
        self.documentID = documentID
        self.actionName = actionName
    }
}

@MainActor
final class DOMSessionDeleteUndoOperationQueue {
    @MainActor
    private final class QueuedOperation {
        let id: UInt64
        let generation: UInt64
        var task: Task<Void, Never>?

        init(id: UInt64, generation: UInt64) {
            self.id = id
            self.generation = generation
        }

        func wait() async {
            await task?.value
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }

    private var generation: UInt64 = 0
    private var operationsByID: [UInt64: QueuedOperation] = [:]
    private var tailOperationID: UInt64?
    private var nextOperationID: UInt64 = 0

    func enqueue(_ body: @escaping @MainActor (UInt64) async -> Void) {
        let previousOperation = tailOperationID.flatMap { operationsByID[$0] }
        let operationGeneration = generation
        nextOperationID &+= 1
        let operation = QueuedOperation(id: nextOperationID, generation: operationGeneration)
        let operationID = operation.id
        let task = Task { @MainActor [weak self] in
            await previousOperation?.wait()
            guard let self,
                  let currentOperation = operationsByID[operationID] else {
                return
            }
            defer {
                finish(currentOperation)
            }
            guard isCurrent(operationGeneration) else {
                return
            }
            await body(operationGeneration)
        }
        operation.task = task
        operationsByID[operation.id] = operation
        tailOperationID = operation.id
    }

    func invalidate() {
        generation &+= 1
        for operation in operationsByID.values {
            operation.cancel()
        }
        operationsByID.removeAll()
        tailOperationID = nil
    }

    func isCurrent(_ operationGeneration: UInt64) -> Bool {
        Task.isCancelled == false && generation == operationGeneration
    }

    func waitUntilIdle() async {
        while let operation = tailOperationID.flatMap({ operationsByID[$0] }) {
            await operation.wait()
        }
    }

    private func finish(_ operation: QueuedOperation) {
        guard operationsByID[operation.id] === operation else {
            return
        }
        operationsByID.removeValue(forKey: operation.id)
        operation.task = nil
        if tailOperationID == operation.id {
            tailOperationID = nil
        }
    }
}

@MainActor
final class DOMSessionDocumentRequestHandle {
    let targetID: ProtocolTarget.ID
    let targetKind: ProtocolTarget.Kind?
    var task: Task<Void, Error>?

    init(targetID: ProtocolTarget.ID, targetKind: ProtocolTarget.Kind?) {
        self.targetID = targetID
        self.targetKind = targetKind
    }

    func wait() async {
        _ = try? await task?.value
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
