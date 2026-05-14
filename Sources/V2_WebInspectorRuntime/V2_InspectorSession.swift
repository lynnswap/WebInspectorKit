import Foundation
import Observation
import Synchronization
import WebKit
import V2_WebInspectorCore
import V2_WebInspectorTransport

package struct V2_InspectorSessionError: Error, Equatable, Sendable, CustomStringConvertible {
    package var message: String

    package init(_ message: String) {
        self.message = message
    }

    package var description: String {
        message
    }
}

package struct V2_InspectorSessionConfiguration: Equatable, Sendable {
    package var responseTimeout: Duration
    package var bootstrapTimeout: Duration
    package var eventApplicationTimeout: Duration

    package init(
        responseTimeout: Duration = .seconds(5),
        bootstrapTimeout: Duration = .seconds(5),
        eventApplicationTimeout: Duration = .milliseconds(250)
    ) {
        self.responseTimeout = responseTimeout
        self.bootstrapTimeout = bootstrapTimeout
        self.eventApplicationTimeout = eventApplicationTimeout
    }
}

@MainActor
private final class DOMDeleteUndoState {
    let documentTargetID: ProtocolTargetIdentifier
    let commandTargetID: ProtocolTargetIdentifier
    var documentID: DOMDocumentIdentifier

    init(
        documentTargetID: ProtocolTargetIdentifier,
        commandTargetID: ProtocolTargetIdentifier,
        documentID: DOMDocumentIdentifier
    ) {
        self.documentTargetID = documentTargetID
        self.commandTargetID = commandTargetID
        self.documentID = documentID
    }
}

@MainActor
private final class V2_InspectorConnection {
    let transport: TransportSession
    weak var webView: WKWebView?
    let originalInspectability: Bool?
    var pumps: [ProtocolDomain: V2_DomainEventPump]
    var bootstrappedTargetIDs: Set<ProtocolTargetIdentifier>

    init(
        transport: TransportSession,
        webView: WKWebView? = nil,
        originalInspectability: Bool? = nil
    ) {
        self.transport = transport
        self.webView = webView
        self.originalInspectability = originalInspectability
        pumps = [:]
        bootstrappedTargetIDs = []
    }
}

private enum DOMInspectRoute {
    case remoteObject(targetID: ProtocolTargetIdentifier, objectID: String)
    case protocolNode(targetID: ProtocolTargetIdentifier, nodeID: DOMProtocolNodeID)
}

@MainActor
@Observable
package final class V2_InspectorSession {
    package let dom: DOMSession
    package let network: NetworkSession
    package private(set) var isAttached: Bool
    package private(set) var lastError: V2_InspectorSessionError?
    package private(set) var isSelectingElement: Bool

    @ObservationIgnored private let configuration: V2_InspectorSessionConfiguration
    @ObservationIgnored private var connection: V2_InspectorConnection?
    @ObservationIgnored private var pendingConnection: V2_InspectorConnection?
    @ObservationIgnored private var highlightedDOMTargetID: ProtocolTargetIdentifier?
    @ObservationIgnored private var elementPickerTargetID: ProtocolTargetIdentifier?
    @ObservationIgnored private var elementPickerGeneration: UInt64
    @ObservationIgnored private var acceptsElementPickerEvents: Bool
    @ObservationIgnored private weak var deleteUndoManager: UndoManager?
    @ObservationIgnored private var deleteUndoStates: [DOMDeleteUndoState]

    package init(
        configuration: V2_InspectorSessionConfiguration = .init(),
        dom: DOMSession = DOMSession(),
        network: NetworkSession = NetworkSession()
    ) {
        self.configuration = configuration
        self.dom = dom
        self.network = network
        isAttached = false
        lastError = nil
        isSelectingElement = false
        connection = nil
        pendingConnection = nil
        highlightedDOMTargetID = nil
        elementPickerTargetID = nil
        elementPickerGeneration = 0
        acceptsElementPickerEvents = false
        deleteUndoManager = nil
        deleteUndoStates = []
    }

    package func attach(to webView: WKWebView) async throws {
        await detach()
        let receiver = TransportReceiver()
        let originalInspectability = Self.prepareInspectability(for: webView)
        var transport: TransportSession?

        do {
            let backend = try NativeInspectorBackendFactory.make(
                webView: webView,
                messageHandler: { message in
                    receiver.receive(message)
                },
                fatalFailureHandler: { [weak self] message in
                    Task { @MainActor in
                        self?.lastError = V2_InspectorSessionError(message)
                    }
                }
            )
            let createdTransport = TransportSession(
                backend: backend,
                responseTimeout: configuration.responseTimeout
            )
            transport = createdTransport
            receiver.setTransport(createdTransport)

            try backend.attach()
            try await connect(
                transport: createdTransport,
                webView: webView,
                originalInspectability: originalInspectability
            )
        } catch {
            Self.restoreInspectabilityIfNeeded(on: webView, originalValue: originalInspectability)
            await transport?.detach()
            throw error
        }
    }

    package func connect(transport: TransportSession) async throws {
        try await connect(transport: transport, webView: nil, originalInspectability: nil)
    }

    private func connect(
        transport: TransportSession,
        webView: WKWebView?,
        originalInspectability: Bool?
    ) async throws {
        await detach()
        let nextConnection = V2_InspectorConnection(
            transport: transport,
            webView: webView,
            originalInspectability: originalInspectability
        )
        pendingConnection = nextConnection
        lastError = nil
        await startPumps(connection: nextConnection)
        seedDOMSession(from: await transport.snapshot())

        do {
            let mainTarget = try await transport.waitForCurrentMainPageTarget(
                timeout: configuration.bootstrapTimeout
            )
            seedDOMSession(from: await transport.snapshot())
            try await bootstrap(mainTargetID: mainTarget.targetID, connection: nextConnection)
            try ensureCurrentConnection(nextConnection)
            pendingConnection = nil
            connection = nextConnection
            isAttached = true
            lastError = nil
        } catch {
            guard connection === nextConnection || pendingConnection === nextConnection else {
                throw error
            }
            stopPumps(nextConnection)
            if pendingConnection === nextConnection {
                pendingConnection = nil
            }
            if connection === nextConnection {
                connection = nil
                isAttached = false
            }
            await transport.detach()
            restoreInspectabilityIfNeeded(for: nextConnection)
            dom.reset()
            network.reset()
            let sessionError = V2_InspectorSessionError(String(describing: error))
            lastError = sessionError
            throw error
        }
    }

    package func detach() async {
        guard connection != nil || pendingConnection != nil else {
            return
        }

        let previousConnection = connection
        let previousPendingConnection = pendingConnection
        connection = nil
        pendingConnection = nil
        isAttached = false

        if let previousConnection {
            stopPumps(previousConnection)
            await previousConnection.transport.detach()
            restoreInspectabilityIfNeeded(for: previousConnection)
        }
        if let previousPendingConnection {
            stopPumps(previousPendingConnection)
            await previousPendingConnection.transport.detach()
            restoreInspectabilityIfNeeded(for: previousPendingConnection)
        }
        dom.reset()
        network.reset()
        highlightedDOMTargetID = nil
        clearElementPickerState(invalidatePendingSelection: true)
        clearDeleteUndoHistory()
        lastError = nil
    }

    package var hasInspectablePageWebView: Bool {
        connection?.webView != nil
    }

    package var canReloadDOMDocument: Bool {
        isAttached && dom.currentPageTargetID != nil
    }

    package var canSelectElement: Bool {
        isAttached && dom.currentPageRootNode != nil
    }

    package var canCopySelectedDOMNodeText: Bool {
        isAttached && dom.selectedNodeID != nil
    }

    package var canDeleteSelectedDOMNode: Bool {
        isAttached && dom.selectedNodeID != nil
    }

    package func toggleElementPicker() async {
        if isSelectingElement {
            await cancelElementPicker()
            return
        }
        do {
            try await beginElementPicker()
        } catch {
            lastError = V2_InspectorSessionError(String(describing: error))
        }
    }

    package func beginElementPicker() async throws {
        let targetID = try currentPageTargetForDOMAction()
        guard canSelectElement else {
            throw V2_InspectorSessionError("DOM is not ready for element selection.")
        }
        if isSelectingElement {
            await cancelElementPicker()
        }

        elementPickerGeneration &+= 1
        let generation = elementPickerGeneration
        elementPickerTargetID = targetID
        acceptsElementPickerEvents = false
        isSelectingElement = true

        do {
            guard let intent = dom.setInspectModeEnabledIntent(targetID: targetID, enabled: true) else {
                throw V2_InspectorSessionError("DOM inspect mode is not available.")
            }
            try await perform(intent)
            guard isCurrentElementPickerGeneration(generation) else {
                return
            }
            acceptsElementPickerEvents = true
            lastError = nil
        } catch {
            if isCurrentElementPickerGeneration(generation) {
                clearElementPickerState(invalidatePendingSelection: true)
            }
            throw error
        }
    }

    package func cancelElementPicker() async {
        let targetID = elementPickerTargetID ?? dom.currentPageTargetID
        clearElementPickerState(invalidatePendingSelection: true)
        guard let targetID,
              let intent = dom.setInspectModeEnabledIntent(targetID: targetID, enabled: false) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            lastError = V2_InspectorSessionError(String(describing: error))
        }
    }

    package func copySelectedDOMNodeText(_ kind: DOMNodeCopyTextKind) async throws -> String {
        guard isAttached else {
            throw V2_InspectorSessionError("Inspector session is not attached.")
        }
        guard let nodeID = dom.selectedNodeID else {
            throw V2_InspectorSessionError("No DOM node is selected.")
        }

        switch kind {
        case .html:
            let commandTargetID = try currentPageTargetForDOMAction()
            guard let intent = dom.outerHTMLIntent(for: nodeID, commandTargetID: commandTargetID) else {
                throw V2_InspectorSessionError("Selected DOM node is no longer available.")
            }
            let result = try await perform(intent)
            return try DOMTransportAdapter.outerHTML(from: result)
        case .selectorPath, .xPath:
            return dom.selectedNodeCopyText(kind) ?? ""
        }
    }

    package func deleteSelectedDOMNode(undoManager: UndoManager?) async throws {
        guard isAttached else {
            throw V2_InspectorSessionError("Inspector session is not attached.")
        }
        guard let nodeID = dom.selectedNodeID else {
            throw V2_InspectorSessionError("No DOM node is selected.")
        }
        let commandTargetID = try currentPageTargetForDOMAction()
        guard let identity = dom.actionIdentity(for: nodeID, commandTargetID: commandTargetID),
              let intent = dom.removeNodeIntent(for: nodeID, commandTargetID: identity.commandTargetID) else {
            throw V2_InspectorSessionError("Selected DOM node is no longer available.")
        }
        let documentID = nodeID.documentID

        try await perform(intent)
        dom.applyNodeRemoved(nodeID)
        lastError = nil

        if let undoManager {
            registerUndoDelete(
                DOMDeleteUndoState(
                    documentTargetID: identity.documentTargetID,
                    commandTargetID: identity.commandTargetID,
                    documentID: documentID
                ),
                undoManager: undoManager
            )
        }
    }

    package func reloadDOMDocument() async throws {
        if isSelectingElement {
            await cancelElementPicker()
        }
        clearDeleteUndoHistory()
        try await reloadDOMDocument(targetID: currentPageTargetForDOMAction())
    }

    package func reloadPage() async throws {
        let webView = try requireInspectableWebView()
        await cancelElementPicker()
        clearDeleteUndoHistory()
        dom.reset()
        network.reset()
        if let connection {
            seedDOMSession(from: await connection.transport.snapshot())
        }
        webView.reload()
    }

    @discardableResult
    package func perform(_ intent: DOMCommandIntent) async throws -> ProtocolCommandResult {
        let connection = try activeConnection()
        let transport = connection.transport
        let command = try DOMTransportAdapter.command(for: intent)
        let result = try await transport.send(command)
        try ensureCurrentConnection(connection)

        switch intent {
        case .getDocument:
            try DOMTransportAdapter.applyGetDocumentResult(result, to: dom)
        case let .requestNode(selectionRequestID, targetID, _):
            let domSequence = result.receivedSequence(for: .dom)
            if requestNodeResultMayNeedDOMPathPush(result, targetID: targetID, domSequence: domSequence) {
                await waitForAppliedSequence(domSequence, domain: .dom, connection: connection)
                try ensureCurrentConnection(connection)
            }
            let selectionResult = try DOMTransportAdapter.applyRequestNodeResult(
                result,
                selectionRequestID: selectionRequestID,
                to: dom
            )
            if case let .failure(failure) = selectionResult {
                lastError = V2_InspectorSessionError(String(describing: failure))
            }
        case .requestChildNodes:
            break
        case let .highlightNode(identity):
            highlightedDOMTargetID = identity.commandTargetID
        case let .hideHighlight(targetID):
            if highlightedDOMTargetID == targetID {
                highlightedDOMTargetID = nil
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
    package func requestChildNodes(for nodeID: DOMNodeIdentifier, depth: Int = 3) async -> Bool {
        guard let intent = dom.requestChildNodesIntent(for: nodeID, depth: depth) else {
            return false
        }
        do {
            try await perform(intent)
            return true
        } catch {
            lastError = V2_InspectorSessionError(String(describing: error))
            return false
        }
    }

    package func highlightNode(for nodeID: DOMNodeIdentifier) async {
        guard let intent = dom.highlightNodeIntent(for: nodeID) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            lastError = V2_InspectorSessionError(String(describing: error))
        }
    }

    package func hideNodeHighlight() async {
        guard let intent = dom.hideHighlightIntent(targetID: highlightedDOMTargetID) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            lastError = V2_InspectorSessionError(String(describing: error))
        }
    }

    @discardableResult
    package func perform(_ intent: NetworkCommandIntent) async throws -> ProtocolCommandResult {
        let connection = try activeConnection()
        let transport = connection.transport
        let result = try await transport.send(NetworkTransportAdapter.command(for: intent))
        try ensureCurrentConnection(connection)
        return result
    }

    package func fetchResponseBody(for id: NetworkRequest.ID) async {
        guard let request = network.request(for: id) else {
            return
        }
        guard request.responseBody?.needsFetch == true else {
            return
        }
        guard let intent = network.responseBodyCommandIntent(for: id) else {
            request.markResponseBodyFailed(.unavailable)
            return
        }

        request.markResponseBodyFetching()
        do {
            let result = try await perform(intent)
            try NetworkTransportAdapter.applyResponseBodyResult(result, to: request)
        } catch {
            request.markResponseBodyFailed(.unknown(String(describing: error)))
            lastError = V2_InspectorSessionError(String(describing: error))
        }
    }

    private func bootstrap(mainTargetID: ProtocolTargetIdentifier, connection: V2_InspectorConnection) async throws {
        _ = try await sendTargetCommand(domain: .inspector, method: "Inspector.enable", targetID: mainTargetID, connection: connection)
        try ensureCurrentConnection(connection)
        _ = try await sendTargetCommand(domain: .inspector, method: "Inspector.initialized", targetID: mainTargetID, connection: connection)
        try ensureCurrentConnection(connection)
        _ = try await sendTargetCommand(domain: .dom, method: "DOM.enable", targetID: mainTargetID, connection: connection)
        try ensureCurrentConnection(connection)
        _ = try await sendTargetCommand(domain: .runtime, method: "Runtime.enable", targetID: mainTargetID, connection: connection)
        try ensureCurrentConnection(connection)

        let documentResult = try await sendTargetCommand(domain: .dom, method: "DOM.getDocument", targetID: mainTargetID, connection: connection)
        try ensureCurrentConnection(connection)
        try DOMTransportAdapter.applyGetDocumentResult(documentResult, to: dom)

        _ = try await connection.transport.send(
            ProtocolCommand(
                domain: .network,
                method: "Network.enable",
                routing: .octopus(pageTarget: mainTargetID)
            )
        )
        try ensureCurrentConnection(connection)
        connection.bootstrappedTargetIDs.insert(mainTargetID)
    }

    private func sendTargetCommand(
        domain: ProtocolDomain,
        method: String,
        targetID: ProtocolTargetIdentifier,
        connection: V2_InspectorConnection
    ) async throws -> ProtocolCommandResult {
        try await connection.transport.send(
            ProtocolCommand(
                domain: domain,
                method: method,
                routing: .target(targetID)
            )
        )
    }

    private func startPumps(connection: V2_InspectorConnection) async {
        stopPumps(connection)
        let transport = connection.transport
        let targetPump = V2_DomainEventPump()
        targetPump.start(stream: await transport.events(for: .target)) { [weak self] event in
            await self?.handleTargetEvent(event)
        }

        let runtimePump = V2_DomainEventPump()
        runtimePump.start(stream: await transport.events(for: .runtime)) { [weak self] event in
            self?.applyEvent(event) {
                try DOMTransportAdapter.applyRuntimeEvent(event, to: $0.dom)
            }
        }

        let inspectorPump = V2_DomainEventPump()
        inspectorPump.start(stream: await transport.events(for: .inspector)) { [weak self] event in
            await self?.handleInspectorEvent(event)
        }

        let domPump = V2_DomainEventPump()
        domPump.start(stream: await transport.events(for: .dom)) { [weak self] event in
            await self?.handleDOMEvent(event)
        }

        let networkPump = V2_DomainEventPump()
        networkPump.start(stream: await transport.events(for: .network)) { [weak self] event in
            self?.applyEvent(event) {
                try NetworkTransportAdapter.applyNetworkEvent(event, to: $0.network)
            }
        }

        connection.pumps = [
            .target: targetPump,
            .runtime: runtimePump,
            .inspector: inspectorPump,
            .dom: domPump,
            .network: networkPump,
        ]
    }

    private func handleInspectorEvent(_ event: ProtocolEventEnvelope) async {
        do {
            guard let inspectEvent = try DOMTransportAdapter.inspectEvent(from: event) else {
                return
            }
            await handleInspectEvent(inspectEvent)
        } catch {
            lastError = V2_InspectorSessionError("\(event.method): \(error)")
        }
    }

    private func handleTargetEvent(_ event: ProtocolEventEnvelope) async {
        do {
            try DOMTransportAdapter.applyTargetEvent(event, to: dom)
            if event.method == "Target.didCommitProvisionalTarget",
               dom.currentPageRootNode == nil,
               let targetID = dom.currentPageTargetID,
               let connection {
                if connection.bootstrappedTargetIDs.contains(targetID) {
                    try await reloadDOMDocument(targetID: targetID)
                } else {
                    try await bootstrap(mainTargetID: targetID, connection: connection)
                }
            }
        } catch {
            lastError = V2_InspectorSessionError("\(event.method): \(error)")
        }
    }

    private func handleDOMEvent(_ event: ProtocolEventEnvelope) async {
        do {
            if let inspectEvent = try DOMTransportAdapter.inspectEvent(from: event) {
                await handleInspectEvent(inspectEvent)
                return
            }
            if event.method == "DOM.documentUpdated" {
                try await refreshDOMDocumentAfterBackendUpdate(event)
                return
            }
            try DOMTransportAdapter.applyDOMEvent(event, to: dom)
        } catch {
            lastError = V2_InspectorSessionError("\(event.method): \(error)")
        }
    }

    private func handleInspectEvent(_ event: DOMInspectEvent) async {
        guard acceptsElementPickerEvents,
              let activeTargetID = elementPickerTargetID else {
            return
        }
        let generation = elementPickerGeneration
        acceptsElementPickerEvents = false

        do {
            try await resolvePickerSelection(event, activeTargetID: activeTargetID)
        } catch {
            lastError = V2_InspectorSessionError(String(describing: error))
        }

        await completeElementPicker(generation: generation)
    }

    private func resolvePickerSelection(
        _ event: DOMInspectEvent,
        activeTargetID: ProtocolTargetIdentifier
    ) async throws {
        switch inspectRoute(for: event, activeTargetID: activeTargetID) {
        case let .remoteObject(targetID, objectID):
            if dom.currentDocumentID(for: targetID) == nil {
                try await reloadDOMDocument(targetID: targetID)
            }
            let intentResult = dom.beginInspectSelectionRequest(targetID: targetID, objectID: objectID)
            switch intentResult {
            case let .success(intent):
                try await perform(intent)
            case let .failure(failure):
                lastError = V2_InspectorSessionError(String(describing: failure))
            }
        case let .protocolNode(targetID, nodeID):
            let result = dom.selectProtocolNode(targetID: targetID, nodeID: nodeID)
            if case let .failure(failure) = result {
                guard case .unresolvedNode = failure else {
                    lastError = V2_InspectorSessionError(String(describing: failure))
                    return
                }
                try await reloadDOMDocument(targetID: targetID)
                let retryResult = dom.selectProtocolNode(targetID: targetID, nodeID: nodeID)
                if case let .failure(retryFailure) = retryResult {
                    lastError = V2_InspectorSessionError(String(describing: retryFailure))
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
        if let executionContextID = remoteObject.injectedScriptID,
           let targetID = dom.snapshot().executionContextsByID[executionContextID]?.targetID {
            return targetID
        }
        return eventTargetID ?? activeTargetID
    }

    private func stopPumps(_ connection: V2_InspectorConnection) {
        for pump in connection.pumps.values {
            pump.stop()
        }
        connection.pumps.removeAll()
    }

    private func applyEvent(
        _ event: ProtocolEventEnvelope,
        apply: @MainActor (V2_InspectorSession) throws -> Void
    ) {
        do {
            try apply(self)
        } catch {
            lastError = V2_InspectorSessionError("\(event.method): \(error)")
        }
    }

    private func currentPageTargetForDOMAction() throws -> ProtocolTargetIdentifier {
        guard isAttached,
              let targetID = dom.currentPageTargetID else {
            throw V2_InspectorSessionError("Inspector session is not attached to a DOM page.")
        }
        return targetID
    }

    private func requireInspectableWebView() throws -> WKWebView {
        guard let webView = connection?.webView else {
            throw V2_InspectorSessionError("Inspector session is not attached to a WKWebView.")
        }
        return webView
    }

    private func clearElementPickerState(invalidatePendingSelection: Bool = false) {
        elementPickerTargetID = nil
        acceptsElementPickerEvents = false
        isSelectingElement = false
        if invalidatePendingSelection {
            dom.selectNode(dom.selectedNodeID)
        }
        elementPickerGeneration &+= 1
    }

    private func isCurrentElementPickerGeneration(_ generation: UInt64) -> Bool {
        generation == elementPickerGeneration && isSelectingElement
    }

    private func completeElementPicker(generation: UInt64) async {
        guard isCurrentElementPickerGeneration(generation) else {
            return
        }
        let targetID = elementPickerTargetID ?? dom.currentPageTargetID
        clearElementPickerState()
        guard let targetID,
              let intent = dom.setInspectModeEnabledIntent(targetID: targetID, enabled: false) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            lastError = V2_InspectorSessionError(String(describing: error))
        }
    }

    private func reloadDOMDocument(targetID: ProtocolTargetIdentifier) async throws {
        try await perform(.getDocument(targetID: targetID))
        lastError = nil
    }

    private func refreshDOMDocumentAfterBackendUpdate(_ event: ProtocolEventEnvelope) async throws {
        let targetID = event.targetID ?? dom.currentPageTargetID
        guard let targetID,
              dom.currentDocumentID(for: targetID) != nil || dom.currentPageTargetID == targetID else {
            return
        }
        try await reloadDOMDocument(targetID: targetID)
    }

    private func registerUndoDelete(_ state: DOMDeleteUndoState, undoManager: UndoManager) {
        rememberDeleteUndoManager(undoManager)
        trackDeleteUndoState(state)
        undoManager.registerUndo(withTarget: self) { target in
            guard target.deleteUndoStateIsCurrent(state, undoManager: undoManager, operation: "undo") else {
                return
            }
            target.registerRedoDelete(state, undoManager: undoManager)
            Task { @MainActor in
                await target.performUndoDelete(state, undoManager: undoManager)
            }
        }
        undoManager.setActionName("Delete Node")
    }

    private func registerRedoDelete(_ state: DOMDeleteUndoState, undoManager: UndoManager) {
        rememberDeleteUndoManager(undoManager)
        trackDeleteUndoState(state)
        undoManager.registerUndo(withTarget: self) { target in
            guard target.deleteUndoStateIsCurrent(state, undoManager: undoManager, operation: "redo") else {
                return
            }
            target.registerUndoDelete(state, undoManager: undoManager)
            Task { @MainActor in
                await target.performRedoDelete(state, undoManager: undoManager)
            }
        }
        undoManager.setActionName("Delete Node")
    }

    private func performUndoDelete(_ state: DOMDeleteUndoState, undoManager: UndoManager) async {
        guard deleteUndoStateIsCurrent(state, undoManager: undoManager, operation: "undo") else {
            return
        }
        do {
            try await perform(.undo(targetID: state.commandTargetID))
            try await reloadDOMDocument(targetID: state.documentTargetID)
            updateDeleteUndoDocumentID(state, undoManager: undoManager)
        } catch {
            clearDeleteUndoHistory(using: undoManager)
            lastError = V2_InspectorSessionError(String(describing: error))
        }
    }

    private func performRedoDelete(_ state: DOMDeleteUndoState, undoManager: UndoManager) async {
        guard deleteUndoStateIsCurrent(state, undoManager: undoManager, operation: "redo") else {
            return
        }
        do {
            try await perform(.redo(targetID: state.commandTargetID))
            try await reloadDOMDocument(targetID: state.documentTargetID)
            updateDeleteUndoDocumentID(state, undoManager: undoManager)
        } catch {
            clearDeleteUndoHistory(using: undoManager)
            lastError = V2_InspectorSessionError(String(describing: error))
        }
    }

    private func deleteUndoStateIsCurrent(
        _ state: DOMDeleteUndoState,
        undoManager: UndoManager,
        operation: String
    ) -> Bool {
        guard dom.currentDocumentID(for: state.documentTargetID) == state.documentID else {
            clearDeleteUndoHistory(using: undoManager)
            lastError = V2_InspectorSessionError("DOM document changed before \(operation).")
            return false
        }
        return true
    }

    private func updateDeleteUndoDocumentID(_ state: DOMDeleteUndoState, undoManager: UndoManager) {
        guard let documentID = dom.currentDocumentID(for: state.documentTargetID) else {
            clearDeleteUndoHistory(using: undoManager)
            lastError = V2_InspectorSessionError("DOM document is unavailable after delete undo operation.")
            return
        }
        var updatedTrackedState = false
        for trackedState in deleteUndoStates where trackedState.documentTargetID == state.documentTargetID {
            trackedState.documentID = documentID
            updatedTrackedState = true
        }
        if updatedTrackedState == false {
            state.documentID = documentID
        }
    }

    private func rememberDeleteUndoManager(_ undoManager: UndoManager) {
        deleteUndoManager = undoManager
    }

    private func trackDeleteUndoState(_ state: DOMDeleteUndoState) {
        guard deleteUndoStates.contains(where: { $0 === state }) == false else {
            return
        }
        deleteUndoStates.append(state)
    }

    private func clearDeleteUndoHistory(using undoManager: UndoManager? = nil) {
        let manager = undoManager ?? deleteUndoManager
        manager?.removeAllActions(withTarget: self)
        if let manager, manager === deleteUndoManager {
            deleteUndoManager = nil
        }
        deleteUndoStates.removeAll()
    }

    private func seedDOMSession(from snapshot: TransportSnapshot) {
        for record in snapshot.targetsByID.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            dom.applyTargetCreated(
                record,
                makeCurrentMainPage: record.id == snapshot.currentMainPageTargetID
                    && record.kind == .page
                    && record.parentFrameID == nil
            )
        }
        for record in snapshot.executionContextsByID.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            dom.applyExecutionContextCreated(record)
        }
    }

    private func waitForAppliedSequence(
        _ sequence: UInt64,
        domain: ProtocolDomain,
        connection: V2_InspectorConnection
    ) async {
        await connection.pumps[domain]?.waitUntilApplied(
            sequence,
            timeout: configuration.eventApplicationTimeout
        )
    }

    private func activeConnection() throws -> V2_InspectorConnection {
        guard isAttached,
              let connection else {
            throw V2_InspectorSessionError("Inspector session is not attached.")
        }
        return connection
    }

    private func ensureCurrentConnection(_ candidate: V2_InspectorConnection) throws {
        guard connection === candidate || pendingConnection === candidate else {
            throw TransportError.transportClosed
        }
    }

    private func requestNodeResultMayNeedDOMPathPush(
        _ result: ProtocolCommandResult,
        targetID: ProtocolTargetIdentifier,
        domSequence: UInt64
    ) -> Bool {
        guard domSequence > 0,
              let payload = try? TransportMessageParser.decode(RequestNodeResultPayload.self, from: result.resultData) else {
            return false
        }
        let key = DOMNodeCurrentKey(targetID: targetID, nodeID: payload.nodeId)
        return dom.snapshot().currentNodeIDByKey[key] == nil
    }

    package static func prepareInspectability(for webView: WKWebView) -> Bool? {
        guard #available(iOS 16.4, macOS 13.3, *) else {
            return nil
        }

        let originalValue = webView.isInspectable
        webView.isInspectable = true
        return originalValue
    }

    package static func restoreInspectabilityIfNeeded(on webView: WKWebView, originalValue: Bool?) {
        guard #available(iOS 16.4, macOS 13.3, *),
              let originalValue else {
            return
        }
        webView.isInspectable = originalValue
    }

    private func restoreInspectabilityIfNeeded(for connection: V2_InspectorConnection) {
        guard let webView = connection.webView else {
            return
        }
        Self.restoreInspectabilityIfNeeded(on: webView, originalValue: connection.originalInspectability)
    }
}

private final class TransportReceiver: @unchecked Sendable {
    private struct State: Sendable {
        var transport: TransportSession?
        var messages: [String] = []
        var isDraining = false
    }

    private let state = Mutex(State())

    func setTransport(_ transport: TransportSession) {
        state.withLock {
            $0.transport = transport
        }
    }

    func receive(_ message: String) {
        let shouldStartDraining = state.withLock {
            $0.messages.append(message)
            guard !$0.isDraining else {
                return false
            }
            $0.isDraining = true
            return true
        }

        guard shouldStartDraining else {
            return
        }
        Task {
            await drain()
        }
    }

    private func drain() async {
        while let next = nextMessage() {
            await next.transport?.receiveRootMessage(next.message)
        }
    }

    private func nextMessage() -> (transport: TransportSession?, message: String)? {
        state.withLock {
            guard !$0.messages.isEmpty else {
                $0.isDraining = false
                return nil
            }
            return ($0.transport, $0.messages.removeFirst())
        }
    }
}

private struct RequestNodeResultPayload: Decodable {
    var nodeId: DOMProtocolNodeID
}
