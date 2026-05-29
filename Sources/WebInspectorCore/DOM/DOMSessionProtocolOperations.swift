import Foundation
import ObservationBridge
import WebInspectorTransport

@MainActor
final class DOMSessionHighlightController {
    var targetID: ProtocolTargetIdentifier?
}

@MainActor
final class DOMSessionElementPickerController {
    var targetID: ProtocolTargetIdentifier?
    var generation: UInt64 = 0
    var acceptsInspectEvents = false
}

@MainActor
final class DOMSessionDocumentRequestController {
    var handlesByTargetID: [ProtocolTargetIdentifier: DOMSessionDocumentRequestHandle] = [:]
}

@MainActor
final class DOMSessionElementStyleHydrationController {
    let observationScope = ObservationScope()
    var refreshTask: Task<Void, Never>?
    var refreshIdentity: CSSNodeStyleIdentity?
    var isActive = false
    var propertyUpdateTasks: [CSSPropertyIdentifier: Task<Void, Never>] = [:]
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
}

private enum DOMInspectRoute {
    case remoteObject(targetID: ProtocolTargetIdentifier, objectID: String)
    case protocolNode(targetID: ProtocolTargetIdentifier, nodeID: DOMProtocolNodeID)
}

private struct TargetDestroyedEventParams: Decodable {
    var targetId: ProtocolTargetIdentifier
}

extension DOMSession {
    package var canReloadDocument: Bool {
        hasActiveCommandChannel && currentPageTargetID != nil
    }

    package var canBeginElementPicker: Bool {
        hasActiveCommandChannel && currentPageTargetID != nil
    }

    package var canSelectElement: Bool {
        hasActiveCommandChannel && currentPageRootNode != nil
    }

    package var canCopySelectedNodeText: Bool {
        hasActiveCommandChannel && selectedNodeID != nil
    }

    package var canDeleteSelectedNode: Bool {
        hasActiveCommandChannel && selectedNodeID != nil
    }

    private var hasActiveCommandChannel: Bool {
        commandChannel?.acceptsActiveCommands == true
    }

    package func bindProtocolChannel(
        _ commandChannel: ProtocolCommandChannel,
        recordError: @escaping (InspectorSessionError?) -> Void
    ) {
        self.commandChannel = commandChannel
        self.recordError = recordError
        elementStyles.bindProtocolChannel(commandChannel)
        if styleHydration.isActive {
            startSelectedNodeStyleHydration()
        }
    }

    package func unbindProtocolChannel() {
        stopSelectedNodeStyleHydration()
        cancelDocumentRequests()
        cancelCSSActionRequests()
        commandChannel = nil
        recordError = nil
        elementStyles.unbindProtocolChannel()
        highlightController.targetID = nil
        clearElementPickerState(invalidatePendingSelection: true)
        clearDeleteUndoHistory()
    }

    package func prepareForDocumentReload() async {
        if isSelectingElement {
            await cancelElementPicker()
        }
        clearDeleteUndoHistory()
    }

    package func prepareForPageReload() async {
        await cancelElementPicker()
        clearDeleteUndoHistory()
        cancelDocumentRequests()
        cancelCSSActionRequests()
    }

    @discardableResult
    package func perform(_ intent: DOMCommandIntent) async throws -> ProtocolCommandResult {
        try await perform(intent, requiresActiveConnection: true)
    }

    @discardableResult
    package func performDuringBootstrap(_ intent: DOMCommandIntent) async throws -> ProtocolCommandResult {
        try await perform(intent, requiresActiveConnection: false)
    }

    @discardableResult
    private func perform(
        _ intent: DOMCommandIntent,
        requiresActiveConnection: Bool
    ) async throws -> ProtocolCommandResult {
        let result = try await send(intent, requiresActiveConnection: requiresActiveConnection)

        switch intent {
        case .getDocument:
            try applyGetDocumentResult(result)
        case let .requestNode(selectionRequestID, targetID, _):
            let selectionResult = try protocolCommands.applyRequestNodeResult(
                result,
                selectionRequestID: selectionRequestID,
                to: self
            )
            switch selectionResult {
            case .resolved, .pending:
                break
            case let .failed(failure):
                InspectorRuntimeLog.warning("requestNode.selectFailure target=\(targetID.rawValue) failure=\(failure)")
                recordError?(InspectorSessionError(String(describing: failure)))
            }
        case .requestChildNodes:
            break
        case let .highlightNode(identity):
            highlightController.targetID = identity.commandTargetID
        case let .hideHighlight(targetID):
            if highlightController.targetID == targetID {
                highlightController.targetID = nil
            }
        case .setInspectModeEnabled,
             .getOuterHTML,
             .removeNode,
             .undo,
             .redo:
            break
        }
        return result
    }

    @discardableResult
    private func send(
        _ intent: DOMCommandIntent,
        requiresActiveConnection: Bool = true
    ) async throws -> ProtocolCommandResult {
        let commandChannel = try requireCommandChannel(requiresActiveConnection: requiresActiveConnection)
        let command = try protocolCommands.command(for: intent)
        return try await commandChannel.send(command)
    }

    @discardableResult
    package func requestChildNodes(for nodeID: DOMNodeIdentifier, depth: Int = 3) async -> Bool {
        guard let intent = requestChildNodesIntent(
            for: nodeID,
            depth: depth,
            issuedSequence: currentAppliedDOMSequence
        ) else {
            return false
        }
        do {
            try await perform(intent)
            return true
        } catch {
            recordError?(InspectorSessionError(String(describing: error)))
            return false
        }
    }

    package func highlightNode(for nodeID: DOMNodeIdentifier) async {
        guard let intent = highlightNodeIntent(for: nodeID) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            recordError?(InspectorSessionError(String(describing: error)))
        }
    }

    package func hideNodeHighlight() async {
        guard let intent = hideHighlightIntent(targetID: highlightController.targetID) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            recordError?(InspectorSessionError(String(describing: error)))
        }
    }

    package func toggleElementPicker() async {
        if isSelectingElement {
            await cancelElementPicker()
            return
        }
        do {
            try await beginElementPicker()
        } catch {
            recordError?(InspectorSessionError(String(describing: error)))
        }
    }

    package func beginElementPicker() async throws {
        var targetID = try currentPageTargetForDOMAction()
        if currentPageRootNode == nil {
            let loaded = await ensureDocumentLoaded()
            guard loaded else {
                recordElementPickerFailure(
                    reason: "documentNotReady",
                    targetID: targetID,
                    details: "current=\(currentPageTargetID?.rawValue ?? "nil") root=false"
                )
                throw InspectorSessionError("DOM is not ready for element selection.")
            }
            targetID = try currentPageTargetForDOMAction()
        }
        guard canSelectElement else {
            recordElementPickerFailure(
                reason: "documentNotReady",
                targetID: targetID,
                details: "current=\(currentPageTargetID?.rawValue ?? "nil") root=\(currentPageRootNode != nil) connected=\(commandChannel != nil)"
            )
            throw InspectorSessionError("DOM is not ready for element selection.")
        }
        if isSelectingElement {
            await cancelElementPicker()
        }

        elementPicker.generation &+= 1
        let pickerGeneration = elementPicker.generation
        elementPicker.targetID = targetID
        elementPicker.acceptsInspectEvents = false
        isSelectingElement = true

        do {
            guard let intent = setInspectModeEnabledIntent(targetID: targetID, enabled: true) else {
                recordElementPickerFailure(reason: "inspectModeUnavailable", targetID: targetID)
                throw InspectorSessionError("DOM inspect mode is not available.")
            }
            try await perform(intent)
            guard isElementPickerSession(generation: pickerGeneration, targetID: targetID) else {
                return
            }
            elementPicker.acceptsInspectEvents = true
            recordError?(nil)
        } catch {
            recordElementPickerFailure(
                reason: "inspectModeCommandFailed",
                targetID: targetID,
                details: "error=\(error)"
            )
            clearElementPickerState(invalidatePendingSelection: true)
            throw error
        }
    }

    package func cancelElementPicker() async {
        let targetID = elementPicker.targetID ?? currentPageTargetID
        clearElementPickerState(invalidatePendingSelection: true)
        guard let targetID,
              let intent = setInspectModeEnabledIntent(targetID: targetID, enabled: false) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            recordError?(InspectorSessionError(String(describing: error)))
        }
    }

    package func copySelectedNodeText(_ kind: DOMNodeCopyTextKind) async throws -> String {
        guard commandChannel != nil else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        guard let nodeID = selectedNodeID else {
            throw InspectorSessionError("No DOM node is selected.")
        }
        return try await copyNodeText(kind, for: nodeID)
    }

    package func copyNodeText(_ kind: DOMNodeCopyTextKind, for nodeID: DOMNode.ID) async throws -> String {
        guard commandChannel != nil else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        switch kind {
        case .html:
            let commandTargetID = try currentPageTargetForDOMAction()
            guard let intent = outerHTMLIntent(for: nodeID, commandTargetID: commandTargetID) else {
                throw InspectorSessionError("DOM node is no longer available.")
            }
            let result = try await perform(intent)
            return try protocolCommands.outerHTML(from: result)
        case .selectorPath:
            guard let node = node(for: nodeID) else {
                throw InspectorSessionError("DOM node is no longer available.")
            }
            return selectorPath(for: node)
        case .xPath:
            guard let node = node(for: nodeID) else {
                throw InspectorSessionError("DOM node is no longer available.")
            }
            return xPath(for: node)
        }
    }

    package func deleteSelectedNode(undoManager: UndoManager?) async throws {
        guard commandChannel != nil else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        guard let nodeID = selectedNodeID else {
            throw InspectorSessionError("No DOM node is selected.")
        }
        try await deleteNode(nodeID, undoManager: undoManager)
    }

    package func deleteNodes(_ nodeIDs: [DOMNode.ID], undoManager: UndoManager?) async throws {
        var seenNodeIDs: Set<DOMNode.ID> = []
        let uniqueNodeIDs = nodeIDs.filter { seenNodeIDs.insert($0).inserted }
        let actionName = uniqueNodeIDs.count > 1 ? "Delete Nodes" : "Delete Node"
        var undoStates: [DOMSessionDeleteUndoState] = []

        do {
            for nodeID in uniqueNodeIDs.sorted(by: { depthFromRoot(for: $0) > depthFromRoot(for: $1) }) {
                undoStates.append(try await performDeleteNode(nodeID))
            }
        } catch {
            registerUndoDeletes(undoStates, undoManager: undoManager, actionName: actionName)
            throw error
        }
        registerUndoDeletes(undoStates, undoManager: undoManager, actionName: actionName)
    }

    package func deleteNode(_ nodeID: DOMNode.ID, undoManager: UndoManager?) async throws {
        let undoState = try await performDeleteNode(nodeID)
        if let undoManager {
            registerUndoDelete(undoState, undoManager: undoManager)
        }
    }

    package func reloadDocument() async throws {
        await prepareForDocumentReload()
        try await reloadDocument(targetID: currentPageTargetForDOMAction(), force: true)
    }

    @discardableResult
    package func ensureDocumentLoaded() async -> Bool {
        guard commandChannel != nil,
              let targetID = currentPageTargetID else {
            return false
        }
        guard currentPageRootNode == nil else {
            return true
        }

        do {
            try await reloadDocument(targetID: targetID)
            return currentPageRootNode != nil
        } catch is CancellationError {
            guard commandChannel != nil,
                  currentPageRootNode == nil else {
                return currentPageRootNode != nil
            }
            do {
                try await reloadDocument(targetID: targetID)
                return currentPageRootNode != nil
            } catch {
                recordError?(InspectorSessionError(String(describing: error)))
                return false
            }
        } catch {
            recordError?(InspectorSessionError(String(describing: error)))
            return false
        }
    }

    package func refreshStylesForSelectedNode() async {
        do {
            try await refreshSelectedNodeStyles()
            recordError?(nil)
        } catch {
            recordError?(InspectorSessionError(String(describing: error)))
        }
    }

    package func setSelectedNodeStyleHydrationActive(_ isActive: Bool) {
        guard styleHydration.isActive != isActive else {
            return
        }
        styleHydration.isActive = isActive
        if isActive, commandChannel != nil {
            startSelectedNodeStyleHydration()
        } else {
            stopSelectedNodeStyleHydration()
        }
    }

    @discardableResult
    package func requestSetCSSProperty(_ propertyID: CSSPropertyIdentifier, enabled: Bool) -> Bool {
        guard commandChannel != nil,
              styleHydration.propertyUpdateTasks[propertyID] == nil,
              elementStyles.setStyleTextIntent(for: propertyID, enabled: enabled) != nil else {
            return false
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                styleHydration.propertyUpdateTasks[propertyID] = nil
            }
            guard Task.isCancelled == false else {
                return
            }

            do {
                try await setCSSProperty(propertyID, enabled: enabled)
            } catch {
                recordError?(InspectorSessionError(String(describing: error)))
                try? await refreshSelectedNodeStyles()
            }
        }
        styleHydration.propertyUpdateTasks[propertyID] = task
        return true
    }

    package func setCSSProperty(_ propertyID: CSSPropertyIdentifier, enabled: Bool) async throws {
        guard let intent = elementStyles.setStyleTextIntent(for: propertyID, enabled: enabled) else {
            throw InspectorSessionError("CSS property is not editable.")
        }
        let result = try await elementStyles.perform(intent)
        guard case let .setStyleText(targetID, _, _) = intent else {
            throw InspectorSessionError("Unexpected CSS command intent.")
        }
        let style = try elementStyles.setStyleTextResult(from: result)
        elementStyles.applySetStyleTextResult(style, propertyID: propertyID, targetID: targetID)
        try await refreshSelectedNodeStyles()
        recordError?(nil)
    }

    private func startSelectedNodeStyleHydration() {
        styleHydration.observationScope.cancelAll()
        styleHydration.observationScope.observe(self) { [weak self] _, _ in
            self?.reconcileSelectedNodeStyleHydration()
        }
    }

    private func stopSelectedNodeStyleHydration() {
        styleHydration.observationScope.cancelAll()
        cancelSelectedNodeStyleHydrationRefresh()
    }

    private func reconcileSelectedNodeStyleHydration() {
        guard commandChannel != nil else {
            return
        }
        guard currentPageRootNode != nil else {
            return
        }

        switch selectedCSSNodeStyleIdentity() {
        case let .success(identity):
            reconcileSelectedNodeStyles(identity)
        case let .failure(reason):
            cancelSelectedNodeStyleHydrationRefresh()
            elementStyles.markSelectedNodeUnavailable(reason)
        }
    }

    private func reconcileSelectedNodeStyles(_ identity: CSSNodeStyleIdentity) {
        switch elementStyles.refreshState(forSelected: identity) {
        case nil, .needsRefresh:
            hydrateSelectedNodeStyles(identity)
        case .loading, .loaded, .failed(_), .unavailable(_):
            return
        }
    }

    private func hydrateSelectedNodeStyles(_ identity: CSSNodeStyleIdentity) {
        guard styleHydration.refreshIdentity != identity else {
            return
        }

        cancelSelectedNodeStyleHydrationRefresh()
        styleHydration.refreshIdentity = identity
        styleHydration.refreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.styleHydration.refreshIdentity == identity {
                    self.styleHydration.refreshIdentity = nil
                    self.styleHydration.refreshTask = nil
                }
            }
            guard Task.isCancelled == false else {
                return
            }

            do {
                try await self.refreshStyles(for: identity)
                self.recordError?(nil)
            } catch is CancellationError {
                self.elementStyles.cancelRefresh(identity: identity)
            } catch {
                self.recordError?(InspectorSessionError(String(describing: error)))
            }
        }
    }

    private func cancelSelectedNodeStyleHydrationRefresh() {
        styleHydration.refreshTask?.cancel()
        styleHydration.refreshTask = nil
        if let refreshIdentity = styleHydration.refreshIdentity {
            elementStyles.cancelRefresh(identity: refreshIdentity)
        }
        styleHydration.refreshIdentity = nil
    }

    private func refreshSelectedNodeStyles() async throws {
        switch selectedCSSNodeStyleIdentity() {
        case let .success(identity):
            try await refreshStyles(for: identity)
        case let .failure(reason):
            elementStyles.markSelectedNodeUnavailable(reason)
        }
    }

    private func refreshStyles(for identity: CSSNodeStyleIdentity) async throws {
        let commandChannel = try requireCommandChannel()
        let targetExists = await commandChannel.snapshot().targetsByID[identity.targetID] != nil
        guard targetExists else {
            elementStyles.markSelectedNodeStylesUnavailable(identity: identity, reason: .staleNode(identity.nodeID))
            return
        }
        guard let token = elementStyles.beginRefresh(identity: identity) else {
            return
        }

        do {
            let results = try await elementStyles.fetchRefreshResults(for: identity)
            guard case let .success(currentIdentity) = selectedCSSNodeStyleIdentity(),
                  currentIdentity == identity else {
                return
            }

            elementStyles.applyRefresh(
                token: token,
                matched: results.matched,
                inline: results.inline,
                computed: results.computed
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            elementStyles.markRefreshFailed(token, message: String(describing: error))
            throw error
        }
    }

    package func inspectEvent(from event: ProtocolEventEnvelope) throws -> DOMInspectEvent? {
        try protocolCommands.inspectEvent(from: event)
    }

    package func applyTargetProtocolEvent(_ event: ProtocolEventEnvelope) throws -> TargetProtocolEventResult {
        let result = try TargetProtocolEventDispatcher().dispatch(event, to: self)
        let destroyedTargetID = result.destroyedTargetID
        let targetCommit = result.targetCommit
        if let destroyedTargetID {
            cancelDocumentRequest(targetID: destroyedTargetID, reason: "targetDestroyed")
            elementStyles.removeStyles(targetID: destroyedTargetID)
        }
        if let oldTargetID = targetCommit?.consumedOldTargetID {
            cancelDocumentRequest(targetID: oldTargetID, reason: "targetCommit")
            elementStyles.removeStyles(targetID: oldTargetID)
        }
        applyElementPickerTargetLifecycle(event, targetCommit: targetCommit)
        return result
    }

    package func handleDOMProtocolEvent(_ event: ProtocolEventEnvelope) async throws {
        if let inspectEvent = try protocolCommands.inspectEvent(from: event) {
            await handleInspectEvent(inspectEvent)
            return
        }
        if event.method == "DOM.documentUpdated" {
            if let targetID = event.targetID ?? currentPageTargetID {
                elementStyles.removeStyles(targetID: targetID)
            }
            refreshDocumentAfterBackendUpdate(event)
            return
        }
        let selectedStyleIdentity = try? selectedCSSNodeStyleIdentity().get()
        try protocolCommands.applyDOMEvent(event, to: self)
        if let selectedStyleIdentity,
           let targetID = event.targetID,
           selectedStyleIdentity.targetID == targetID {
            if selectedNodeID != selectedStyleIdentity.nodeID {
                elementStyles.removeStyles(targetID: targetID)
            } else if selectedStylesShouldRefresh(after: event) {
                elementStyles.markNeedsRefresh(targetID: targetID, nodeID: selectedStyleIdentity.protocolNodeID)
            }
        }
        if event.method == "DOM.setChildNodes" {
            startPendingFrameOwnerHydration()
        }
    }

    package func startDocumentRequestsForAttachedFrameTargets() {
        for target in snapshot().targetsByID.values
        where target.kind == .frame
            && target.capabilities.contains(.dom)
            && target.currentDocumentID == nil {
            startDocumentRequest(targetID: target.id, reason: "attachedFrameTarget")
        }
    }

    package func startFrameTargetDocumentRequestIfNeeded(targetID: ProtocolTargetIdentifier, reason: String) {
        guard commandChannel != nil,
              let target = snapshot().targetsByID[targetID],
              target.kind == .frame,
              target.capabilities.contains(.dom),
              target.currentDocumentID == nil else {
            return
        }
        startDocumentRequest(targetID: targetID, reason: reason)
    }

    package func startPageTargetDocumentRequestAfterCommit(
        targetID: ProtocolTargetIdentifier,
        isBootstrapped: Bool,
        bootstrap: @escaping @MainActor () async throws -> Void
    ) {
        if isBootstrapped {
            startDocumentRequest(targetID: targetID, reason: "pageTargetCommit")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await bootstrap()
            } catch {
                recordError?(InspectorSessionError(String(describing: error)))
            }
        }
    }

    package func handleInspectProtocolEvent(_ event: DOMInspectEvent) async {
        await handleInspectEvent(event)
    }

    private func handleInspectEvent(_ event: DOMInspectEvent) async {
        guard isSelectingElement,
              elementPicker.acceptsInspectEvents,
              let activeTargetID = elementPicker.targetID else {
            recordElementPickerFailure(
                reason: "inspectEventWithoutActivePicker",
                details: "activeTarget=\(elementPicker.targetID?.rawValue ?? "nil")"
            )
            return
        }
        let pickerGeneration = elementPicker.generation
        do {
            try await resolvePickerSelection(event, activeTargetID: activeTargetID)
        } catch {
            guard isCurrentElementPicker(generation: pickerGeneration, targetID: activeTargetID) else {
                return
            }
            recordElementPickerFailure(
                reason: "selectionResolveFailed",
                targetID: activeTargetID,
                details: "error=\(error)"
            )
            recordError?(InspectorSessionError(String(describing: error)))
        }

        await completeElementPicker(generation: pickerGeneration, targetID: activeTargetID)
    }

    private func resolvePickerSelection(
        _ event: DOMInspectEvent,
        activeTargetID: ProtocolTargetIdentifier
    ) async throws {
        switch inspectRoute(for: event, activeTargetID: activeTargetID) {
        case let .remoteObject(targetID, objectID):
            if currentDocumentID(for: targetID) == nil {
                try await reloadDocument(targetID: targetID)
            }
            let intentResult = beginInspectSelectionRequest(
                targetID: targetID,
                objectID: objectID,
                issuedSequence: currentAppliedDOMSequence
            )
            switch intentResult {
            case let .success(intent):
                try await perform(intent)
                if let failure = snapshot().selection.failure {
                    throw InspectorSessionError("DOM.requestNode failed: \(failure)")
                }
            case let .failure(failure):
                throw InspectorSessionError("DOM.requestNode could not be issued: \(failure)")
            }
        case let .protocolNode(targetID, nodeID):
            let result = selectProtocolNode(targetID: targetID, nodeID: nodeID)
            if case let .failure(failure) = result {
                guard case .unresolvedNode = failure else {
                    throw InspectorSessionError("DOM protocol-node selection failed: \(failure)")
                }
                try await reloadDocument(targetID: targetID)
                let retryResult = selectProtocolNode(targetID: targetID, nodeID: nodeID)
                if case let .failure(retryFailure) = retryResult {
                    throw InspectorSessionError("DOM protocol-node selection failed after reload: \(retryFailure)")
                }
            }
        }
    }

    private func inspectRoute(
        for event: DOMInspectEvent,
        activeTargetID: ProtocolTargetIdentifier
    ) -> DOMInspectRoute {
        switch event {
        case let .remoteObject(eventTargetID, remoteObject):
            return .remoteObject(
                targetID: inspectTargetID(for: remoteObject, eventTargetID: eventTargetID, activeTargetID: activeTargetID),
                objectID: remoteObject.objectID
            )
        case let .protocolNode(eventTargetID, nodeID):
            let targetID = eventTargetID.rawValue.isEmpty ? activeTargetID : eventTargetID
            return .protocolNode(targetID: targetID, nodeID: nodeID)
        }
    }

    private func inspectTargetID(
        for remoteObject: RemoteObject,
        eventTargetID: ProtocolTargetIdentifier?,
        activeTargetID: ProtocolTargetIdentifier
    ) -> ProtocolTargetIdentifier {
        if let executionContextID = remoteObject.injectedScriptID {
            let snapshot = snapshot()
            if let targetID = snapshot.executionContext(
                runtimeAgentTargetID: eventTargetID ?? activeTargetID,
                contextID: executionContextID
            )?.targetID {
                return targetID
            }
            if let targetID = snapshot.uniqueExecutionContext(contextID: executionContextID)?.targetID {
                return targetID
            }
        }
        return eventTargetID ?? activeTargetID
    }

    private func reloadDocument(
        targetID: ProtocolTargetIdentifier,
        force: Bool = false
    ) async throws {
        guard let handle = startDocumentRequest(targetID: targetID, force: force, reason: "explicit") else {
            return
        }
        try await handle.task?.value
        recordError?(nil)
    }

    @discardableResult
    private func startDocumentRequest(
        targetID: ProtocolTargetIdentifier,
        force: Bool = false,
        reason: String
    ) -> DOMSessionDocumentRequestHandle? {
        if force {
            cancelDocumentRequest(targetID: targetID, reason: "force-\(reason)")
        } else if let activeHandle = documentRequests.handlesByTargetID[targetID] {
            return activeHandle
        }
        guard let intent = getDocumentIntent(targetID: targetID) else {
            return nil
        }

        let targetKind = targetKind(for: targetID)
        let handle = DOMSessionDocumentRequestHandle(targetID: targetID, targetKind: targetKind)
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                if documentRequests.handlesByTargetID[targetID] === handle {
                    documentRequests.handlesByTargetID.removeValue(forKey: targetID)
                }
            }
            do {
                let result = try await send(intent)
                try Task.checkCancellation()
                guard documentRequests.handlesByTargetID[targetID] === handle else {
                    return
                }
                try applyGetDocumentResult(result)
                recordError?(nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if handle.targetKind == .frame, shouldIgnoreFrameTargetLifecycleError(error) {
                    return
                }
                InspectorRuntimeLog.error("getDocument.failed target=\(targetID.rawValue) reason=\(reason) error=\(error)")
                recordError?(InspectorSessionError(String(describing: error)))
                throw error
            }
        }
        handle.task = task
        documentRequests.handlesByTargetID[targetID] = handle
        return handle
    }

    private func refreshDocumentAfterBackendUpdate(_ event: ProtocolEventEnvelope) {
        guard let targetID = event.targetID ?? currentPageTargetID else {
            return
        }
        let activeRequest = documentRequests.handlesByTargetID[targetID]
        let targetKind = targetKind(for: targetID) ?? activeRequest?.targetKind
        let isCurrentPageTarget = currentPageTargetID == targetID
        let hasCurrentDocument = currentDocumentID(for: targetID) != nil
        let hasActiveFrameDocumentRequest = targetKind == .frame && activeRequest != nil
        guard hasCurrentDocument || isCurrentPageTarget || hasActiveFrameDocumentRequest else {
            return
        }

        invalidateDocument(targetID: targetID)
        if targetKind == .frame {
            startDocumentRequest(targetID: targetID, force: true, reason: "frameDocumentUpdated")
            return
        }

        cancelDocumentRequest(targetID: targetID, reason: "documentUpdated")
    }

    private func startPendingFrameOwnerHydration() {
        guard let intent = pendingFrameOwnerHydrationIntent(issuedSequence: currentAppliedDOMSequence) else {
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await perform(intent)
            } catch {
                InspectorRuntimeLog.warning("frameOwnerHydration.failed intent=\(intent) error=\(error)")
                clearOwnerHydrationTransaction(for: intent)
                recordError?(InspectorSessionError(String(describing: error)))
            }
        }
    }

    private func cancelDocumentRequest(targetID: ProtocolTargetIdentifier, reason _: String) {
        guard let handle = documentRequests.handlesByTargetID.removeValue(forKey: targetID) else {
            return
        }
        handle.task?.cancel()
    }

    private func cancelDocumentRequests() {
        for handle in documentRequests.handlesByTargetID.values {
            handle.task?.cancel()
        }
        documentRequests.handlesByTargetID.removeAll()
    }

    private func cancelCSSActionRequests() {
        cancelSelectedNodeStyleHydrationRefresh()

        for task in styleHydration.propertyUpdateTasks.values {
            task.cancel()
        }
        styleHydration.propertyUpdateTasks.removeAll()
    }

    private func clearOwnerHydrationTransaction(for intent: DOMCommandIntent) {
        guard case let .requestChildNodes(targetID, _, _) = intent else {
            return
        }
        clearOwnerHydrationTransactions(targetID: targetID)
    }

    private func shouldIgnoreFrameTargetLifecycleError(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError:
            return true
        case let error as TransportError:
            switch error {
            case .missingTarget, .replyTimeout:
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    private func applyGetDocumentResult(_ result: ProtocolCommandResult) throws {
        guard let targetID = result.targetID else {
            return
        }
        guard targetKind(for: targetID) != nil else {
            return
        }
        try protocolCommands.applyGetDocumentResult(result, to: self)
        elementStyles.removeStyles(targetID: targetID)
        startPendingFrameOwnerHydration()
        recordError?(nil)
    }

    private var currentAppliedDOMSequence: UInt64 {
        commandChannel?.currentAppliedSequence ?? 0
    }

    private func applyElementPickerTargetLifecycle(
        _ event: ProtocolEventEnvelope,
        targetCommit: TargetProtocolCommitResolution?
    ) {
        guard let activeTargetID = elementPicker.targetID else {
            return
        }

        switch event.method {
        case "Target.targetDestroyed":
            guard let params = try? TransportMessageParser.decode(
                TargetDestroyedEventParams.self,
                from: event.paramsData
            ),
                params.targetId == activeTargetID else {
                return
            }
            recordElementPickerFailure(reason: "targetDestroyedBeforeInspectEvent", targetID: activeTargetID)
            clearElementPickerState(invalidatePendingSelection: true)
        case "Target.didCommitProvisionalTarget":
            guard let targetCommit,
                  targetCommit.consumedOldTargetID == activeTargetID else {
                return
            }
            recordElementPickerFailure(
                reason: "targetCommitBeforeInspectEvent",
                targetID: activeTargetID,
                details: "newTarget=\(targetCommit.newTargetID.rawValue)"
            )
            clearElementPickerState(invalidatePendingSelection: true)
        default:
            return
        }
    }

    private func selectedStylesShouldRefresh(after event: ProtocolEventEnvelope) -> Bool {
        switch event.method {
        case "DOM.attributeModified",
             "DOM.attributeRemoved",
             "DOM.childNodeInserted",
             "DOM.childNodeRemoved",
             "DOM.childNodeCountUpdated":
            return true
        default:
            return false
        }
    }

    private func currentPageTargetForDOMAction() throws -> ProtocolTargetIdentifier {
        guard commandChannel != nil,
              let targetID = currentPageTargetID else {
            throw InspectorSessionError("Inspector session is not attached to a DOM page.")
        }
        return targetID
    }

    private func clearElementPickerState(invalidatePendingSelection: Bool = false) {
        elementPicker.generation &+= 1
        elementPicker.targetID = nil
        elementPicker.acceptsInspectEvents = false
        isSelectingElement = false
        if invalidatePendingSelection {
            selectNode(selectedNodeID)
        }
    }

    private func recordElementPickerFailure(
        reason: String,
        targetID: ProtocolTargetIdentifier? = nil,
        details: String = ""
    ) {
        let resolvedTargetID = targetID ?? elementPicker.targetID
        var message = "picker.failure reason=\(reason)"
        message += " target=\(resolvedTargetID?.rawValue ?? "nil")"
        message += " currentPage=\(currentPageTargetID?.rawValue ?? "nil")"
        message += " hasRoot=\(currentPageRootNode != nil)"
        message += " selecting=\(isSelectingElement)"
        if !details.isEmpty {
            message += " \(details)"
        }
        InspectorRuntimeLog.warning(message)
    }

    private func isElementPickerSession(generation: UInt64, targetID: ProtocolTargetIdentifier) -> Bool {
        isSelectingElement && elementPicker.generation == generation && elementPicker.targetID == targetID
    }

    private func isCurrentElementPicker(generation: UInt64, targetID: ProtocolTargetIdentifier) -> Bool {
        isElementPickerSession(generation: generation, targetID: targetID) && elementPicker.acceptsInspectEvents
    }

    private func completeElementPicker(generation: UInt64, targetID: ProtocolTargetIdentifier) async {
        guard isCurrentElementPicker(generation: generation, targetID: targetID) else {
            return
        }
        clearElementPickerState()
        guard let intent = setInspectModeEnabledIntent(targetID: targetID, enabled: false) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            recordError?(InspectorSessionError(String(describing: error)))
        }
    }

    private func requireCommandChannel(requiresActiveConnection: Bool = true) throws -> ProtocolCommandChannel {
        guard let commandChannel else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        if requiresActiveConnection {
            try commandChannel.requireAttached()
        }
        return commandChannel
    }

    private func performDeleteNode(_ nodeID: DOMNode.ID) async throws -> DOMSessionDeleteUndoState {
        guard commandChannel != nil else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        let commandTargetID = try currentPageTargetForDOMAction()
        guard let identity = actionIdentity(for: nodeID, commandTargetID: commandTargetID),
              let intent = removeNodeIntent(for: nodeID, commandTargetID: identity.commandTargetID) else {
            throw InspectorSessionError("DOM node is no longer available.")
        }
        let documentID = nodeID.documentID

        try await perform(intent)
        applyNodeRemoved(nodeID)
        selectNode(nil)
        elementStyles.removeStyles(targetID: documentID.targetID)
        recordError?(nil)

        return DOMSessionDeleteUndoState(
            documentTargetID: identity.documentTargetID,
            commandTargetID: identity.commandTargetID,
            documentID: documentID
        )
    }

    private func depthFromRoot(for nodeID: DOMNode.ID) -> Int {
        var depth = 0
        var currentNode = node(for: nodeID)
        while let parentID = currentNode?.parentID,
              let parent = node(for: parentID) {
            depth += 1
            currentNode = parent
        }
        return depth
    }

    private func registerUndoDelete(_ state: DOMSessionDeleteUndoState, undoManager: UndoManager) {
        rememberDeleteUndoManager(undoManager)
        trackDeleteUndoState(state)
        undoManager.registerUndo(withTarget: self) { target in
            target.registerRedoDelete(state, undoManager: undoManager)
            target.enqueueDeleteUndoOperation { [weak target] generation in
                await target?.performUndoDelete(state, undoManager: undoManager, generation: generation)
            }
        }
        undoManager.setActionName(state.actionName)
    }

    private func registerRedoDelete(_ state: DOMSessionDeleteUndoState, undoManager: UndoManager) {
        rememberDeleteUndoManager(undoManager)
        trackDeleteUndoState(state)
        undoManager.registerUndo(withTarget: self) { target in
            target.registerUndoDelete(state, undoManager: undoManager)
            target.enqueueDeleteUndoOperation { [weak target] generation in
                await target?.performRedoDelete(state, undoManager: undoManager, generation: generation)
            }
        }
        undoManager.setActionName(state.actionName)
    }

    private func registerUndoDeletes(
        _ states: [DOMSessionDeleteUndoState],
        undoManager: UndoManager?,
        actionName: String
    ) {
        guard let undoManager, !states.isEmpty else {
            return
        }
        for state in states {
            state.actionName = actionName
        }

        guard states.count > 1 else {
            registerUndoDelete(states[0], undoManager: undoManager)
            return
        }

        undoManager.beginUndoGrouping()
        defer {
            undoManager.setActionName(actionName)
            undoManager.endUndoGrouping()
        }
        for state in states {
            registerUndoDelete(state, undoManager: undoManager)
        }
    }

    private func enqueueDeleteUndoOperation(_ operation: @escaping @MainActor (UInt64) async -> Void) {
        deleteUndoController.operationQueue.enqueue(operation)
    }

    private func performUndoDelete(_ state: DOMSessionDeleteUndoState, undoManager: UndoManager, generation: UInt64) async {
        guard deleteUndoOperationIsCurrent(generation) else {
            return
        }
        guard deleteUndoStateIsCurrent(state, undoManager: undoManager, operation: "undo") else {
            return
        }
        do {
            try Task.checkCancellation()
            try await perform(.undo(targetID: state.commandTargetID))
            try Task.checkCancellation()
            guard deleteUndoOperationIsCurrent(generation) else {
                return
            }
            try await reloadDocument(targetID: state.documentTargetID)
            try Task.checkCancellation()
            guard deleteUndoOperationIsCurrent(generation) else {
                return
            }
            updateDeleteUndoDocumentID(state, undoManager: undoManager)
        } catch is CancellationError {
            handleDeleteUndoOperationError(CancellationError(), undoManager: undoManager, generation: generation)
        } catch {
            handleDeleteUndoOperationError(error, undoManager: undoManager, generation: generation)
        }
    }

    private func performRedoDelete(_ state: DOMSessionDeleteUndoState, undoManager: UndoManager, generation: UInt64) async {
        guard deleteUndoOperationIsCurrent(generation) else {
            return
        }
        guard deleteUndoStateIsCurrent(state, undoManager: undoManager, operation: "redo") else {
            return
        }
        do {
            try Task.checkCancellation()
            try await perform(.redo(targetID: state.commandTargetID))
            try Task.checkCancellation()
            guard deleteUndoOperationIsCurrent(generation) else {
                return
            }
            try await reloadDocument(targetID: state.documentTargetID)
            try Task.checkCancellation()
            guard deleteUndoOperationIsCurrent(generation) else {
                return
            }
            updateDeleteUndoDocumentID(state, undoManager: undoManager)
        } catch is CancellationError {
            handleDeleteUndoOperationError(CancellationError(), undoManager: undoManager, generation: generation)
        } catch {
            handleDeleteUndoOperationError(error, undoManager: undoManager, generation: generation)
        }
    }

    private func deleteUndoOperationIsCurrent(_ generation: UInt64) -> Bool {
        deleteUndoController.operationQueue.isCurrent(generation)
    }

    private func handleDeleteUndoOperationError(
        _ error: any Error,
        undoManager: UndoManager,
        generation: UInt64
    ) {
        guard deleteUndoOperationIsCurrent(generation) else {
            return
        }
        clearDeleteUndoHistory(using: undoManager)
        recordError?(InspectorSessionError(String(describing: error)))
    }

    private func deleteUndoStateIsCurrent(
        _ state: DOMSessionDeleteUndoState,
        undoManager: UndoManager,
        operation: String
    ) -> Bool {
        guard currentDocumentID(for: state.documentTargetID) == state.documentID else {
            clearDeleteUndoHistory(using: undoManager)
            recordError?(InspectorSessionError("DOM document changed before \(operation)."))
            return false
        }
        return true
    }

    private func updateDeleteUndoDocumentID(_ state: DOMSessionDeleteUndoState, undoManager: UndoManager) {
        guard let documentID = currentDocumentID(for: state.documentTargetID) else {
            clearDeleteUndoHistory(using: undoManager)
            recordError?(InspectorSessionError("DOM document is unavailable after delete undo operation."))
            return
        }
        var updatedTrackedState = false
        for trackedState in deleteUndoController.states where trackedState.documentTargetID == state.documentTargetID {
            trackedState.documentID = documentID
            updatedTrackedState = true
        }
        if updatedTrackedState == false {
            state.documentID = documentID
        }
    }

    private func rememberDeleteUndoManager(_ undoManager: UndoManager) {
        deleteUndoController.undoManager = undoManager
    }

    private func trackDeleteUndoState(_ state: DOMSessionDeleteUndoState) {
        guard deleteUndoController.states.contains(where: { $0 === state }) == false else {
            return
        }
        deleteUndoController.states.append(state)
    }

    private func clearDeleteUndoHistory(using undoManager: UndoManager? = nil) {
        let manager = undoManager ?? deleteUndoController.undoManager
        manager?.removeAllActions(withTarget: self)
        if let manager, manager === deleteUndoController.undoManager {
            deleteUndoController.undoManager = nil
        }
        deleteUndoController.states.removeAll()
        deleteUndoController.operationQueue.invalidate()
    }
}
