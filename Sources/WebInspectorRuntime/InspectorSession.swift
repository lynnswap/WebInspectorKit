import Foundation
import Observation
import Synchronization
import WebKit
import WebInspectorCore
import WebInspectorTransport

#if DEBUG
private func inspectorRuntimeTrace(_ message: @autoclosure () -> String) {}

private func inspectorRuntimeFailureTrace(_ message: @autoclosure () -> String) {
    print("[WebInspectorRuntime.Failure] \(message())")
}

private func inspectorRuntimeDOMTrace(_ message: @autoclosure () -> String) {
    print("[WebInspectorRuntime.DOM] \(message())")
}

private func inspectorRuntimeVerboseTrace(_ message: @autoclosure () -> String) {}
#else
private func inspectorRuntimeTrace(_ message: @autoclosure () -> String) {}
private func inspectorRuntimeFailureTrace(_ message: @autoclosure () -> String) {}
private func inspectorRuntimeDOMTrace(_ message: @autoclosure () -> String) {}
private func inspectorRuntimeVerboseTrace(_ message: @autoclosure () -> String) {}
#endif

package struct InspectorSessionError: Error, Equatable, Sendable, CustomStringConvertible {
    package var message: String

    package init(_ message: String) {
        self.message = message
    }

    package var description: String {
        message
    }
}

package struct InspectorSessionConfiguration: Equatable, Sendable {
    package var responseTimeout: Duration
    package var bootstrapTimeout: Duration

    package init(
        responseTimeout: Duration = .seconds(5),
        bootstrapTimeout: Duration = .seconds(5)
    ) {
        self.responseTimeout = responseTimeout
        self.bootstrapTimeout = bootstrapTimeout
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
private final class InspectorConnection {
    let transport: TransportSession
    weak var webView: WKWebView?
    let originalInspectability: Bool?
    var eventPump: DomainEventPump?
    var bootstrappedTargetIDs: Set<ProtocolTargetIdentifier>

    init(
        transport: TransportSession,
        webView: WKWebView? = nil,
        originalInspectability: Bool? = nil
    ) {
        self.transport = transport
        self.webView = webView
        self.originalInspectability = originalInspectability
        eventPump = nil
        bootstrappedTargetIDs = []
    }
}

@MainActor
private final class DOMDocumentRequestHandle {
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

private struct TargetCommittedEventParams: Decodable {
    var oldTargetId: ProtocolTargetIdentifier?
    var newTargetId: ProtocolTargetIdentifier
}

private struct DOMGetDocumentTracePayload: Decodable {
    var root: DOMNodeTracePayload
}

private struct DOMNodeTracePayload: Decodable {
    var nodeId: Int?
    var nodeName: String?
    var documentURL: String?
    var baseURL: String?
    var childNodeCount: Int?
    var children: [DOMNodeTracePayload]?

    var summary: String {
        let name = nodeName ?? "?"
        let id = nodeId.map(String.init) ?? "?"
        let url = documentURL.map { " url=\(shortTraceValue($0))" } ?? ""
        let base = baseURL.map { " base=\(shortTraceValue($0))" } ?? ""
        let count = childNodeCount.map { " count=\($0)" } ?? ""
        let childSummary = (children ?? [])
            .prefix(4)
            .map(\.shallowSummary)
            .joined(separator: ",")
        if childSummary.isEmpty {
            return "\(name)#\(id)\(url)\(base)\(count)"
        }
        return "\(name)#\(id)\(url)\(base)\(count)[\(childSummary)]"
    }

    private var shallowSummary: String {
        let name = nodeName ?? "?"
        let id = nodeId.map(String.init) ?? "?"
        let count = childNodeCount.map { " count=\($0)" } ?? ""
        let childSummary = (children ?? [])
            .prefix(4)
            .map { child in
                let childName = child.nodeName ?? "?"
                let childID = child.nodeId.map(String.init) ?? "?"
                let childCount = child.childNodeCount.map { " count=\($0)" } ?? ""
                return "\(childName)#\(childID)\(childCount)"
            }
            .joined(separator: ",")
        if childSummary.isEmpty {
            return "\(name)#\(id)\(count)"
        }
        return "\(name)#\(id)\(count)[\(childSummary)]"
    }
}

private func shortTraceValue(_ value: String, limit: Int = 160) -> String {
    guard value.count > limit else {
        return value
    }
    return "\(value.prefix(limit))..."
}

@MainActor
@Observable
package final class InspectorSession {
    package let dom: DOMSession
    package let network: NetworkSession
    package private(set) var isAttached: Bool
    package private(set) var lastError: InspectorSessionError?
    package private(set) var isSelectingElement: Bool

    @ObservationIgnored private let configuration: InspectorSessionConfiguration
    @ObservationIgnored private var connection: InspectorConnection?
    @ObservationIgnored private var pendingConnection: InspectorConnection?
    @ObservationIgnored private var highlightedDOMTargetID: ProtocolTargetIdentifier?
    @ObservationIgnored private var elementPickerTargetID: ProtocolTargetIdentifier?
    @ObservationIgnored private weak var deleteUndoManager: UndoManager?
    @ObservationIgnored private var deleteUndoStates: [DOMDeleteUndoState]
    @ObservationIgnored private var domDocumentRequestHandlesByTargetID: [ProtocolTargetIdentifier: DOMDocumentRequestHandle]

    package init(
        configuration: InspectorSessionConfiguration = .init(),
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
        deleteUndoManager = nil
        deleteUndoStates = []
        domDocumentRequestHandlesByTargetID = [:]
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
                        self?.lastError = InspectorSessionError(message)
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
        let nextConnection = InspectorConnection(
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
            let sessionError = InspectorSessionError(String(describing: error))
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
        cancelDOMDocumentRequests()
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
            lastError = InspectorSessionError(String(describing: error))
        }
    }

    package func beginElementPicker() async throws {
        var targetID = try currentPageTargetForDOMAction()
        if dom.currentPageRootNode == nil {
            let loaded = await ensureDOMDocumentLoaded()
            guard loaded else {
                recordElementPickerFailure(
                    reason: "documentNotReady",
                    targetID: targetID,
                    details: "current=\(dom.currentPageTargetID?.rawValue ?? "nil") root=false"
                )
                throw InspectorSessionError("DOM is not ready for element selection.")
            }
            targetID = try currentPageTargetForDOMAction()
        }
        guard canSelectElement else {
            recordElementPickerFailure(
                reason: "documentNotReady",
                targetID: targetID,
                details: "current=\(dom.currentPageTargetID?.rawValue ?? "nil") root=\(dom.currentPageRootNode != nil) attached=\(isAttached)"
            )
            throw InspectorSessionError("DOM is not ready for element selection.")
        }
        if isSelectingElement {
            await cancelElementPicker()
        }

        elementPickerTargetID = targetID
        isSelectingElement = true

        do {
            guard let intent = dom.setInspectModeEnabledIntent(targetID: targetID, enabled: true) else {
                recordElementPickerFailure(reason: "inspectModeUnavailable", targetID: targetID)
                throw InspectorSessionError("DOM inspect mode is not available.")
            }
            try await perform(intent)
            lastError = nil
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
        let targetID = elementPickerTargetID ?? dom.currentPageTargetID
        if isSelectingElement {
            inspectorRuntimeTrace("picker.cancel target=\(targetID?.rawValue ?? "nil")")
        }
        clearElementPickerState(invalidatePendingSelection: true)
        guard let targetID,
              let intent = dom.setInspectModeEnabledIntent(targetID: targetID, enabled: false) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            lastError = InspectorSessionError(String(describing: error))
        }
    }

    package func copySelectedDOMNodeText(_ kind: DOMNodeCopyTextKind) async throws -> String {
        guard isAttached else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        guard let nodeID = dom.selectedNodeID else {
            throw InspectorSessionError("No DOM node is selected.")
        }

        switch kind {
        case .html:
            let commandTargetID = try currentPageTargetForDOMAction()
            guard let intent = dom.outerHTMLIntent(for: nodeID, commandTargetID: commandTargetID) else {
                throw InspectorSessionError("Selected DOM node is no longer available.")
            }
            let result = try await perform(intent)
            return try DOMTransportAdapter.outerHTML(from: result)
        case .selectorPath, .xPath:
            return dom.selectedNodeCopyText(kind) ?? ""
        }
    }

    package func deleteSelectedDOMNode(undoManager: UndoManager?) async throws {
        guard isAttached else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        guard let nodeID = dom.selectedNodeID else {
            throw InspectorSessionError("No DOM node is selected.")
        }
        let commandTargetID = try currentPageTargetForDOMAction()
        guard let identity = dom.actionIdentity(for: nodeID, commandTargetID: commandTargetID),
              let intent = dom.removeNodeIntent(for: nodeID, commandTargetID: identity.commandTargetID) else {
            throw InspectorSessionError("Selected DOM node is no longer available.")
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
        try await reloadDOMDocument(targetID: currentPageTargetForDOMAction(), force: true)
    }

    @discardableResult
    package func ensureDOMDocumentLoaded() async -> Bool {
        guard isAttached,
              let targetID = dom.currentPageTargetID else {
            return false
        }
        guard dom.currentPageRootNode == nil else {
            return true
        }

        do {
            inspectorRuntimeTrace("documentEnsure.request target=\(targetID.rawValue)")
            try await reloadDOMDocument(targetID: targetID)
            return dom.currentPageRootNode != nil
        } catch is CancellationError {
            guard isAttached,
                  dom.currentPageRootNode == nil else {
                return dom.currentPageRootNode != nil
            }
            do {
                inspectorRuntimeTrace("documentEnsure.retry target=\(targetID.rawValue)")
                try await reloadDOMDocument(targetID: targetID)
                return dom.currentPageRootNode != nil
            } catch {
                lastError = InspectorSessionError(String(describing: error))
                return false
            }
        } catch {
            lastError = InspectorSessionError(String(describing: error))
            return false
        }
    }

    package func reloadPage() async throws {
        let webView = try requireInspectableWebView()
        await cancelElementPicker()
        clearDeleteUndoHistory()
        dom.reset()
        network.reset()
        cancelDOMDocumentRequests()
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
        traceCommandSend(command)
        let result: ProtocolCommandResult
        do {
            result = try await transport.send(command)
        } catch {
            inspectorRuntimeFailureTrace("command.error method=\(command.method) routing=\(command.routing) error=\(error)")
            throw error
        }
        traceCommandReply(command, result: result)
        try ensureCurrentConnection(connection)

        switch intent {
        case .getDocument:
            try applyGetDocumentResult(result)
        case let .requestNode(selectionRequestID, targetID, _):
            let selectionResult = try DOMTransportAdapter.applyRequestNodeResult(
                result,
                selectionRequestID: selectionRequestID,
                to: dom
            )
            switch selectionResult {
            case let .resolved(nodeID):
                inspectorRuntimeVerboseTrace("requestNode.select success target=\(targetID.rawValue) node=\(nodeID.nodeID.rawValue) document=\(nodeID.documentID)")
            case let .pending(key):
                inspectorRuntimeTrace("requestNode.select pending target=\(targetID.rawValue) node=\(key.nodeID.rawValue) reason=awaiting-setChildNodes")
            case let .failed(failure):
                inspectorRuntimeFailureTrace("requestNode.selectFailure target=\(targetID.rawValue) failure=\(failure)")
                lastError = InspectorSessionError(String(describing: failure))
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
        guard let intent = dom.requestChildNodesIntent(
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
            lastError = InspectorSessionError(String(describing: error))
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
            lastError = InspectorSessionError(String(describing: error))
        }
    }

    package func hideNodeHighlight() async {
        guard let intent = dom.hideHighlightIntent(targetID: highlightedDOMTargetID) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            lastError = InspectorSessionError(String(describing: error))
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
            lastError = InspectorSessionError(String(describing: error))
        }
    }

    private func bootstrap(mainTargetID: ProtocolTargetIdentifier, connection: InspectorConnection) async throws {
        inspectorRuntimeDOMTrace("bootstrap.start target=\(mainTargetID.rawValue)")
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
        try applyGetDocumentResult(documentResult)

        _ = try await connection.transport.send(
            ProtocolCommand(
                domain: .network,
                method: "Network.enable",
                routing: .octopus(pageTarget: mainTargetID)
            )
        )
        try ensureCurrentConnection(connection)
        connection.bootstrappedTargetIDs.insert(mainTargetID)
        inspectorRuntimeDOMTrace("bootstrap.done target=\(mainTargetID.rawValue)")
    }

    private func sendTargetCommand(
        domain: ProtocolDomain,
        method: String,
        targetID: ProtocolTargetIdentifier,
        connection: InspectorConnection
    ) async throws -> ProtocolCommandResult {
        try await connection.transport.send(
            ProtocolCommand(
                domain: domain,
                method: method,
                routing: .target(targetID)
            )
        )
    }

    private func startPumps(connection: InspectorConnection) async {
        stopPumps(connection)
        let transport = connection.transport
        let eventPump = DomainEventPump()
        eventPump.start(stream: await transport.orderedEvents()) { [weak self] event in
            await self?.handleProtocolEvent(event)
        }
        connection.eventPump = eventPump
    }

    private func handleProtocolEvent(_ event: ProtocolEventEnvelope) async {
        traceEvent(event, phase: "begin")
        defer {
            traceEvent(event, phase: "end")
        }
        switch event.domain {
        case .target:
            await handleTargetEvent(event)
        case .runtime:
            applyEvent(event) {
                try DOMTransportAdapter.applyRuntimeEvent(event, to: $0.dom)
            }
        case .inspector:
            await handleInspectorEvent(event)
        case .dom:
            await handleDOMEvent(event)
        case .network:
            applyEvent(event) {
                try NetworkTransportAdapter.applyNetworkEvent(event, to: $0.network)
            }
        default:
            break
        }
    }

    private func handleInspectorEvent(_ event: ProtocolEventEnvelope) async {
        do {
            guard let inspectEvent = try DOMTransportAdapter.inspectEvent(from: event) else {
                return
            }
            inspectorRuntimeVerboseTrace("inspect.event seq=\(event.sequence) target=\(event.targetID?.rawValue ?? "nil") activePicker=\(elementPickerTargetID?.rawValue ?? "nil") selecting=\(isSelectingElement)")
            await handleInspectEvent(inspectEvent)
        } catch {
            lastError = InspectorSessionError("\(event.method): \(error)")
        }
    }

    private func handleTargetEvent(_ event: ProtocolEventEnvelope) async {
        do {
            let destroyedTargetID = targetDestroyedID(from: event)
            let createdTarget = try DOMTransportAdapter.applyTargetEvent(event, to: dom)
            if let destroyedTargetID {
                cancelDOMDocumentRequest(targetID: destroyedTargetID, reason: "targetDestroyed")
            }
            applyElementPickerTargetLifecycle(event)
            if isAttached,
               let createdTarget,
               createdTarget.kind == .frame {
                if createdTarget.capabilities.contains(.dom) {
                    inspectorRuntimeDOMTrace(
                        "frameTarget.created action=getDocument target=\(createdTarget.id.rawValue) frame=\(createdTarget.frameID?.rawValue ?? "nil") parentFrame=\(createdTarget.parentFrameID?.rawValue ?? "nil") caps=\(createdTarget.capabilities.rawValue)"
                    )
                    startDOMDocumentRequest(targetID: createdTarget.id, reason: "frameTargetCreated")
                } else {
                    inspectorRuntimeTrace(
                        "frameTarget.created action=skipNoDOM target=\(createdTarget.id.rawValue) frame=\(createdTarget.frameID?.rawValue ?? "nil") parentFrame=\(createdTarget.parentFrameID?.rawValue ?? "nil") caps=\(createdTarget.capabilities.rawValue)"
                    )
                }
            }
            if event.method == "Target.didCommitProvisionalTarget",
               dom.currentPageRootNode == nil,
               let targetID = dom.currentPageTargetID,
               let connection {
                startPageTargetDocumentRequestAfterCommit(targetID: targetID, connection: connection)
            }
        } catch {
            lastError = InspectorSessionError("\(event.method): \(error)")
        }
    }

    private func handleDOMEvent(_ event: ProtocolEventEnvelope) async {
        do {
            if let inspectEvent = try DOMTransportAdapter.inspectEvent(from: event) {
                await handleInspectEvent(inspectEvent)
                return
            }
            if event.method == "DOM.documentUpdated" {
                refreshDOMDocumentAfterBackendUpdate(event)
                return
            }
            try DOMTransportAdapter.applyDOMEvent(event, to: dom)
            if event.method == "DOM.setChildNodes" {
                startPendingFrameOwnerHydration()
            }
        } catch {
            lastError = InspectorSessionError("\(event.method): \(error)")
        }
    }

    private func startPendingFrameOwnerHydration() {
        guard let intent = dom.pendingFrameOwnerHydrationIntent(issuedSequence: currentAppliedDOMSequence) else {
            return
        }
        inspectorRuntimeDOMTrace("frameOwnerHydration.perform intent=\(intent)")
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await perform(intent)
            } catch {
                inspectorRuntimeFailureTrace("frameOwnerHydration.failed intent=\(intent) error=\(error)")
                lastError = InspectorSessionError(String(describing: error))
            }
        }
    }

    private func handleInspectEvent(_ event: DOMInspectEvent) async {
        guard isSelectingElement,
              let activeTargetID = elementPickerTargetID else {
            recordElementPickerFailure(
                reason: "inspectEventWithoutActivePicker",
                details: "activeTarget=\(elementPickerTargetID?.rawValue ?? "nil")"
            )
            return
        }
        do {
            try await resolvePickerSelection(event, activeTargetID: activeTargetID)
        } catch {
            recordElementPickerFailure(
                reason: "selectionResolveFailed",
                targetID: activeTargetID,
                details: "error=\(error)"
            )
            lastError = InspectorSessionError(String(describing: error))
        }

        await completeElementPicker()
    }

    private func resolvePickerSelection(
        _ event: DOMInspectEvent,
        activeTargetID: ProtocolTargetIdentifier
    ) async throws {
        switch inspectRoute(for: event, activeTargetID: activeTargetID) {
        case let .remoteObject(targetID, objectID):
            inspectorRuntimeVerboseTrace("inspect.route remoteObject target=\(targetID.rawValue) object=\(objectID) hasDocument=\(dom.currentDocumentID(for: targetID) != nil)")
            if dom.currentDocumentID(for: targetID) == nil {
                try await reloadDOMDocument(targetID: targetID)
            }
            let intentResult = dom.beginInspectSelectionRequest(
                targetID: targetID,
                objectID: objectID,
                issuedSequence: currentAppliedDOMSequence
            )
            switch intentResult {
            case let .success(intent):
                try await perform(intent)
                if let failure = dom.snapshot().selection.failure {
                    throw InspectorSessionError("DOM.requestNode failed: \(failure)")
                }
            case let .failure(failure):
                throw InspectorSessionError("DOM.requestNode could not be issued: \(failure)")
            }
        case let .protocolNode(targetID, nodeID):
            inspectorRuntimeVerboseTrace("inspect.route protocolNode target=\(targetID.rawValue) node=\(nodeID.rawValue)")
            let result = dom.selectProtocolNode(targetID: targetID, nodeID: nodeID)
            if case let .failure(failure) = result {
                guard case .unresolvedNode = failure else {
                    throw InspectorSessionError("DOM protocol-node selection failed: \(failure)")
                }
                try await reloadDOMDocument(targetID: targetID)
                let retryResult = dom.selectProtocolNode(targetID: targetID, nodeID: nodeID)
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
        if let executionContextID = remoteObject.injectedScriptID,
           let targetID = dom.snapshot().executionContextsByID[executionContextID]?.targetID {
            return targetID
        }
        if let executionContextID = remoteObject.injectedScriptID {
            inspectorRuntimeTrace(
                "inspect.routeFallback reason=unknownExecutionContext injectedScriptID=\(executionContextID.rawValue) eventTarget=\(eventTargetID?.rawValue ?? "nil") activeTarget=\(activeTargetID.rawValue)"
            )
        }
        return eventTargetID ?? activeTargetID
    }

    private func stopPumps(_ connection: InspectorConnection) {
        connection.eventPump?.stop()
        connection.eventPump = nil
    }

    private func applyEvent(
        _ event: ProtocolEventEnvelope,
        apply: @MainActor (InspectorSession) throws -> Void
    ) {
        do {
            try apply(self)
        } catch {
            lastError = InspectorSessionError("\(event.method): \(error)")
        }
    }

    private func currentPageTargetForDOMAction() throws -> ProtocolTargetIdentifier {
        guard isAttached,
              let targetID = dom.currentPageTargetID else {
            throw InspectorSessionError("Inspector session is not attached to a DOM page.")
        }
        return targetID
    }

    private func requireInspectableWebView() throws -> WKWebView {
        guard let webView = connection?.webView else {
            throw InspectorSessionError("Inspector session is not attached to a WKWebView.")
        }
        return webView
    }

    private func clearElementPickerState(invalidatePendingSelection: Bool = false) {
        elementPickerTargetID = nil
        isSelectingElement = false
        if invalidatePendingSelection {
            dom.selectNode(dom.selectedNodeID)
        }
    }

    private func recordElementPickerFailure(
        reason: String,
        targetID: ProtocolTargetIdentifier? = nil,
        details: String = ""
    ) {
        let resolvedTargetID = targetID ?? elementPickerTargetID
        var message = "picker.failure reason=\(reason)"
        message += " target=\(resolvedTargetID?.rawValue ?? "nil")"
        message += " currentPage=\(dom.currentPageTargetID?.rawValue ?? "nil")"
        message += " hasRoot=\(dom.currentPageRootNode != nil)"
        message += " selecting=\(isSelectingElement)"
        if !details.isEmpty {
            message += " \(details)"
        }
        inspectorRuntimeFailureTrace(message)
    }

    private func completeElementPicker() async {
        let targetID = elementPickerTargetID ?? dom.currentPageTargetID
        clearElementPickerState()
        guard let targetID,
              let intent = dom.setInspectModeEnabledIntent(targetID: targetID, enabled: false) else {
            return
        }
        do {
            try await perform(intent)
        } catch {
            lastError = InspectorSessionError(String(describing: error))
        }
    }

    private func reloadDOMDocument(
        targetID: ProtocolTargetIdentifier,
        force: Bool = false
    ) async throws {
        guard let handle = startDOMDocumentRequest(targetID: targetID, force: force, reason: "explicit") else {
            return
        }
        try await handle.task?.value
        lastError = nil
    }

    @discardableResult
    private func startDOMDocumentRequest(
        targetID: ProtocolTargetIdentifier,
        force: Bool = false,
        reason: String
    ) -> DOMDocumentRequestHandle? {
        if force {
            cancelDOMDocumentRequest(targetID: targetID, reason: "force-\(reason)")
        } else if let activeHandle = domDocumentRequestHandlesByTargetID[targetID] {
            inspectorRuntimeTrace("documentRequest.pending target=\(targetID.rawValue) reason=active-request caller=\(reason)")
            return activeHandle
        }
        guard let intent = dom.getDocumentIntent(targetID: targetID) else {
            inspectorRuntimeDOMTrace(
                "getDocument.skip target=\(targetID.rawValue) reason=noDOMCapability kind=\(String(describing: dom.targetKind(for: targetID)))"
            )
            return nil
        }

        let targetKind = dom.targetKind(for: targetID)
        let handle = DOMDocumentRequestHandle(targetID: targetID, targetKind: targetKind)
        inspectorRuntimeDOMTrace(
            "getDocument.start target=\(targetID.rawValue) kind=\(String(describing: targetKind)) reason=\(reason)"
        )
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                if domDocumentRequestHandlesByTargetID[targetID] === handle {
                    domDocumentRequestHandlesByTargetID.removeValue(forKey: targetID)
                }
            }
            do {
                let connection = try activeConnection()
                let command = try DOMTransportAdapter.command(for: intent)
                traceCommandSend(command)
                let result = try await connection.transport.send(command)
                try Task.checkCancellation()
                try ensureCurrentConnection(connection)
                traceCommandReply(command, result: result)
                guard domDocumentRequestHandlesByTargetID[targetID] === handle else {
                    inspectorRuntimeDOMTrace("getDocument.dropReply target=\(targetID.rawValue) reason=request-gate-reset")
                    return
                }
                try applyGetDocumentResult(result)
                lastError = nil
            } catch is CancellationError {
                inspectorRuntimeDOMTrace("getDocument.cancelled target=\(targetID.rawValue) reason=\(reason)")
                throw CancellationError()
            } catch {
                if handle.targetKind == .frame, shouldIgnoreFrameDocumentRequestError(error) {
                    inspectorRuntimeDOMTrace("getDocument.frameDrop target=\(targetID.rawValue) reason=\(reason) error=\(error)")
                    return
                }
                inspectorRuntimeFailureTrace("getDocument.failed target=\(targetID.rawValue) reason=\(reason) error=\(error)")
                lastError = InspectorSessionError(String(describing: error))
                throw error
            }
        }
        handle.task = task
        domDocumentRequestHandlesByTargetID[targetID] = handle
        return handle
    }

    private func startPageTargetDocumentRequestAfterCommit(
        targetID: ProtocolTargetIdentifier,
        connection: InspectorConnection
    ) {
        if connection.bootstrappedTargetIDs.contains(targetID) {
            startDOMDocumentRequest(targetID: targetID, reason: "pageTargetCommit")
            return
        }

        Task { @MainActor [weak self, connection] in
            guard let self else {
                return
            }
            do {
                try await bootstrap(mainTargetID: targetID, connection: connection)
            } catch {
                lastError = InspectorSessionError(String(describing: error))
            }
        }
    }

    private func refreshDOMDocumentAfterBackendUpdate(_ event: ProtocolEventEnvelope) {
        guard let targetID = event.targetID,
              dom.currentDocumentID(for: targetID) != nil || dom.currentPageTargetID == targetID else {
            inspectorRuntimeTrace("documentUpdated.drop seq=\(event.sequence) target=\(event.targetID?.rawValue ?? "nil") currentPage=\(dom.currentPageTargetID?.rawValue ?? "nil")")
            return
        }
        let targetKind = dom.targetKind(for: targetID)
        inspectorRuntimeTrace("documentUpdated.invalidate seq=\(event.sequence) target=\(targetID.rawValue) kind=\(String(describing: targetKind)) currentDocument=\(String(describing: dom.currentDocumentID(for: targetID)))")
        cancelDOMDocumentRequest(targetID: targetID, reason: "documentUpdated")
        dom.invalidateDocument(targetID: targetID)
        if targetKind == .frame {
            inspectorRuntimeTrace("documentUpdated.requestFrame target=\(targetID.rawValue)")
            startDOMDocumentRequest(targetID: targetID, force: true, reason: "frameDocumentUpdated")
        }
    }

    private func cancelDOMDocumentRequest(targetID: ProtocolTargetIdentifier, reason: String) {
        guard let handle = domDocumentRequestHandlesByTargetID.removeValue(forKey: targetID) else {
            return
        }
        inspectorRuntimeTrace("documentRequest.cancel target=\(targetID.rawValue) reason=\(reason)")
        handle.task?.cancel()
    }

    private func cancelDOMDocumentRequests() {
        for (targetID, handle) in domDocumentRequestHandlesByTargetID {
            inspectorRuntimeTrace("documentRequest.cancel target=\(targetID.rawValue) reason=session-reset")
            handle.task?.cancel()
        }
        domDocumentRequestHandlesByTargetID.removeAll()
    }

    private func targetDestroyedID(from event: ProtocolEventEnvelope) -> ProtocolTargetIdentifier? {
        guard event.method == "Target.targetDestroyed",
              let params = try? TransportMessageParser.decode(
                  TargetDestroyedEventParams.self,
                  from: event.paramsData
              ) else {
            return nil
        }
        return params.targetId
    }

    private func shouldIgnoreFrameDocumentRequestError(_ error: any Error) -> Bool {
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
            inspectorRuntimeTrace("getDocument.drop reason=missing-target")
            return
        }
        guard dom.targetKind(for: targetID) != nil else {
            inspectorRuntimeTrace("getDocument.drop target=\(targetID.rawValue) reason=missing-target-kind")
            return
        }
        traceGetDocumentResult(result)
        try DOMTransportAdapter.applyGetDocumentResult(result, to: dom)
        startPendingFrameOwnerHydration()
        lastError = nil
    }

    private var currentAppliedDOMSequence: UInt64 {
        connection?.eventPump?.appliedSequence ?? 0
    }

    private func applyElementPickerTargetLifecycle(_ event: ProtocolEventEnvelope) {
        guard let activeTargetID = elementPickerTargetID else {
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
            guard let params = try? TransportMessageParser.decode(
                TargetCommittedEventParams.self,
                from: event.paramsData
            ),
                params.oldTargetId == activeTargetID else {
                return
            }
            recordElementPickerFailure(
                reason: "targetCommitBeforeInspectEvent",
                targetID: activeTargetID,
                details: "newTarget=\(params.newTargetId.rawValue)"
            )
            clearElementPickerState(invalidatePendingSelection: true)
        default:
            return
        }
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
            lastError = InspectorSessionError(String(describing: error))
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
            lastError = InspectorSessionError(String(describing: error))
        }
    }

    private func deleteUndoStateIsCurrent(
        _ state: DOMDeleteUndoState,
        undoManager: UndoManager,
        operation: String
    ) -> Bool {
        guard dom.currentDocumentID(for: state.documentTargetID) == state.documentID else {
            clearDeleteUndoHistory(using: undoManager)
            lastError = InspectorSessionError("DOM document changed before \(operation).")
            return false
        }
        return true
    }

    private func updateDeleteUndoDocumentID(_ state: DOMDeleteUndoState, undoManager: UndoManager) {
        guard let documentID = dom.currentDocumentID(for: state.documentTargetID) else {
            clearDeleteUndoHistory(using: undoManager)
            lastError = InspectorSessionError("DOM document is unavailable after delete undo operation.")
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

    private func activeConnection() throws -> InspectorConnection {
        guard isAttached,
              let connection else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        return connection
    }

    private func ensureCurrentConnection(_ candidate: InspectorConnection) throws {
        guard connection === candidate || pendingConnection === candidate else {
            throw TransportError.transportClosed
        }
    }

    private func traceCommandSend(_ command: ProtocolCommand) {
        switch command.method {
        case "DOM.getDocument", "DOM.requestNode":
            inspectorRuntimeTrace("command.send method=\(command.method) routing=\(command.routing) appliedSeq=\(currentAppliedDOMSequence)")
        default:
            break
        }
    }

    private func traceCommandReply(_ command: ProtocolCommand, result: ProtocolCommandResult) {
        switch command.method {
        case "DOM.getDocument", "DOM.requestNode":
            inspectorRuntimeTrace("command.reply method=\(command.method) target=\(result.targetID?.rawValue ?? "nil") replySeq=\(result.receivedSequence) domSeq=\(result.receivedSequence(for: .dom))")
        default:
            break
        }
    }

    private func traceEvent(_ event: ProtocolEventEnvelope, phase: String) {
        switch event.domain {
        case .target:
            inspectorRuntimeTrace("event.\(phase) seq=\(event.sequence) domain=\(event.domain) method=\(event.method) target=\(event.targetID?.rawValue ?? "nil")")
        case .dom where event.method == "DOM.documentUpdated" || event.method == "DOM.inspect":
            inspectorRuntimeTrace("event.\(phase) seq=\(event.sequence) domain=\(event.domain) method=\(event.method) target=\(event.targetID?.rawValue ?? "nil")")
        default:
            break
        }
    }

    private func traceGetDocumentResult(_ result: ProtocolCommandResult) {
        let summary = (try? JSONDecoder().decode(DOMGetDocumentTracePayload.self, from: result.resultData).root.summary) ?? "decode-failed"
        inspectorRuntimeDOMTrace("getDocument.apply target=\(result.targetID?.rawValue ?? "nil") replySeq=\(result.receivedSequence) domSeq=\(result.receivedSequence(for: .dom)) root=\(summary)")
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

    private func restoreInspectabilityIfNeeded(for connection: InspectorConnection) {
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
