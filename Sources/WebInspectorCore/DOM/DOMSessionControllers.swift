import Foundation
import WebInspectorTransport

@MainActor
final class DOMSessionHighlightController {
    struct PossibleVisibleHighlight: Equatable {
        var targetID: ProtocolTarget.ID
        var generation: UInt64?
        var nodeID: DOMNode.ID?
        var owner: DOMPageHighlightOwner?
    }

    private struct PossibleVisibleTarget: Equatable {
        var targetID: ProtocolTarget.ID
        var generation: UInt64
        var nodeID: DOMNode.ID?
        var owner: DOMPageHighlightOwner?
    }

    // WebKit does not expose the current overlay state, and a task can be
    // cancelled after a highlight command has reached the backend. Track
    // targets that may still need an explicit hide instead of tying ownership
    // to command replies.
    private var possibleVisibleTargets: [PossibleVisibleTarget] = []
    private var nextGeneration: UInt64 = 0

    var hasPossibleVisibleHighlight: Bool {
        !possibleVisibleTargets.isEmpty
    }

    func possibleVisibleHighlights(
        preferredFirst preferredTargetID: ProtocolTarget.ID?,
        fallbackTargetID: ProtocolTarget.ID?,
        preserving preservedTargetID: ProtocolTarget.ID?
    ) -> [PossibleVisibleHighlight] {
        var highlights: [PossibleVisibleHighlight] = []
        let candidates = [preferredTargetID] + possibleVisibleTargets.map { Optional.some($0.targetID) }
        for targetID in candidates.compactMap(\.self)
        where targetID != preservedTargetID && !highlights.contains(where: { $0.targetID == targetID }) {
            highlights.append(
                PossibleVisibleHighlight(
                    targetID: targetID,
                    generation: possibleVisibleGeneration(targetID: targetID),
                    nodeID: possibleVisibleNodeID(targetID: targetID),
                    owner: possibleVisibleOwner(targetID: targetID)
                )
            )
        }
        if highlights.isEmpty,
           let fallbackTargetID,
           fallbackTargetID != preservedTargetID {
            highlights.append(
                PossibleVisibleHighlight(
                    targetID: fallbackTargetID,
                    generation: nil,
                    nodeID: nil,
                    owner: nil
                )
            )
        }
        return highlights
    }

    func possibleVisibleGeneration(targetID: ProtocolTarget.ID) -> UInt64? {
        possibleVisibleTargets.first { $0.targetID == targetID }?.generation
    }

    func possibleVisibleNodeID(targetID: ProtocolTarget.ID) -> DOMNode.ID? {
        possibleVisibleTargets.first { $0.targetID == targetID }?.nodeID
    }

    func possibleVisibleOwner(targetID: ProtocolTarget.ID) -> DOMPageHighlightOwner? {
        possibleVisibleTargets.first { $0.targetID == targetID }?.owner
    }

    func possibleVisibleSelectionHighlight(for nodeID: DOMNode.ID) -> PossibleVisibleHighlight? {
        possibleVisibleTargets.lazy
            .filter { $0.nodeID == nodeID && $0.owner == .selection }
            .map {
                PossibleVisibleHighlight(
                    targetID: $0.targetID,
                    generation: $0.generation,
                    nodeID: $0.nodeID,
                    owner: $0.owner
                )
            }
            .first
    }

    func possibleVisibleHighlight(targetID: ProtocolTarget.ID) -> PossibleVisibleHighlight {
        PossibleVisibleHighlight(
            targetID: targetID,
            generation: possibleVisibleGeneration(targetID: targetID),
            nodeID: possibleVisibleNodeID(targetID: targetID),
            owner: possibleVisibleOwner(targetID: targetID)
        )
    }

    func isPossibleVisibleHighlight(
        targetID: ProtocolTarget.ID,
        generation: UInt64,
        nodeID: DOMNode.ID?,
        owner: DOMPageHighlightOwner?
    ) -> Bool {
        possibleVisibleTargets.contains {
            $0.targetID == targetID
                && $0.generation == generation
                && (nodeID == nil || $0.nodeID == nodeID)
                && (owner == nil || $0.owner == owner)
        }
    }

    func markHighlightMayBeVisible(
        targetID: ProtocolTarget.ID,
        nodeID: DOMNode.ID? = nil,
        owner: DOMPageHighlightOwner? = nil
    ) {
        nextGeneration &+= 1
        clearHighlight(targetID: targetID)
        possibleVisibleTargets.append(
            PossibleVisibleTarget(
                targetID: targetID,
                generation: nextGeneration,
                nodeID: nodeID,
                owner: owner
            )
        )
    }

    func clearHighlight(targetID: ProtocolTarget.ID) {
        possibleVisibleTargets.removeAll { $0.targetID == targetID }
    }

    func clearHighlight(targetID: ProtocolTarget.ID, matchingGeneration generation: UInt64?) {
        guard let generation else {
            return
        }
        possibleVisibleTargets.removeAll { $0.targetID == targetID && $0.generation == generation }
    }

    func clearAll() {
        possibleVisibleTargets.removeAll()
    }
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

    var currentSession: Session? {
        phase.session
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

    func isCurrentEnablingSession(_ session: Session) -> Bool {
        guard case let .enabling(currentSession) = phase else {
            return false
        }
        return currentSession === session
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

    @discardableResult
    func clear(ifCurrent session: Session) -> Bool {
        guard phase.session === session else {
            return false
        }
        clear()
        return true
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

    #if DEBUG
    func recordCoalescedWaiter(for handle: DOMSessionDocumentRequestHandle) {
        guard isActive(handle) else {
            return
        }
        handle.recordCoalescedWaiter()
    }
    #endif

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

    #if DEBUG
    func waitUntilCoalescedWaiterCount(
        targetID: ProtocolTarget.ID,
        minimumCount: Int
    ) async {
        precondition(minimumCount > 0, "minimumCount must be positive")
        guard let handle = activeHandle(for: targetID) else {
            return
        }
        await handle.waitUntilCoalescedWaiterCount(minimumCount)
    }
    #endif

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
        let token: CSSStyle.RefreshToken
        fileprivate var task: Task<Void, Never>?

        init(token: CSSStyle.RefreshToken) {
            self.token = token
        }

        func wait() async {
            await task?.value
        }

        func cancel() {
            task?.cancel()
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
    private var cancelledRefreshes: [Refresh] = []
    private var propertyUpdateRequests: [CSSProperty.ID: PropertyUpdateRequest] = [:]

    @discardableResult
    func setActive(_ isActive: Bool) -> Bool {
        guard self.isActive != isActive else {
            return false
        }
        self.isActive = isActive
        return true
    }

    func isRefreshing(id: CSSNodeStyles.ID) -> Bool {
        activeRefresh?.token.id == id
    }

    @discardableResult
    func startRefresh(
        token: CSSStyle.RefreshToken,
        operation: @escaping @MainActor (CSSStyle.RefreshToken) async -> Void
    ) -> CSSStyle.RefreshToken? {
        let cancelledToken = cancelRefresh()
        let refresh = Refresh(token: token)
        activeRefresh = refresh
        refresh.task = Task { @MainActor [weak self, weak refresh] in
            guard let refresh else {
                return
            }
            defer {
                self?.finishRefresh(refresh)
            }
            await operation(refresh.token)
        }
        return cancelledToken
    }

    @discardableResult
    func cancelRefresh() -> CSSStyle.RefreshToken? {
        guard let refresh = activeRefresh else {
            return nil
        }
        activeRefresh = nil
        refresh.cancel()
        cancelledRefreshes.append(refresh)
        return refresh.token
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
        while activeRefresh != nil || cancelledRefreshes.isEmpty == false {
            if let refresh = activeRefresh {
                await refresh.wait()
            }
            if let refresh = cancelledRefreshes.first {
                await refresh.wait()
            }
        }
    }

    func waitUntilIdle() async {
        while activeRefresh != nil || cancelledRefreshes.isEmpty == false || propertyUpdateRequests.isEmpty == false {
            if let request = propertyUpdateRequests.values.first {
                await request.wait()
            }
            if let refresh = activeRefresh {
                await refresh.wait()
            }
            if let refresh = cancelledRefreshes.first {
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
            cancelledRefreshes.removeAll { $0 === refresh }
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
    #if DEBUG
    private struct CoalescedWaiterContinuation {
        var minimumCount: Int
        var continuation: CheckedContinuation<Void, Never>
    }
    #endif

    let targetID: ProtocolTarget.ID
    let targetKind: ProtocolTarget.Kind?
    var task: Task<Void, Error>?
    #if DEBUG
    private var coalescedWaiterCount = 0
    private var coalescedWaiterContinuations: [CoalescedWaiterContinuation] = []
    #endif

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

    #if DEBUG
    func recordCoalescedWaiter() {
        coalescedWaiterCount += 1
        resumeCoalescedWaiterContinuationsIfNeeded()
    }

    func waitUntilCoalescedWaiterCount(_ minimumCount: Int) async {
        guard coalescedWaiterCount < minimumCount else {
            return
        }
        await withCheckedContinuation { continuation in
            if coalescedWaiterCount >= minimumCount {
                continuation.resume()
            } else {
                coalescedWaiterContinuations.append(
                    CoalescedWaiterContinuation(
                        minimumCount: minimumCount,
                        continuation: continuation
                    )
                )
            }
        }
    }

    private func resumeCoalescedWaiterContinuationsIfNeeded() {
        let readyContinuations = coalescedWaiterContinuations.filter {
            coalescedWaiterCount >= $0.minimumCount
        }
        guard !readyContinuations.isEmpty else {
            return
        }
        coalescedWaiterContinuations.removeAll {
            coalescedWaiterCount >= $0.minimumCount
        }
        for readyContinuation in readyContinuations {
            readyContinuation.continuation.resume()
        }
    }
    #endif
}
