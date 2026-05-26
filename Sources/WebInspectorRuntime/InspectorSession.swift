import Foundation
import Observation
import ObservationBridge
import OSLog
import Synchronization
import WebKit
import WebInspectorCore
import WebInspectorTransport

private enum InspectorRuntimeLog {
    private static let logger = Logger(
        subsystem: "com.lynnswap.WebInspectorKit",
        category: "Runtime"
    )

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    static func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }
}

private enum SelectedNodeStyleHydrationState {
    case detached
    case waitingForDocument
    case unavailable(CSSNodeStylesUnavailableReason)
    case needsRefresh(CSSNodeStyleIdentity)
    case refreshing(CSSNodeStyleIdentity)
    case current(CSSNodeStyleIdentity)
}

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
private final class DOMDeleteUndoOperationQueue {
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
private final class InspectorTarget {
    let id: ProtocolTargetIdentifier
    var kind: ProtocolTargetKind
    var frameID: DOMFrameIdentifier?
    var parentFrameID: DOMFrameIdentifier?
    var capabilities: ProtocolTargetCapabilities
    var isProvisional: Bool
    var isPaused: Bool
    var isBootstrapped: Bool
    private var enabledDomains: ProtocolTargetCapabilities
    private var runtimeConsoleEnableTask: Task<Void, Never>?

    init(snapshot: ProtocolTargetSnapshot) {
        id = snapshot.id
        kind = snapshot.kind
        frameID = snapshot.frameID
        parentFrameID = snapshot.parentFrameID
        capabilities = snapshot.capabilities
        isProvisional = snapshot.isProvisional
        isPaused = snapshot.isPaused
        isBootstrapped = false
        enabledDomains = []
        runtimeConsoleEnableTask = nil
    }

    func update(from snapshot: ProtocolTargetSnapshot) {
        kind = snapshot.kind
        frameID = snapshot.frameID
        parentFrameID = snapshot.parentFrameID
        capabilities = snapshot.capabilities
        isProvisional = snapshot.isProvisional
        isPaused = snapshot.isPaused
    }

    func hasDomain(_ domain: ProtocolTargetCapabilities) -> Bool {
        capabilities.contains(domain)
    }

    func markEnabled(_ domain: ProtocolTargetCapabilities) {
        enabledDomains.insert(domain)
    }

    func shouldEnableCompatibilityCSS() -> Bool {
        hasDomain(.css) && enabledDomains.contains(.css) == false
    }

    func shouldEnableRuntime(using runtime: RuntimeSession) -> Bool {
        isProvisional == false
            && hasDomain(.runtime)
            && enabledDomains.contains(.runtime) == false
            && runtime.supportsCommand("Runtime.enable", targetID: id)
    }

    func shouldEnableConsole(using console: ConsoleSession, force: Bool = false) -> Bool {
        isProvisional == false
            && hasDomain(.console)
            && (force || enabledDomains.contains(.console) == false)
            && console.supportsCommand("Console.enable", targetID: id)
    }

    func canStartRuntimeConsoleEnable(using runtime: RuntimeSession, console: ConsoleSession) -> Bool {
        runtimeConsoleEnableTask == nil
            && (shouldEnableRuntime(using: runtime) || shouldEnableConsole(using: console))
    }

    func startRuntimeConsoleEnableTask(_ task: Task<Void, Never>) {
        runtimeConsoleEnableTask = task
    }

    func finishRuntimeConsoleEnableTask() {
        runtimeConsoleEnableTask = nil
    }

    func cancelRuntimeConsoleEnableTask() {
        runtimeConsoleEnableTask?.cancel()
        runtimeConsoleEnableTask = nil
    }
}

@MainActor
private final class InspectorTargetRegistry {
    private var targetsByID: [ProtocolTargetIdentifier: InspectorTarget]

    init() {
        targetsByID = [:]
    }

    var targets: [InspectorTarget] {
        Array(targetsByID.values)
    }

    func sync(from snapshot: DOMSessionSnapshot) {
        let currentTargetIDs = Set(snapshot.targetsByID.keys)
        for removedTargetID in Array(targetsByID.keys) where currentTargetIDs.contains(removedTargetID) == false {
            removeTarget(removedTargetID)
        }
        for targetSnapshot in snapshot.targetsByID.values {
            upsertTarget(from: targetSnapshot)
        }
    }

    func target(for targetID: ProtocolTargetIdentifier) -> InspectorTarget? {
        targetsByID[targetID]
    }

    @discardableResult
    func upsertTarget(from snapshot: ProtocolTargetSnapshot) -> InspectorTarget {
        if let target = targetsByID[snapshot.id] {
            target.update(from: snapshot)
            return target
        }
        let target = InspectorTarget(snapshot: snapshot)
        targetsByID[snapshot.id] = target
        return target
    }

    func removeTarget(_ targetID: ProtocolTargetIdentifier) {
        targetsByID.removeValue(forKey: targetID)?.cancelRuntimeConsoleEnableTask()
    }

    func cancelRuntimeConsoleEnableTasks() {
        for target in targetsByID.values {
            target.cancelRuntimeConsoleEnableTask()
        }
    }
}

@MainActor
private final class InspectorConnection {
    let transport: TransportSession
    weak var webView: WKWebView?
    let originalInspectability: Bool?
    var eventPump: DomainEventPump?
    let targets: InspectorTargetRegistry

    init(
        transport: TransportSession,
        webView: WKWebView? = nil,
        originalInspectability: Bool? = nil
    ) {
        self.transport = transport
        self.webView = webView
        self.originalInspectability = originalInspectability
        eventPump = nil
        targets = InspectorTargetRegistry()
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

@MainActor
@Observable
package final class InspectorSession {
    package let dom: DOMSession
    package let css: CSSSession
    package let network: NetworkSession
    package let runtime: RuntimeSession
    package let console: ConsoleSession
    package private(set) var isAttached: Bool
    package private(set) var lastError: InspectorSessionError?
    package private(set) var isSelectingElement: Bool

    @ObservationIgnored private let configuration: InspectorSessionConfiguration
    @ObservationIgnored private var connection: InspectorConnection?
    @ObservationIgnored private var pendingConnection: InspectorConnection?
    @ObservationIgnored private var highlightedDOMTargetID: ProtocolTargetIdentifier?
    @ObservationIgnored private var elementPickerTargetID: ProtocolTargetIdentifier?
    @ObservationIgnored private var elementPickerGeneration: UInt64
    @ObservationIgnored private var elementPickerAcceptsInspectEvents: Bool
    @ObservationIgnored private weak var deleteUndoManager: UndoManager?
    @ObservationIgnored private var deleteUndoStates: [DOMDeleteUndoState]
    @ObservationIgnored private let deleteUndoOperationQueue: DOMDeleteUndoOperationQueue
    @ObservationIgnored private var domDocumentRequestHandlesByTargetID: [ProtocolTargetIdentifier: DOMDocumentRequestHandle]
    @ObservationIgnored private var selectedNodeStyleHydrationObservationTask: Task<Void, Never>?
    @ObservationIgnored private var selectedNodeStyleHydrationTask: Task<Void, Never>?
    @ObservationIgnored private var selectedNodeStyleHydrationIdentity: CSSNodeStyleIdentity?
    @ObservationIgnored private var isSelectedNodeStyleHydrationActive: Bool
    @ObservationIgnored private var cssPropertyUpdateTasks: [CSSPropertyIdentifier: Task<Void, Never>]

    package init(
        configuration: InspectorSessionConfiguration = .init(),
        dom: DOMSession = DOMSession(),
        css: CSSSession = CSSSession(),
        network: NetworkSession = NetworkSession(),
        runtime: RuntimeSession = RuntimeSession(),
        console: ConsoleSession = ConsoleSession()
    ) {
        self.configuration = configuration
        self.dom = dom
        self.css = css
        self.network = network
        self.runtime = runtime
        self.console = console
        isAttached = false
        lastError = nil
        isSelectingElement = false
        connection = nil
        pendingConnection = nil
        highlightedDOMTargetID = nil
        elementPickerTargetID = nil
        elementPickerGeneration = 0
        elementPickerAcceptsInspectEvents = false
        deleteUndoManager = nil
        deleteUndoStates = []
        deleteUndoOperationQueue = DOMDeleteUndoOperationQueue()
        domDocumentRequestHandlesByTargetID = [:]
        selectedNodeStyleHydrationObservationTask = nil
        selectedNodeStyleHydrationTask = nil
        selectedNodeStyleHydrationIdentity = nil
        isSelectedNodeStyleHydrationActive = false
        cssPropertyUpdateTasks = [:]
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
        seedRuntimeSession(from: await transport.snapshot())
        syncTargets(for: nextConnection)

        do {
            let mainTarget = try await transport.waitForCurrentMainPageTarget(
                timeout: configuration.bootstrapTimeout
            )
            seedDOMSession(from: await transport.snapshot())
            seedRuntimeSession(from: await transport.snapshot())
            syncTargets(for: nextConnection)
            try await bootstrap(mainTargetID: mainTarget.targetID, connection: nextConnection)
            try ensureCurrentConnection(nextConnection)
            pendingConnection = nil
            connection = nextConnection
            isAttached = true
            if isSelectedNodeStyleHydrationActive {
                startSelectedNodeStyleHydration()
            }
            startDOMDocumentRequestsForAttachedFrameTargets()
            startRuntimeConsoleEnableForAttachedTargets()
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
            cancelCSSActionRequests()
            stopSelectedNodeStyleHydration()
            dom.reset()
            css.reset()
            network.reset()
            runtime.reset()
            console.reset()
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
        stopSelectedNodeStyleHydration()

        if let previousConnection {
            cancelRuntimeConsoleEnableTasks(previousConnection)
            stopPumps(previousConnection)
            await previousConnection.transport.detach()
            restoreInspectabilityIfNeeded(for: previousConnection)
        }
        if let previousPendingConnection {
            cancelRuntimeConsoleEnableTasks(previousPendingConnection)
            stopPumps(previousPendingConnection)
            await previousPendingConnection.transport.detach()
            restoreInspectabilityIfNeeded(for: previousPendingConnection)
        }
        cancelDOMDocumentRequests()
        cancelCSSActionRequests()
        dom.reset()
        css.reset()
        network.reset()
        runtime.reset()
        console.reset()
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

        elementPickerGeneration &+= 1
        let pickerGeneration = elementPickerGeneration
        elementPickerTargetID = targetID
        elementPickerAcceptsInspectEvents = false
        isSelectingElement = true

        do {
            guard let intent = dom.setInspectModeEnabledIntent(targetID: targetID, enabled: true) else {
                recordElementPickerFailure(reason: "inspectModeUnavailable", targetID: targetID)
                throw InspectorSessionError("DOM inspect mode is not available.")
            }
            try await perform(intent)
            guard isElementPickerSession(generation: pickerGeneration, targetID: targetID) else {
                return
            }
            elementPickerAcceptsInspectEvents = true
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
        return try await copyDOMNodeText(kind, for: nodeID)
    }

    package func copyDOMNodeText(_ kind: DOMNodeCopyTextKind, for nodeID: WebInspectorCore.DOMNode.ID) async throws -> String {
        guard isAttached else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        switch kind {
        case .html:
            let commandTargetID = try currentPageTargetForDOMAction()
            guard let intent = dom.outerHTMLIntent(for: nodeID, commandTargetID: commandTargetID) else {
                throw InspectorSessionError("DOM node is no longer available.")
            }
            let result = try await perform(intent)
            return try DOMTransportAdapter.outerHTML(from: result)
        case .selectorPath:
            guard let node = dom.node(for: nodeID) else {
                throw InspectorSessionError("DOM node is no longer available.")
            }
            return dom.selectorPath(for: node)
        case .xPath:
            guard let node = dom.node(for: nodeID) else {
                throw InspectorSessionError("DOM node is no longer available.")
            }
            return dom.xPath(for: node)
        }
    }

    package func deleteSelectedDOMNode(undoManager: UndoManager?) async throws {
        guard isAttached else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        guard let nodeID = dom.selectedNodeID else {
            throw InspectorSessionError("No DOM node is selected.")
        }
        try await deleteDOMNode(nodeID, undoManager: undoManager)
    }

    package func deleteDOMNodes(_ nodeIDs: [WebInspectorCore.DOMNode.ID], undoManager: UndoManager?) async throws {
        var seenNodeIDs: Set<WebInspectorCore.DOMNode.ID> = []
        let uniqueNodeIDs = nodeIDs.filter { seenNodeIDs.insert($0).inserted }
        let actionName = uniqueNodeIDs.count > 1 ? "Delete Nodes" : "Delete Node"
        var undoStates: [DOMDeleteUndoState] = []

        do {
            for nodeID in uniqueNodeIDs.sorted(by: { depthFromRoot(for: $0) > depthFromRoot(for: $1) }) {
                undoStates.append(try await performDeleteDOMNode(nodeID))
            }
        } catch {
            registerUndoDeletes(undoStates, undoManager: undoManager, actionName: actionName)
            throw error
        }
        registerUndoDeletes(undoStates, undoManager: undoManager, actionName: actionName)
    }

    package func deleteDOMNode(_ nodeID: WebInspectorCore.DOMNode.ID, undoManager: UndoManager?) async throws {
        let undoState = try await performDeleteDOMNode(nodeID)
        if let undoManager {
            registerUndoDelete(undoState, undoManager: undoManager)
        }
    }

    private func performDeleteDOMNode(_ nodeID: WebInspectorCore.DOMNode.ID) async throws -> DOMDeleteUndoState {
        guard isAttached else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        let commandTargetID = try currentPageTargetForDOMAction()
        guard let identity = dom.actionIdentity(for: nodeID, commandTargetID: commandTargetID),
              let intent = dom.removeNodeIntent(for: nodeID, commandTargetID: identity.commandTargetID) else {
            throw InspectorSessionError("DOM node is no longer available.")
        }
        let documentID = nodeID.documentID

        try await perform(intent)
        dom.applyNodeRemoved(nodeID)
        dom.selectNode(nil)
        css.removeStyles(targetID: documentID.targetID)
        lastError = nil

        return DOMDeleteUndoState(
            documentTargetID: identity.documentTargetID,
            commandTargetID: identity.commandTargetID,
            documentID: documentID
        )
    }

    private func depthFromRoot(for nodeID: WebInspectorCore.DOMNode.ID) -> Int {
        var depth = 0
        var currentNode = dom.node(for: nodeID)
        while let parentID = currentNode?.parentID,
              let parent = dom.node(for: parentID) {
            depth += 1
            currentNode = parent
        }
        return depth
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
            try await reloadDOMDocument(targetID: targetID)
            return dom.currentPageRootNode != nil
        } catch is CancellationError {
            guard isAttached,
                  dom.currentPageRootNode == nil else {
                return dom.currentPageRootNode != nil
            }
            do {
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
        cancelDOMDocumentRequests()
        cancelCSSActionRequests()
        dom.reset()
        css.reset()
        network.reset()
        runtime.reset()
        console.reset()
        if let connection {
            seedDOMSession(from: await connection.transport.snapshot())
            seedRuntimeSession(from: await connection.transport.snapshot())
            syncTargets(for: connection)
        }
        webView.reload()
    }

    package func waitUntilProtocolEventApplied(_ sequence: UInt64) async -> Bool {
        guard let eventPump = connection?.eventPump else {
            return false
        }
        return await eventPump.waitUntilApplied(sequence)
    }

    @discardableResult
    package func perform(_ intent: DOMCommandIntent) async throws -> ProtocolCommandResult {
        let connection = try activeConnection()
        let transport = connection.transport
        let command = try DOMTransportAdapter.command(for: intent)
        let result: ProtocolCommandResult
        do {
            result = try await transport.send(command)
        } catch {
            InspectorRuntimeLog.error("command.error method=\(command.method) routing=\(command.routing) error=\(error)")
            throw error
        }
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
            case .resolved, .pending:
                break
            case let .failed(failure):
                InspectorRuntimeLog.warning("requestNode.selectFailure target=\(targetID.rawValue) failure=\(failure)")
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

    @discardableResult
    package func perform(_ intent: CSSCommandIntent) async throws -> ProtocolCommandResult {
        let connection = try activeConnection()
        let transport = connection.transport
        let result = try await transport.send(CSSTransportAdapter.command(for: intent))
        try ensureCurrentConnection(connection)
        return result
    }

    @discardableResult
    package func perform(_ intent: RuntimeCommandIntent) async throws -> ProtocolCommandResult {
        let connection = try activeConnection()
        let transport = connection.transport
        let command = try RuntimeTransportAdapter.command(for: intent)
        let result: ProtocolCommandResult
        do {
            result = try await transport.send(command)
        } catch {
            markRuntimeCommandUnsupportedIfNeeded(command.method, targetID: intent.routingTargetID, error: error)
            throw error
        }
        try ensureCurrentConnection(connection)

        switch intent {
        case let .evaluate(request):
            let payload = try RuntimeTransportAdapter.evaluationResult(from: result)
            runtime.applyEvaluationResult(
                payload,
                request: request,
                runtimeAgentTargetID: result.targetID
            )
        case let .releaseObject(key):
            runtime.releaseObject(key)
        case let .releaseObjectGroup(runtimeAgentTargetID, objectGroup):
            runtime.releaseObjectGroup(objectGroup, runtimeAgentTargetID: runtimeAgentTargetID)
        default:
            break
        }
        return result
    }

    @discardableResult
    package func perform(_ intent: ConsoleCommandIntent) async throws -> ProtocolCommandResult {
        let connection = try activeConnection()
        let transport = connection.transport
        let command = try ConsoleTransportAdapter.command(for: intent)
        do {
            let result = try await transport.send(command)
            try ensureCurrentConnection(connection)
            return result
        } catch {
            markConsoleCommandUnsupportedIfNeeded(command.method, targetID: intent.targetID, error: error)
            throw error
        }
    }

    package func refreshStylesForSelectedNode() async {
        do {
            try await refreshSelectedNodeStyles()
            lastError = nil
        } catch {
            lastError = InspectorSessionError(String(describing: error))
        }
    }

    package func setSelectedNodeStyleHydrationActive(_ isActive: Bool) {
        guard isSelectedNodeStyleHydrationActive != isActive else {
            return
        }
        isSelectedNodeStyleHydrationActive = isActive
        if isActive, isAttached {
            startSelectedNodeStyleHydration()
        } else {
            stopSelectedNodeStyleHydration()
        }
    }

    @discardableResult
    package func requestSetCSSProperty(_ propertyID: CSSPropertyIdentifier, enabled: Bool) -> Bool {
        guard isAttached,
              cssPropertyUpdateTasks[propertyID] == nil,
              css.setStyleTextIntent(for: propertyID, enabled: enabled) != nil else {
            return false
        }

        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                cssPropertyUpdateTasks[propertyID] = nil
            }
            guard Task.isCancelled == false else {
                return
            }

            do {
                try await setCSSProperty(propertyID, enabled: enabled)
            } catch {
                lastError = InspectorSessionError(String(describing: error))
                try? await refreshSelectedNodeStyles()
            }
        }
        cssPropertyUpdateTasks[propertyID] = task
        return true
    }

    package func setCSSProperty(_ propertyID: CSSPropertyIdentifier, enabled: Bool) async throws {
        guard let intent = css.setStyleTextIntent(for: propertyID, enabled: enabled) else {
            throw InspectorSessionError("CSS property is not editable.")
        }
        let result = try await perform(intent)
        guard case let .setStyleText(targetID, _, _) = intent else {
            throw InspectorSessionError("Unexpected CSS command intent.")
        }
        let style = try CSSTransportAdapter.setStyleTextResult(from: result)
        css.applySetStyleTextResult(style, propertyID: propertyID, targetID: targetID)
        try await refreshSelectedNodeStyles()
        lastError = nil
    }

    private func startSelectedNodeStyleHydration() {
        selectedNodeStyleHydrationObservationTask?.cancel()
        selectedNodeStyleHydrationObservationTask = Task { @MainActor [weak self] in
            let stream = makeObservationBridgeStream {
                self?.selectedNodeStyleHydrationState() ?? .detached
            }
            for await state in stream {
                guard let self else {
                    return
                }
                self.applySelectedNodeStyleHydrationState(state)
            }
        }
    }

    private func stopSelectedNodeStyleHydration() {
        selectedNodeStyleHydrationObservationTask?.cancel()
        selectedNodeStyleHydrationObservationTask = nil
        cancelSelectedNodeStyleHydrationRefresh()
    }

    private func selectedNodeStyleHydrationState() -> SelectedNodeStyleHydrationState {
        guard isAttached else {
            return .detached
        }
        guard dom.currentPageRootNode != nil else {
            return .waitingForDocument
        }

        switch dom.selectedCSSNodeStyleIdentity() {
        case let .success(identity):
            switch css.refreshState(forSelected: identity) {
            case nil, .needsRefresh:
                return .needsRefresh(identity)
            case .loading:
                return .refreshing(identity)
            case .loaded, .failed(_), .unavailable(_):
                return .current(identity)
            }
        case let .failure(reason):
            return .unavailable(reason)
        }
    }

    private func applySelectedNodeStyleHydrationState(_ state: SelectedNodeStyleHydrationState) {
        switch state {
        case .detached, .waitingForDocument, .refreshing, .current:
            return
        case .unavailable(let reason):
            cancelSelectedNodeStyleHydrationRefresh()
            css.markSelectedNodeUnavailable(reason)
        case .needsRefresh(let identity):
            hydrateSelectedNodeStyles(identity)
        }
    }

    private func hydrateSelectedNodeStyles(_ identity: CSSNodeStyleIdentity) {
        guard selectedNodeStyleHydrationIdentity != identity else {
            return
        }

        cancelSelectedNodeStyleHydrationRefresh()
        selectedNodeStyleHydrationIdentity = identity
        selectedNodeStyleHydrationTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                if self.selectedNodeStyleHydrationIdentity == identity {
                    self.selectedNodeStyleHydrationIdentity = nil
                    self.selectedNodeStyleHydrationTask = nil
                }
            }
            guard Task.isCancelled == false else {
                return
            }

            do {
                try await self.refreshStyles(for: identity)
                self.lastError = nil
            } catch is CancellationError {
                self.css.cancelRefresh(identity: identity)
            } catch {
                self.lastError = InspectorSessionError(String(describing: error))
            }
        }
    }

    private func cancelSelectedNodeStyleHydrationRefresh() {
        selectedNodeStyleHydrationTask?.cancel()
        selectedNodeStyleHydrationTask = nil
        if let selectedNodeStyleHydrationIdentity {
            css.cancelRefresh(identity: selectedNodeStyleHydrationIdentity)
        }
        selectedNodeStyleHydrationIdentity = nil
    }

    private func refreshSelectedNodeStyles() async throws {
        switch dom.selectedCSSNodeStyleIdentity() {
        case let .success(identity):
            try await refreshStyles(for: identity)
        case let .failure(reason):
            css.markSelectedNodeUnavailable(reason)
        }
    }

    private func refreshStyles(for identity: CSSNodeStyleIdentity) async throws {
        let connection = try activeConnection()
        let targetExists = await connection.transport.snapshot().targetsByID[identity.targetID] != nil
        guard targetExists else {
            css.markSelectedNodeStylesUnavailable(identity: identity, reason: .staleNode(identity.nodeID))
            return
        }
        guard let token = css.beginRefresh(identity: identity) else {
            return
        }
        let transport = connection.transport

        do {
            let results: CSSRefreshResults
            do {
                results = try await fetchStyleResults(for: identity, transport: transport)
            } catch {
                guard shouldRetryAfterEnablingCSSAgent(error) else {
                    throw error
                }
                try await enableCSSAgentForCompatibility(targetID: identity.targetID, connection: connection)
                results = try await fetchStyleResults(for: identity, transport: transport)
            }
            try ensureCurrentConnection(connection)
            guard case let .success(currentIdentity) = dom.selectedCSSNodeStyleIdentity(),
                  currentIdentity == identity else {
                return
            }

            css.applyRefresh(
                token: token,
                matched: try CSSTransportAdapter.matchedStyles(from: results.matched),
                inline: try CSSTransportAdapter.inlineStyles(from: results.inline),
                computed: try CSSTransportAdapter.computedStyles(from: results.computed)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            css.markRefreshFailed(token, message: String(describing: error))
            throw error
        }
    }

    private struct CSSRefreshResults {
        var matched: ProtocolCommandResult
        var inline: ProtocolCommandResult
        var computed: ProtocolCommandResult
    }

    private func fetchStyleResults(
        for identity: CSSNodeStyleIdentity,
        transport: TransportSession
    ) async throws -> CSSRefreshResults {
        let matchedCommand = try CSSTransportAdapter.command(for: .getMatchedStyles(identity: identity))
        let inlineCommand = try CSSTransportAdapter.command(for: .getInlineStyles(identity: identity))
        let computedCommand = try CSSTransportAdapter.command(for: .getComputedStyle(identity: identity))

        async let matchedResult = transport.send(matchedCommand)
        async let inlineResult = transport.send(inlineCommand)
        async let computedResult = transport.send(computedCommand)

        let results = try await (matchedResult, inlineResult, computedResult)
        return CSSRefreshResults(matched: results.0, inline: results.1, computed: results.2)
    }

    private func shouldRetryAfterEnablingCSSAgent(_ error: any Error) -> Bool {
        guard case let TransportError.remoteError(method, _, message) = error,
              method.hasPrefix("CSS.") else {
            return false
        }

        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("enable")
            || normalizedMessage.contains("enabled")
    }

    private func markRuntimeCommandUnsupportedIfNeeded(
        _ method: String,
        targetID: ProtocolTargetIdentifier,
        error: any Error
    ) {
        guard isUnsupportedProtocolCommandError(method, error: error) else {
            return
        }
        runtime.markCommandUnsupported(method, targetID: targetID)
    }

    private func markConsoleCommandUnsupportedIfNeeded(
        _ method: String,
        targetID: ProtocolTargetIdentifier,
        error: any Error
    ) {
        guard isUnsupportedProtocolCommandError(method, error: error) else {
            return
        }
        console.markCommandUnsupported(method, targetID: targetID)
    }

    private func isUnsupportedProtocolCommandError(
        _ method: String,
        error: any Error
    ) -> Bool {
        guard case let TransportError.remoteError(errorMethod, _, message) = error,
              errorMethod == method else {
            return false
        }
        let normalizedMessage = message.lowercased()
        if normalizedMessage.contains("unknown command")
            || normalizedMessage.contains("unknown method")
            || normalizedMessage.contains("unrecognized command")
            || normalizedMessage.contains("unrecognized method")
            || normalizedMessage.contains("unsupported command")
            || normalizedMessage.contains("unsupported method")
            || normalizedMessage.contains("command not found")
            || normalizedMessage.contains("method not found") {
            return true
        }

        guard normalizedMessage.contains("not implemented") else {
            return false
        }
        return normalizedMessage.contains(method.lowercased())
            || normalizedMessage.contains("command")
            || normalizedMessage.contains("method")
    }

    private func enableCSSAgentForCompatibility(
        targetID: ProtocolTargetIdentifier,
        connection: InspectorConnection
    ) async throws {
        syncTargets(for: connection)
        guard let target = connection.targets.target(for: targetID),
              target.shouldEnableCompatibilityCSS() else {
            return
        }

        // Do not enable the WebKit CSS agent proactively. On current simulator
        // WebContent, CSS.enable can crash while synchronizing stylesheet
        // headers during page load, while the read commands work without it.
        _ = try await connection.transport.send(try CSSTransportAdapter.command(for: .enable(targetID: targetID)))
        try ensureCurrentConnection(connection)
        target.markEnabled(.css)
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
        _ = try await sendTargetCommand(domain: .inspector, method: "Inspector.enable", targetID: mainTargetID, connection: connection)
        try ensureCurrentConnection(connection)
        _ = try await sendTargetCommand(domain: .inspector, method: "Inspector.initialized", targetID: mainTargetID, connection: connection)
        try ensureCurrentConnection(connection)
        _ = try await sendTargetCommand(domain: .dom, method: "DOM.enable", targetID: mainTargetID, connection: connection)
        try ensureCurrentConnection(connection)
        _ = try await connection.transport.send(
            try RuntimeTransportAdapter.command(for: .enable(targetID: mainTargetID))
        )
        try ensureCurrentConnection(connection)
        syncTargets(for: connection)
        connection.targets.target(for: mainTargetID)?.markEnabled(.runtime)

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
        try await enableConsoleAgentIfSupported(targetID: mainTargetID, connection: connection, force: true)
        connection.targets.target(for: mainTargetID)?.isBootstrapped = true
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
        switch event.domain {
        case .target:
            await handleTargetEvent(event)
        case .runtime:
            applyEvent(event) {
                try RuntimeTransportAdapter.applyRuntimeEvent(event, to: $0.runtime)
                try DOMTransportAdapter.applyRuntimeEvent(event, to: $0.dom)
            }
        case .console:
            applyEvent(event) { session in
                if let targetID = event.targetID,
                   let message = try ConsoleTransportAdapter.messagePayload(from: event) {
                    let parameters = message.parameters.map { parameter in
                        session.runtime.registerRemoteObject(
                            parameter,
                            runtimeAgentTargetID: targetID,
                            objectGroup: .console
                        )
                    }
                    session.console.applyMessageAdded(message, targetID: targetID, parameters: parameters)
                    return
                }
                try ConsoleTransportAdapter.applyConsoleEvent(event, to: session.console)
                if event.method == "Console.messagesCleared",
                   let targetID = event.targetID {
                    session.runtime.releaseObjectGroup(.console, runtimeAgentTargetID: targetID)
                }
            }
        case .inspector:
            await handleInspectorEvent(event)
        case .dom:
            await handleDOMEvent(event)
        case .css:
            applyEvent(event) {
                try CSSTransportAdapter.applyCSSEvent(event, to: $0.css)
            }
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
            await handleInspectEvent(inspectEvent)
        } catch {
            lastError = InspectorSessionError("\(event.method): \(error)")
        }
    }

    private func handleTargetEvent(_ event: ProtocolEventEnvelope) async {
        do {
            let destroyedTargetID = targetDestroyedID(from: event)
            let targetCommit = try DOMTransportAdapter.targetCommitResolution(from: event, snapshot: dom.snapshot())
            let createdTarget = try DOMTransportAdapter.applyTargetEvent(event, to: dom)
            if let createdTarget {
                runtime.applyTargetCreated(createdTarget)
            }
            if let connection {
                syncTargets(for: connection)
            }
            if let destroyedTargetID {
                cancelDOMDocumentRequest(targetID: destroyedTargetID, reason: "targetDestroyed")
                cancelRuntimeConsoleEnableTask(targetID: destroyedTargetID)
                css.removeStyles(targetID: destroyedTargetID)
                runtime.applyTargetDestroyed(destroyedTargetID)
                console.applyTargetDestroyed(destroyedTargetID)
                discardConnectionTargetState(targetID: destroyedTargetID)
            }
            applyElementPickerTargetLifecycle(event, targetCommit: targetCommit)
            if isAttached,
               let createdTarget {
                if createdTarget.kind == .frame,
                   createdTarget.capabilities.contains(.dom) {
                    startDOMDocumentRequest(targetID: createdTarget.id, reason: "frameTargetCreated")
                }
                startRuntimeConsoleEnableIfNeeded(targetID: createdTarget.id, reason: "targetCreated")
            }
            if event.method == "Target.didCommitProvisionalTarget",
               dom.currentPageRootNode == nil,
               let targetID = dom.currentPageTargetID,
               let connection {
                startPageTargetDocumentRequestAfterCommit(targetID: targetID, connection: connection)
            }
            if event.method == "Target.didCommitProvisionalTarget",
               let targetCommit {
                if let committedTarget = dom.snapshot().targetsByID[targetCommit.newTargetID] {
                    runtime.applyTargetCreated(committedTarget.record)
                }
                if let oldTargetID = targetCommit.consumedOldTargetID {
                    cancelDOMDocumentRequest(targetID: oldTargetID, reason: "frameTargetCommit")
                    cancelRuntimeConsoleEnableTask(targetID: oldTargetID)
                    css.removeStyles(targetID: oldTargetID)
                    runtime.applyTargetCommitted(oldTargetID: oldTargetID, newTargetID: targetCommit.newTargetID)
                    console.applyTargetCommitted(oldTargetID: oldTargetID, newTargetID: targetCommit.newTargetID)
                    discardConnectionTargetState(targetID: oldTargetID)
                }
                startFrameTargetDocumentRequestAfterCommit(targetID: targetCommit.newTargetID)
                startRuntimeConsoleEnableIfNeeded(targetID: targetCommit.newTargetID, reason: "frameTargetCommit")
            }
        } catch {
            lastError = InspectorSessionError("\(event.method): \(error)")
        }
    }

    private func startDOMDocumentRequestsForAttachedFrameTargets() {
        for target in dom.snapshot().targetsByID.values
        where target.kind == .frame
            && target.capabilities.contains(.dom)
            && target.currentDocumentID == nil {
            startDOMDocumentRequest(targetID: target.id, reason: "attachedFrameTarget")
        }
    }

    private func startRuntimeConsoleEnableForAttachedTargets() {
        for target in dom.snapshot().targetsByID.values
        where target.isProvisional == false {
            startRuntimeConsoleEnableIfNeeded(targetID: target.id, reason: "attachedTarget")
        }
    }

    private func startRuntimeConsoleEnableIfNeeded(targetID: ProtocolTargetIdentifier, reason: String) {
        guard isAttached,
              let connection else {
            return
        }
        syncTargets(for: connection)
        guard let target = connection.targets.target(for: targetID),
              target.canStartRuntimeConsoleEnable(using: runtime, console: console) else {
            return
        }

        let task = Task { @MainActor [weak self, connection] in
            guard let self else {
                return
            }
            defer {
                connection.targets.target(for: targetID)?.finishRuntimeConsoleEnableTask()
            }
            do {
                try await enableRuntimeConsoleIfNeeded(targetID: targetID, connection: connection)
            } catch is CancellationError {
            } catch {
                InspectorRuntimeLog.warning("runtimeConsoleEnable.failed target=\(targetID.rawValue) reason=\(reason) error=\(error)")
                lastError = InspectorSessionError(String(describing: error))
            }
        }
        target.startRuntimeConsoleEnableTask(task)
    }

    private func enableRuntimeConsoleIfNeeded(
        targetID: ProtocolTargetIdentifier,
        connection: InspectorConnection
    ) async throws {
        try Task.checkCancellation()
        syncTargets(for: connection)
        guard let target = connection.targets.target(for: targetID),
              target.isProvisional == false else {
            return
        }

        if target.shouldEnableRuntime(using: runtime) {
            do {
                _ = try await connection.transport.send(try RuntimeTransportAdapter.command(for: .enable(targetID: targetID)))
                try ensureCurrentConnection(connection)
                target.markEnabled(.runtime)
            } catch {
                markRuntimeCommandUnsupportedIfNeeded("Runtime.enable", targetID: targetID, error: error)
                if isUnsupportedProtocolCommandError("Runtime.enable", error: error) == false {
                    throw error
                }
            }
        }

        try Task.checkCancellation()
        guard target.shouldEnableConsole(using: console) else {
            return
        }
        try await enableConsoleAgentIfSupported(targetID: targetID, connection: connection)
    }

    private func enableConsoleAgentIfSupported(
        targetID: ProtocolTargetIdentifier,
        connection: InspectorConnection,
        force: Bool = false
    ) async throws {
        syncTargets(for: connection)
        guard let target = connection.targets.target(for: targetID),
              target.shouldEnableConsole(using: console, force: force) else {
            return
        }
        do {
            _ = try await connection.transport.send(try ConsoleTransportAdapter.command(for: .enable(targetID: targetID)))
            try ensureCurrentConnection(connection)
            target.markEnabled(.console)
        } catch {
            markConsoleCommandUnsupportedIfNeeded("Console.enable", targetID: targetID, error: error)
            if isUnsupportedProtocolCommandError("Console.enable", error: error) {
                return
            }
            throw error
        }
    }

    private func cancelRuntimeConsoleEnableTask(targetID: ProtocolTargetIdentifier) {
        guard let connection else {
            return
        }
        connection.targets.target(for: targetID)?.cancelRuntimeConsoleEnableTask()
    }

    private func cancelRuntimeConsoleEnableTasks(_ connection: InspectorConnection) {
        connection.targets.cancelRuntimeConsoleEnableTasks()
    }

    private func discardConnectionTargetState(targetID: ProtocolTargetIdentifier) {
        guard let connection else {
            return
        }
        connection.targets.removeTarget(targetID)
    }

    private func startFrameTargetDocumentRequestAfterCommit(targetID: ProtocolTargetIdentifier) {
        guard isAttached,
              let target = dom.snapshot().targetsByID[targetID],
              target.kind == .frame,
              target.capabilities.contains(.dom),
              target.currentDocumentID == nil else {
            return
        }
        startDOMDocumentRequest(targetID: targetID, reason: "frameTargetCommit")
    }

    private func handleDOMEvent(_ event: ProtocolEventEnvelope) async {
        do {
            if let inspectEvent = try DOMTransportAdapter.inspectEvent(from: event) {
                await handleInspectEvent(inspectEvent)
                return
            }
            if event.method == "DOM.documentUpdated" {
                if let targetID = event.targetID ?? dom.currentPageTargetID {
                    css.removeStyles(targetID: targetID)
                }
                refreshDOMDocumentAfterBackendUpdate(event)
                return
            }
            let selectedStyleIdentity = css.selectedNodeStyles?.identity
            try DOMTransportAdapter.applyDOMEvent(event, to: dom)
            if let selectedStyleIdentity,
               let targetID = event.targetID,
               selectedStyleIdentity.targetID == targetID {
                if dom.selectedNodeID != selectedStyleIdentity.nodeID {
                    css.removeStyles(targetID: targetID)
                } else if selectedStylesShouldRefresh(after: event) {
                    css.markNeedsRefresh(targetID: targetID, nodeID: selectedStyleIdentity.protocolNodeID)
                }
            }
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
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            do {
                try await perform(intent)
            } catch {
                InspectorRuntimeLog.warning("frameOwnerHydration.failed intent=\(intent) error=\(error)")
                clearOwnerHydrationTransaction(for: intent)
                lastError = InspectorSessionError(String(describing: error))
            }
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

    private func handleInspectEvent(_ event: DOMInspectEvent) async {
        guard isSelectingElement,
              elementPickerAcceptsInspectEvents,
              let activeTargetID = elementPickerTargetID else {
            recordElementPickerFailure(
                reason: "inspectEventWithoutActivePicker",
                details: "activeTarget=\(elementPickerTargetID?.rawValue ?? "nil")"
            )
            return
        }
        let pickerGeneration = elementPickerGeneration
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
            lastError = InspectorSessionError(String(describing: error))
        }

        await completeElementPicker(generation: pickerGeneration, targetID: activeTargetID)
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
        if let executionContextID = remoteObject.injectedScriptID {
            let snapshot = dom.snapshot()
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
        elementPickerGeneration &+= 1
        elementPickerTargetID = nil
        elementPickerAcceptsInspectEvents = false
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
        InspectorRuntimeLog.warning(message)
    }

    private func isElementPickerSession(generation: UInt64, targetID: ProtocolTargetIdentifier) -> Bool {
        isSelectingElement && elementPickerGeneration == generation && elementPickerTargetID == targetID
    }

    private func isCurrentElementPicker(generation: UInt64, targetID: ProtocolTargetIdentifier) -> Bool {
        isElementPickerSession(generation: generation, targetID: targetID) && elementPickerAcceptsInspectEvents
    }

    private func completeElementPicker(generation: UInt64, targetID: ProtocolTargetIdentifier) async {
        guard isCurrentElementPicker(generation: generation, targetID: targetID) else {
            return
        }
        clearElementPickerState()
        guard let intent = dom.setInspectModeEnabledIntent(targetID: targetID, enabled: false) else {
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
            return activeHandle
        }
        guard let intent = dom.getDocumentIntent(targetID: targetID) else {
            return nil
        }

        let targetKind = dom.targetKind(for: targetID)
        let handle = DOMDocumentRequestHandle(targetID: targetID, targetKind: targetKind)
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
                let result = try await connection.transport.send(command)
                try Task.checkCancellation()
                try ensureCurrentConnection(connection)
                guard domDocumentRequestHandlesByTargetID[targetID] === handle else {
                    return
                }
                try applyGetDocumentResult(result)
                lastError = nil
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if handle.targetKind == .frame, shouldIgnoreFrameTargetLifecycleError(error) {
                    return
                }
                InspectorRuntimeLog.error("getDocument.failed target=\(targetID.rawValue) reason=\(reason) error=\(error)")
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
        syncTargets(for: connection)
        if connection.targets.target(for: targetID)?.isBootstrapped == true {
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
        guard let targetID = event.targetID ?? dom.currentPageTargetID else {
            return
        }
        let activeRequest = domDocumentRequestHandlesByTargetID[targetID]
        let targetKind = dom.targetKind(for: targetID) ?? activeRequest?.targetKind
        let isCurrentPageTarget = dom.currentPageTargetID == targetID
        let hasCurrentDocument = dom.currentDocumentID(for: targetID) != nil
        let hasActiveFrameDocumentRequest = targetKind == .frame && activeRequest != nil
        guard hasCurrentDocument || isCurrentPageTarget || hasActiveFrameDocumentRequest else {
            return
        }

        dom.invalidateDocument(targetID: targetID)
        if targetKind == .frame {
            startDOMDocumentRequest(targetID: targetID, force: true, reason: "frameDocumentUpdated")
            return
        }

        cancelDOMDocumentRequest(targetID: targetID, reason: "documentUpdated")
    }

    private func cancelDOMDocumentRequest(targetID: ProtocolTargetIdentifier, reason: String) {
        guard let handle = domDocumentRequestHandlesByTargetID.removeValue(forKey: targetID) else {
            return
        }
        handle.task?.cancel()
    }

    private func cancelDOMDocumentRequests() {
        for handle in domDocumentRequestHandlesByTargetID.values {
            handle.task?.cancel()
        }
        domDocumentRequestHandlesByTargetID.removeAll()
    }

    private func cancelCSSActionRequests() {
        cancelSelectedNodeStyleHydrationRefresh()

        for task in cssPropertyUpdateTasks.values {
            task.cancel()
        }
        cssPropertyUpdateTasks.removeAll()
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

    private func clearOwnerHydrationTransaction(for intent: DOMCommandIntent) {
        guard case let .requestChildNodes(targetID, _, _) = intent else {
            return
        }
        dom.clearOwnerHydrationTransactions(targetID: targetID)
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
        guard dom.targetKind(for: targetID) != nil else {
            return
        }
        try DOMTransportAdapter.applyGetDocumentResult(result, to: dom)
        css.removeStyles(targetID: targetID)
        startPendingFrameOwnerHydration()
        lastError = nil
    }

    private var currentAppliedDOMSequence: UInt64 {
        connection?.eventPump?.appliedSequence ?? 0
    }

    private func applyElementPickerTargetLifecycle(
        _ event: ProtocolEventEnvelope,
        targetCommit: DOMTransportAdapter.TargetCommitResolution?
    ) {
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

    private func registerUndoDelete(_ state: DOMDeleteUndoState, undoManager: UndoManager) {
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

    private func registerRedoDelete(_ state: DOMDeleteUndoState, undoManager: UndoManager) {
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
        _ states: [DOMDeleteUndoState],
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
        deleteUndoOperationQueue.enqueue(operation)
    }

    private func performUndoDelete(_ state: DOMDeleteUndoState, undoManager: UndoManager, generation: UInt64) async {
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
            try await reloadDOMDocument(targetID: state.documentTargetID)
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

    private func performRedoDelete(_ state: DOMDeleteUndoState, undoManager: UndoManager, generation: UInt64) async {
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
            try await reloadDOMDocument(targetID: state.documentTargetID)
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
        deleteUndoOperationQueue.isCurrent(generation)
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
        lastError = InspectorSessionError(String(describing: error))
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
        deleteUndoOperationQueue.invalidate()
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
        for record in snapshot.executionContextsByKey.values.sorted(by: RuntimeExecutionContextRecord.stableOrder) {
            dom.applyExecutionContextCreated(record)
        }
    }

    private func seedRuntimeSession(from snapshot: TransportSnapshot) {
        for record in snapshot.targetsByID.values.sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            runtime.applyTargetCreated(record)
        }
        for record in snapshot.executionContextsByKey.values.sorted(by: RuntimeExecutionContextRecord.stableOrder) {
            runtime.applyExecutionContextCreated(record)
        }
    }

    private func syncTargets(for connection: InspectorConnection) {
        connection.targets.sync(from: dom.snapshot())
    }

    private func activeConnection() throws -> InspectorConnection {
        guard isAttached,
              let connection else {
            throw InspectorSessionError("Inspector session is not attached.")
        }
        return connection
    }

    private func ensureCurrentConnection(_ candidate: InspectorConnection) throws {
        guard isCurrentConnection(candidate) else {
            throw TransportError.transportClosed
        }
    }

    private func isCurrentConnection(_ candidate: InspectorConnection) -> Bool {
        connection === candidate || pendingConnection === candidate
    }

    package static func prepareInspectability(for webView: WKWebView) -> Bool {
        let originalValue = webView.isInspectable
        webView.isInspectable = true
        return originalValue
    }

    package static func restoreInspectabilityIfNeeded(on webView: WKWebView, originalValue: Bool?) {
        guard let originalValue else {
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
        var messageStartIndex = 0
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
            guard $0.messageStartIndex < $0.messages.count else {
                $0.messages.removeAll(keepingCapacity: true)
                $0.messageStartIndex = 0
                $0.isDraining = false
                return nil
            }

            let message = $0.messages[$0.messageStartIndex]
            $0.messageStartIndex += 1
            compactMessagesIfNeeded(in: &$0)
            return ($0.transport, message)
        }
    }

    private func compactMessagesIfNeeded(in state: inout State) {
        if state.messageStartIndex == state.messages.count {
            state.messages.removeAll(keepingCapacity: true)
            state.messageStartIndex = 0
        } else if state.messageStartIndex >= 64 && state.messageStartIndex * 2 >= state.messages.count {
            state.messages.removeFirst(state.messageStartIndex)
            state.messageStartIndex = 0
        }
    }
}

private struct RequestNodeResultPayload: Decodable {
    var nodeId: DOMProtocolNodeID
}
