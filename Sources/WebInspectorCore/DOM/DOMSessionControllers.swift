import Foundation
import WebInspectorTransport

@MainActor
final class DOMSessionHighlightController {
    var targetID: ProtocolTargetIdentifier?
}

@MainActor
final class DOMSessionElementPickerController {
    final class Session {
        let targetID: ProtocolTargetIdentifier

        init(targetID: ProtocolTargetIdentifier) {
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

    var targetID: ProtocolTargetIdentifier? {
        phase.session?.targetID
    }

    var isSelecting: Bool {
        phase.session != nil
    }

    func begin(targetID: ProtocolTargetIdentifier) -> Session {
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
    func clear() -> ProtocolTargetIdentifier? {
        let targetID = phase.session?.targetID
        phase = .idle
        return targetID
    }
}

@MainActor
final class DOMSessionDocumentRequestController {
    private var handlesByTargetID: [ProtocolTargetIdentifier: DOMSessionDocumentRequestHandle] = [:]

    func activeHandle(for targetID: ProtocolTargetIdentifier) -> DOMSessionDocumentRequestHandle? {
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

    func cancel(targetID: ProtocolTargetIdentifier) {
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
}

@MainActor
final class DOMSessionElementStyleHydrationController {
    private final class Refresh {
        let identity: CSSNodeStyleIdentity
        fileprivate var task: Task<Void, Never>?

        init(identity: CSSNodeStyleIdentity) {
            self.identity = identity
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }

    private final class PropertyUpdateRequest {
        let propertyID: CSSPropertyIdentifier
        fileprivate var task: Task<Void, Never>?

        init(propertyID: CSSPropertyIdentifier) {
            self.propertyID = propertyID
        }

        func cancel() {
            task?.cancel()
            task = nil
        }
    }

    private(set) var isActive = false
    private var activeRefresh: Refresh?
    private var propertyUpdateRequests: [CSSPropertyIdentifier: PropertyUpdateRequest] = [:]

    @discardableResult
    func setActive(_ isActive: Bool) -> Bool {
        guard self.isActive != isActive else {
            return false
        }
        self.isActive = isActive
        return true
    }

    func isRefreshing(identity: CSSNodeStyleIdentity) -> Bool {
        activeRefresh?.identity == identity
    }

    @discardableResult
    func startRefresh(
        identity: CSSNodeStyleIdentity,
        operation: @escaping @MainActor (CSSNodeStyleIdentity) async -> Void
    ) -> CSSNodeStyleIdentity? {
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
    func cancelRefresh() -> CSSNodeStyleIdentity? {
        guard let refresh = activeRefresh else {
            return nil
        }
        activeRefresh = nil
        refresh.cancel()
        return refresh.identity
    }

    @discardableResult
    func startPropertyUpdate(
        propertyID: CSSPropertyIdentifier,
        operation: @escaping @MainActor (CSSPropertyIdentifier) async -> Void
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
}

@MainActor
final class DOMSessionDeleteUndoState {
    let documentTargetID: ProtocolTargetIdentifier
    let commandTargetID: ProtocolTargetIdentifier
    var documentID: DOMDocumentIdentifier
    var actionName: String

    init(
        documentTargetID: ProtocolTargetIdentifier,
        commandTargetID: ProtocolTargetIdentifier,
        documentID: DOMDocumentIdentifier,
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
    private var generation: UInt64 = 0
    private var tail: Task<Void, Never>?
    private var tasksByID: [UInt64: Task<Void, Never>] = [:]
    private var nextTaskID: UInt64 = 0

    func enqueue(_ operation: @escaping @MainActor (UInt64) async -> Void) {
        let previousOperation = tail
        let operationGeneration = generation
        nextTaskID &+= 1
        let taskID = nextTaskID
        let task = Task { @MainActor [weak self] in
            await previousOperation?.value
            guard let self else {
                return
            }
            defer {
                tasksByID[taskID] = nil
            }
            guard isCurrent(operationGeneration) else {
                return
            }
            await operation(operationGeneration)
        }
        tail = task
        tasksByID[taskID] = task
    }

    func invalidate() {
        generation &+= 1
        for task in tasksByID.values {
            task.cancel()
        }
        tasksByID.removeAll()
        tail = nil
    }

    func isCurrent(_ operationGeneration: UInt64) -> Bool {
        Task.isCancelled == false && generation == operationGeneration
    }
}

@MainActor
final class DOMSessionDocumentRequestHandle {
    let targetID: ProtocolTargetIdentifier
    let targetKind: ProtocolTargetKind?
    var task: Task<Void, Error>?

    init(targetID: ProtocolTargetIdentifier, targetKind: ProtocolTargetKind?) {
        self.targetID = targetID
        self.targetKind = targetKind
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
