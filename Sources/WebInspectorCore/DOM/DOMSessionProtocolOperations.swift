import Foundation
import WebInspectorTransport

private enum DOMInspectRoute {
    case remoteObject(targetID: ProtocolTarget.ID, objectID: String)
    case protocolNode(targetID: ProtocolTarget.ID, nodeID: DOMNode.ProtocolID)
}

private struct TargetDestroyedEventParams: Decodable {
    var targetId: ProtocolTarget.ID
}

extension DOMSession {
    package func bindProtocolChannel(
        _ commandChannel: ProtocolCommandChannel,
        recordError: @escaping (InspectorSession.Error?) -> Void
    ) {
        self.commandChannel = commandChannel
        self.recordError = recordError
        elementStyles.bindProtocolChannel(commandChannel)
        recordCommandAvailabilityMutation()
        reconcileSelectedNodeStyleHydrationIfNeeded()
    }

    package func unbindProtocolChannel() {
        cancelSelectedNodeStyleHydrationRefresh()
        cancelDocumentRequests()
        cancelCSSActionRequests()
        commandChannel = nil
        recordError = nil
        elementStyles.unbindProtocolChannel()
        highlightController.targetID = nil
        clearElementPickerState(invalidatePendingSelection: true)
        clearDeleteUndoHistory()
        recordCommandAvailabilityMutation()
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

    package func waitUntilDocumentRequestsIdle(targetID: ProtocolTarget.ID? = nil) async {
        await documentRequests.waitUntilIdle(targetID: targetID)
    }

    package func waitUntilSelectedStyleRefreshIdle() async {
        await styleHydration.waitUntilIdle()
    }

    package func waitUntilElementPickerIdle() async {
        await elementPicker.waitUntilIdle()
    }

    package func waitUntilDeleteUndoOperationsIdle() async {
        await deleteUndoController.operationQueue.waitUntilIdle()
    }

    @discardableResult
    package func perform(_ intent: DOMCommand.Intent) async throws -> ProtocolCommand.Result {
        try await perform(intent, requiresActiveConnection: true)
    }

    @discardableResult
    package func performDuringBootstrap(_ intent: DOMCommand.Intent) async throws -> ProtocolCommand.Result {
        try await perform(intent, requiresActiveConnection: false)
    }

    @discardableResult
    private func perform(
        _ intent: DOMCommand.Intent,
        requiresActiveConnection: Bool
    ) async throws -> ProtocolCommand.Result {
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
                recordError?(InspectorSession.Error(String(describing: failure)))
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
        _ intent: DOMCommand.Intent,
        requiresActiveConnection: Bool = true
    ) async throws -> ProtocolCommand.Result {
        let commandChannel = try requireCommandChannel(requiresActiveConnection: requiresActiveConnection)
        let command = try protocolCommands.command(for: intent)
        return try await commandChannel.send(command)
    }

    @discardableResult
    package func requestChildNodes(for nodeID: DOMNode.ID, depth: Int = 3) async -> Bool {
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
            recordError?(InspectorSession.Error(String(describing: error)))
            return false
        }
    }

    package func highlightNode(for nodeID: DOMNode.ID) async {
        guard let intent = highlightNodeIntent(for: nodeID) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            recordError?(InspectorSession.Error(String(describing: error)))
        }
    }

    package func hideNodeHighlight() async {
        guard let intent = hideHighlightIntent(targetID: highlightController.targetID) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            recordError?(InspectorSession.Error(String(describing: error)))
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
            recordError?(InspectorSession.Error(String(describing: error)))
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
                throw InspectorSession.Error("DOM is not ready for element selection.")
            }
            targetID = try currentPageTargetForDOMAction()
        }
        guard canSelectElement else {
            recordElementPickerFailure(
                reason: "documentNotReady",
                targetID: targetID,
                details: "current=\(currentPageTargetID?.rawValue ?? "nil") root=\(currentPageRootNode != nil) connected=\(commandChannel != nil)"
            )
            throw InspectorSession.Error("DOM is not ready for element selection.")
        }
        if isSelectingElement {
            await cancelElementPicker()
        }

        let pickerSession = elementPicker.begin(targetID: targetID)
        syncElementPickerSelectionState()

        do {
            guard let intent = setInspectModeEnabledIntent(targetID: targetID, enabled: true) else {
                recordElementPickerFailure(reason: "inspectModeUnavailable", targetID: targetID)
                throw InspectorSession.Error("DOM inspect mode is not available.")
            }
            try await perform(intent)
            guard elementPicker.beginAcceptingInspectEvents(for: pickerSession) else {
                return
            }
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
            recordError?(InspectorSession.Error(String(describing: error)))
        }
    }

    package func copySelectedNodeText(_ kind: DOMNode.CopyTextKind) async throws -> String {
        guard commandChannel != nil else {
            throw InspectorSession.Error("Inspector session is not attached.")
        }
        guard let nodeID = selectedNodeID else {
            throw InspectorSession.Error("No DOM node is selected.")
        }
        return try await copyNodeText(kind, for: nodeID)
    }

    package func copyNodeText(_ kind: DOMNode.CopyTextKind, for nodeID: DOMNode.ID) async throws -> String {
        guard commandChannel != nil else {
            throw InspectorSession.Error("Inspector session is not attached.")
        }
        switch kind {
        case .html:
            let commandTargetID = try currentPageTargetForDOMAction()
            guard let intent = outerHTMLIntent(for: nodeID, commandTargetID: commandTargetID) else {
                throw InspectorSession.Error("DOM node is no longer available.")
            }
            let result = try await perform(intent)
            return try protocolCommands.outerHTML(from: result)
        case .selectorPath:
            guard let node = node(for: nodeID) else {
                throw InspectorSession.Error("DOM node is no longer available.")
            }
            return selectorPath(for: node)
        case .xPath:
            guard let node = node(for: nodeID) else {
                throw InspectorSession.Error("DOM node is no longer available.")
            }
            return xPath(for: node)
        }
    }

    package func deleteSelectedNode(undoManager: UndoManager?) async throws {
        guard commandChannel != nil else {
            throw InspectorSession.Error("Inspector session is not attached.")
        }
        guard let nodeID = selectedNodeID else {
            throw InspectorSession.Error("No DOM node is selected.")
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
                recordError?(InspectorSession.Error(String(describing: error)))
                return false
            }
        } catch {
            recordError?(InspectorSession.Error(String(describing: error)))
            return false
        }
    }

    package func refreshStylesForSelectedNode() async {
        do {
            try await refreshSelectedNodeStyles()
            recordError?(nil)
        } catch {
            recordError?(InspectorSession.Error(String(describing: error)))
        }
    }

    package func setSelectedNodeStyleHydrationActive(_ isActive: Bool) {
        guard styleHydration.setActive(isActive) else {
            return
        }
        if isActive, commandChannel != nil {
            reconcileSelectedNodeStyleHydrationIfNeeded()
        } else {
            cancelSelectedNodeStyleHydrationRefresh()
        }
    }

    @discardableResult
    package func requestSetCSSProperty(_ propertyID: CSSProperty.ID, enabled: Bool) -> Bool {
        guard commandChannel != nil,
              elementStyles.setStyleTextIntent(for: propertyID, enabled: enabled) != nil else {
            return false
        }

        return styleHydration.startPropertyUpdate(propertyID: propertyID) { [weak self] propertyID in
            guard let self else {
                return
            }
            guard Task.isCancelled == false else {
                return
            }

            do {
                try await setCSSProperty(propertyID, enabled: enabled)
            } catch {
                recordError?(InspectorSession.Error(String(describing: error)))
                try? await refreshSelectedNodeStyles()
            }
        }
    }

    package func setCSSProperty(_ propertyID: CSSProperty.ID, enabled: Bool) async throws {
        guard let intent = elementStyles.setStyleTextIntent(for: propertyID, enabled: enabled) else {
            throw InspectorSession.Error("CSS property is not editable.")
        }
        let result = try await elementStyles.perform(intent)
        guard case let .setStyleText(targetID, _, _) = intent else {
            throw InspectorSession.Error("Unexpected CSS command intent.")
        }
        let style = try elementStyles.setStyleTextResult(from: result)
        elementStyles.applySetStyleTextResult(style, propertyID: propertyID, targetID: targetID)
        try await refreshSelectedNodeStyles()
        recordError?(nil)
    }

    package func reconcileSelectedNodeStyleHydrationIfNeeded() {
        guard styleHydration.isActive else {
            return
        }
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

    private func reconcileSelectedNodeStyles(_ identity: CSSNodeStyles.Identity) {
        switch elementStyles.refreshState(forSelected: identity) {
        case nil, .needsRefresh:
            hydrateSelectedNodeStyles(identity)
        case .loading, .loaded, .failed(_), .unavailable(_):
            return
        }
    }

    private func hydrateSelectedNodeStyles(_ identity: CSSNodeStyles.Identity) {
        guard styleHydration.isRefreshing(identity: identity) == false else {
            return
        }
        guard let token = elementStyles.beginRefresh(identity: identity) else {
            return
        }

        if let cancelledToken = styleHydration.startRefresh(token: token, operation: { [weak self] token in
            guard let self else {
                return
            }
            guard Task.isCancelled == false else {
                return
            }

            do {
                try await self.refreshStyles(for: token)
                self.recordError?(nil)
            } catch is CancellationError {
                return
            } catch {
                self.recordError?(InspectorSession.Error(String(describing: error)))
            }
        }) {
            elementStyles.cancelRefresh(cancelledToken)
        }
    }

    private func cancelSelectedNodeStyleHydrationRefresh() {
        if let cancelledToken = styleHydration.cancelRefresh() {
            elementStyles.cancelRefresh(cancelledToken)
        }
    }

    private func refreshSelectedNodeStyles() async throws {
        switch selectedCSSNodeStyleIdentity() {
        case let .success(identity):
            try await refreshStyles(for: identity)
        case let .failure(reason):
            elementStyles.markSelectedNodeUnavailable(reason)
        }
    }

    private func refreshStyles(for identity: CSSNodeStyles.Identity) async throws {
        guard let token = elementStyles.beginRefresh(identity: identity) else {
            return
        }
        try await refreshStyles(for: token)
    }

    private func refreshStyles(for token: CSSStyle.RefreshToken) async throws {
        let identity = token.identity
        do {
            let commandChannel = try requireCommandChannel()
            let targetExists = await commandChannel.snapshot().targetsByID[identity.targetID] != nil
            guard targetExists else {
                elementStyles.markSelectedNodeStylesUnavailable(identity: identity, reason: .staleNode(identity.nodeID))
                return
            }

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
            elementStyles.cancelRefresh(token)
            throw CancellationError()
        } catch {
            elementStyles.markRefreshFailed(token, message: String(describing: error))
            throw error
        }
    }

    package func inspectEvent(from event: ProtocolEvent) throws -> DOMInspectEvent? {
        try protocolCommands.inspectEvent(from: event)
    }

    package func applyTargetProtocolEvent(_ event: ProtocolEvent) throws -> TargetProtocolEventResult {
        let result = try TargetProtocolEventDispatcher().dispatch(event, to: self)
        let destroyedTargetID = result.destroyedTargetID
        let targetCommit = result.targetCommit
        if let destroyedTargetID {
            cancelDocumentRequest(targetID: destroyedTargetID, reason: "targetDestroyed")
            removeElementStyles(targetID: destroyedTargetID)
        }
        if let oldTargetID = targetCommit?.consumedOldTargetID {
            cancelDocumentRequest(targetID: oldTargetID, reason: "targetCommit")
            removeElementStyles(targetID: oldTargetID)
        }
        applyElementPickerTargetLifecycle(event, targetCommit: targetCommit)
        return result
    }

    package func handleDOMProtocolEvent(_ event: ProtocolEvent) async throws {
        if let inspectEvent = try protocolCommands.inspectEvent(from: event) {
            await handleInspectEvent(inspectEvent)
            return
        }
        if event.method == "DOM.documentUpdated" {
            if let targetID = event.targetID ?? currentPageTargetID {
                elementStyles.removeStyles(targetID: targetID)
            }
            refreshDocumentAfterBackendUpdate(event)
            syncSelectedElementStyles()
            return
        }
        let selectedStyleIdentity = try? selectedCSSNodeStyleIdentity().get()
        try protocolCommands.applyDOMEvent(event, to: self)
        if let selectedStyleIdentity,
           let targetID = event.targetID,
           selectedStyleIdentity.targetID == targetID {
            if selectedNodeID != selectedStyleIdentity.nodeID {
                removeElementStyles(targetID: targetID)
            } else if selectedStylesShouldRefresh(after: event) {
                elementStyles.markNeedsRefresh(targetID: targetID, nodeID: selectedStyleIdentity.protocolNodeID)
                reconcileSelectedNodeStyleHydrationIfNeeded()
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

    package func startFrameTargetDocumentRequestIfNeeded(targetID: ProtocolTarget.ID, reason: String) {
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
        targetID: ProtocolTarget.ID,
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
                recordError?(InspectorSession.Error(String(describing: error)))
            }
        }
    }

    package func handleInspectProtocolEvent(_ event: DOMInspectEvent) async {
        await handleInspectEvent(event)
    }

    private func handleInspectEvent(_ event: DOMInspectEvent) async {
        guard isSelectingElement,
              let pickerSession = elementPicker.currentAcceptingSession() else {
            recordElementPickerFailure(
                reason: "inspectEventWithoutActivePicker",
                details: "activeTarget=\(elementPicker.targetID?.rawValue ?? "nil")"
            )
            return
        }
        guard elementPicker.beginCompletion(for: pickerSession) else {
            return
        }
        defer {
            elementPicker.finishCompletion(for: pickerSession)
        }
        let activeTargetID = pickerSession.targetID
        do {
            try await resolvePickerSelection(event, activeTargetID: activeTargetID)
        } catch {
            guard elementPicker.isCurrentAcceptingSession(pickerSession) else {
                return
            }
            recordElementPickerFailure(
                reason: "selectionResolveFailed",
                targetID: activeTargetID,
                details: "error=\(error)"
            )
            recordError?(InspectorSession.Error(String(describing: error)))
        }

        await completeElementPicker(pickerSession)
    }

    private func resolvePickerSelection(
        _ event: DOMInspectEvent,
        activeTargetID: ProtocolTarget.ID
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
                    throw InspectorSession.Error("DOM.requestNode failed: \(failure)")
                }
            case let .failure(failure):
                throw InspectorSession.Error("DOM.requestNode could not be issued: \(failure)")
            }
        case let .protocolNode(targetID, nodeID):
            let result = selectProtocolNode(targetID: targetID, nodeID: nodeID)
            if case let .failure(failure) = result {
                guard case .unresolvedNode = failure else {
                    throw InspectorSession.Error("DOM protocol-node selection failed: \(failure)")
                }
                try await reloadDocument(targetID: targetID)
                let retryResult = selectProtocolNode(targetID: targetID, nodeID: nodeID)
                if case let .failure(retryFailure) = retryResult {
                    throw InspectorSession.Error("DOM protocol-node selection failed after reload: \(retryFailure)")
                }
            }
        }
    }

    private func inspectRoute(
        for event: DOMInspectEvent,
        activeTargetID: ProtocolTarget.ID
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
        for remoteObject: DOMInspectEvent.RemoteObject,
        eventTargetID: ProtocolTarget.ID?,
        activeTargetID: ProtocolTarget.ID
    ) -> ProtocolTarget.ID {
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
        targetID: ProtocolTarget.ID,
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
        targetID: ProtocolTarget.ID,
        force: Bool = false,
        reason: String
    ) -> DOMSessionDocumentRequestHandle? {
        if force {
            cancelDocumentRequest(targetID: targetID, reason: "force-\(reason)")
        } else if let activeHandle = documentRequests.activeHandle(for: targetID) {
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
                documentRequests.finish(handle)
            }
            do {
                let result = try await send(intent)
                try Task.checkCancellation()
                guard documentRequests.isActive(handle) else {
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
                recordError?(InspectorSession.Error(String(describing: error)))
                throw error
            }
        }
        handle.task = task
        documentRequests.register(handle)
        return handle
    }

    private func refreshDocumentAfterBackendUpdate(_ event: ProtocolEvent) {
        guard let targetID = event.targetID ?? currentPageTargetID else {
            return
        }
        let activeRequest = documentRequests.activeHandle(for: targetID)
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
                recordError?(InspectorSession.Error(String(describing: error)))
            }
        }
    }

    private func cancelDocumentRequest(targetID: ProtocolTarget.ID, reason _: String) {
        documentRequests.cancel(targetID: targetID)
    }

    private func cancelDocumentRequests() {
        documentRequests.cancelAll()
    }

    private func cancelCSSActionRequests() {
        cancelSelectedNodeStyleHydrationRefresh()
        styleHydration.cancelPropertyUpdates()
    }

    private func clearOwnerHydrationTransaction(for intent: DOMCommand.Intent) {
        guard case let .requestChildNodes(targetID, _, _) = intent else {
            return
        }
        clearOwnerHydrationTransactions(targetID: targetID)
    }

    private func shouldIgnoreFrameTargetLifecycleError(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError:
            return true
        case let error as TransportSession.Error:
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

    private func applyGetDocumentResult(_ result: ProtocolCommand.Result) throws {
        guard let targetID = result.targetID else {
            return
        }
        guard targetKind(for: targetID) != nil else {
            return
        }
        try protocolCommands.applyGetDocumentResult(result, to: self)
        removeElementStyles(targetID: targetID)
        startPendingFrameOwnerHydration()
        recordError?(nil)
    }

    private func removeElementStyles(targetID: ProtocolTarget.ID) {
        elementStyles.removeStyles(targetID: targetID)
        syncSelectedElementStyles()
    }

    private var currentAppliedDOMSequence: UInt64 {
        commandChannel?.currentAppliedSequence ?? 0
    }

    private func applyElementPickerTargetLifecycle(
        _ event: ProtocolEvent,
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

    private func selectedStylesShouldRefresh(after event: ProtocolEvent) -> Bool {
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

    private func currentPageTargetForDOMAction() throws -> ProtocolTarget.ID {
        guard commandChannel != nil,
              let targetID = currentPageTargetID else {
            throw InspectorSession.Error("Inspector session is not attached to a DOM page.")
        }
        return targetID
    }

    private func clearElementPickerState(invalidatePendingSelection: Bool = false) {
        elementPicker.clear()
        syncElementPickerSelectionState()
        if invalidatePendingSelection {
            selectNode(selectedNodeID)
        }
    }

    private func syncElementPickerSelectionState() {
        isSelectingElement = elementPicker.isSelecting
    }

    private func recordElementPickerFailure(
        reason: String,
        targetID: ProtocolTarget.ID? = nil,
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

    private func completeElementPicker(_ session: DOMSessionElementPickerController.Session) async {
        guard elementPicker.isCurrentAcceptingSession(session) else {
            return
        }
        let targetID = session.targetID
        clearElementPickerState()
        guard let intent = setInspectModeEnabledIntent(targetID: targetID, enabled: false) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            recordError?(InspectorSession.Error(String(describing: error)))
        }
    }

    private func requireCommandChannel(requiresActiveConnection: Bool = true) throws -> ProtocolCommandChannel {
        guard let commandChannel else {
            throw InspectorSession.Error("Inspector session is not attached.")
        }
        if requiresActiveConnection {
            try commandChannel.requireAttached()
        }
        return commandChannel
    }

    private func performDeleteNode(_ nodeID: DOMNode.ID) async throws -> DOMSessionDeleteUndoState {
        guard commandChannel != nil else {
            throw InspectorSession.Error("Inspector session is not attached.")
        }
        let commandTargetID = try currentPageTargetForDOMAction()
        guard let identity = actionIdentity(for: nodeID, commandTargetID: commandTargetID),
              let intent = removeNodeIntent(for: nodeID, commandTargetID: identity.commandTargetID) else {
            throw InspectorSession.Error("DOM node is no longer available.")
        }
        let documentID = nodeID.documentID

        try await perform(intent)
        applyNodeRemoved(nodeID)
        selectNode(nil)
        removeElementStyles(targetID: documentID.targetID)
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
        deleteUndoController.remember(undoManager)
        deleteUndoController.track(state)
        undoManager.registerUndo(withTarget: self) { target in
            target.registerRedoDelete(state, undoManager: undoManager)
            target.enqueueDeleteUndoOperation { [weak target] generation in
                await target?.performUndoDelete(state, undoManager: undoManager, generation: generation)
            }
        }
        undoManager.setActionName(state.actionName)
    }

    private func registerRedoDelete(_ state: DOMSessionDeleteUndoState, undoManager: UndoManager) {
        deleteUndoController.remember(undoManager)
        deleteUndoController.track(state)
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
        recordError?(InspectorSession.Error(String(describing: error)))
    }

    private func deleteUndoStateIsCurrent(
        _ state: DOMSessionDeleteUndoState,
        undoManager: UndoManager,
        operation: String
    ) -> Bool {
        deleteUndoController.stateIsCurrent(
            state,
            currentDocumentID: currentDocumentID(for: state.documentTargetID),
            undoManager: undoManager,
            undoTarget: self,
            operation: operation,
            recordError: { [weak self] error in self?.recordError?(error) }
        )
    }

    private func updateDeleteUndoDocumentID(_ state: DOMSessionDeleteUndoState, undoManager: UndoManager) {
        deleteUndoController.updateDocumentID(
            for: state,
            currentDocumentID: currentDocumentID(for: state.documentTargetID),
            undoManager: undoManager,
            undoTarget: self,
            recordError: { [weak self] error in self?.recordError?(error) }
        )
    }

    private func clearDeleteUndoHistory(using undoManager: UndoManager? = nil) {
        deleteUndoController.clear(using: undoManager, undoTarget: self)
    }
}
