import Foundation
import Observation
import WebKit
import WebInspectorTransport

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
private final class InspectorTargetLifecycleState {
    private(set) var isBootstrapped = false
    private var enabledDomains: ProtocolTargetCapabilities
    private var runtimeConsoleEnableTask: Task<Void, Never>?
    private var runtimeConsoleEnableTaskWaiters: [CheckedContinuation<Void, Never>]

    init() {
        enabledDomains = []
        runtimeConsoleEnableTask = nil
        runtimeConsoleEnableTaskWaiters = []
    }

    func markBootstrapped() {
        isBootstrapped = true
    }

    func markEnabled(_ domain: ProtocolTargetCapabilities) {
        enabledDomains.insert(domain)
    }

    func hasEnabled(_ domain: ProtocolTargetCapabilities) -> Bool {
        enabledDomains.contains(domain)
    }

    func shouldEnable(_ domain: ProtocolTargetCapabilities, capabilities: ProtocolTargetCapabilities, force: Bool = false) -> Bool {
        capabilities.contains(domain)
            && (force || hasEnabled(domain) == false)
    }

    func canStartRuntimeConsoleEnable(needsRuntime: Bool, needsConsole: Bool) -> Bool {
        runtimeConsoleEnableTask == nil
            && (needsRuntime || needsConsole)
    }

    func startRuntimeConsoleEnableTask(_ task: Task<Void, Never>) {
        runtimeConsoleEnableTask = task
    }

    func finishRuntimeConsoleEnableTask() {
        runtimeConsoleEnableTask = nil
        resumeRuntimeConsoleEnableTaskWaiters()
    }

    func cancelRuntimeConsoleEnableTask() {
        runtimeConsoleEnableTask?.cancel()
        runtimeConsoleEnableTask = nil
        resumeRuntimeConsoleEnableTaskWaiters()
    }

    func waitUntilRuntimeConsoleEnableTaskFinished() async {
        guard runtimeConsoleEnableTask != nil else {
            return
        }
        await withCheckedContinuation { continuation in
            if runtimeConsoleEnableTask == nil {
                continuation.resume()
            } else {
                runtimeConsoleEnableTaskWaiters.append(continuation)
            }
        }
    }

    private func resumeRuntimeConsoleEnableTaskWaiters() {
        let waiters = runtimeConsoleEnableTaskWaiters
        runtimeConsoleEnableTaskWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
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
    private let lifecycle: InspectorTargetLifecycleState

    init(snapshot: ProtocolTargetSnapshot) {
        id = snapshot.id
        kind = snapshot.kind
        frameID = snapshot.frameID
        parentFrameID = snapshot.parentFrameID
        capabilities = snapshot.capabilities
        isProvisional = snapshot.isProvisional
        isPaused = snapshot.isPaused
        lifecycle = InspectorTargetLifecycleState()
    }

    var isBootstrapped: Bool {
        lifecycle.isBootstrapped
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

    func markBootstrapped() {
        lifecycle.markBootstrapped()
    }

    func markEnabled(_ domain: ProtocolTargetCapabilities) {
        lifecycle.markEnabled(domain)
    }

    func shouldEnableCompatibilityCSS() -> Bool {
        hasDomain(.css) && lifecycle.hasEnabled(.css) == false
    }

    func shouldEnableRuntime(using runtime: RuntimeState) -> Bool {
        isProvisional == false
            && lifecycle.shouldEnable(.runtime, capabilities: capabilities)
            && runtime.supportsCommand("Runtime.enable", targetID: id)
    }

    func shouldEnableConsole(using console: ConsoleSession, force: Bool = false) -> Bool {
        isProvisional == false
            && lifecycle.shouldEnable(.console, capabilities: capabilities, force: force)
            && console.supportsCommand("Console.enable", targetID: id)
    }

    func canStartRuntimeConsoleEnable(using runtime: RuntimeState, console: ConsoleSession) -> Bool {
        lifecycle.canStartRuntimeConsoleEnable(
            needsRuntime: shouldEnableRuntime(using: runtime),
            needsConsole: shouldEnableConsole(using: console)
        )
    }

    func startRuntimeConsoleEnableTask(_ task: Task<Void, Never>) {
        lifecycle.startRuntimeConsoleEnableTask(task)
    }

    func finishRuntimeConsoleEnableTask() {
        lifecycle.finishRuntimeConsoleEnableTask()
    }

    func cancelRuntimeConsoleEnableTask() {
        lifecycle.cancelRuntimeConsoleEnableTask()
    }

    func waitUntilRuntimeConsoleEnableTaskFinished() async {
        await lifecycle.waitUntilRuntimeConsoleEnableTaskFinished()
    }
}

@MainActor
private final class InspectorTargetRegistry {
    private var targetsByID: [ProtocolTargetIdentifier: InspectorTarget] = [:]

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

    func waitUntilRuntimeConsoleEnableTaskFinished(targetID: ProtocolTargetIdentifier) async -> Bool {
        guard let target = targetsByID[targetID] else {
            return false
        }
        await target.waitUntilRuntimeConsoleEnableTaskFinished()
        return true
    }
}

@MainActor
package protocol InspectorInspectableWebView: AnyObject {
    var isInspectable: Bool { get set }
}

extension WKWebView: InspectorInspectableWebView {}

@MainActor
private final class InspectorConnection {
    let transport: TransportSession
    let receiver: TransportReceiver?
    weak var webView: WKWebView?
    let originalInspectability: Bool?
    var eventPump: DomainEventPump?
    let targets: InspectorTargetRegistry

    init(
        transport: TransportSession,
        receiver: TransportReceiver? = nil,
        webView: WKWebView? = nil,
        originalInspectability: Bool? = nil
    ) {
        self.transport = transport
        self.receiver = receiver
        self.webView = webView
        self.originalInspectability = originalInspectability
        eventPump = nil
        targets = InspectorTargetRegistry()
    }
}

@MainActor
private enum InspectorConnectionPhase {
    case idle
    case pending(InspectorConnection)
    case active(InspectorConnection)

    var activeConnection: InspectorConnection? {
        guard case let .active(connection) = self else {
            return nil
        }
        return connection
    }

    var pendingConnection: InspectorConnection? {
        guard case let .pending(connection) = self else {
            return nil
        }
        return connection
    }

    var connectionsForDetach: [InspectorConnection] {
        switch self {
        case .idle:
            []
        case let .pending(connection), let .active(connection):
            [connection]
        }
    }

    var hasAnyConnection: Bool {
        connectionsForDetach.isEmpty == false
    }

    func isCurrent(_ candidate: InspectorConnection) -> Bool {
        switch self {
        case .idle:
            false
        case let .pending(connection), let .active(connection):
            connection === candidate
        }
    }

    func isAttached(_ candidate: InspectorConnection) -> Bool {
        guard case let .active(connection) = self else {
            return false
        }
        return connection === candidate
    }
}

@MainActor
@Observable
package final class AttachedInspection {
    package let targetGraph: TargetGraph
    package let dom: DOMSession
    package let network: NetworkSession
    package let runtime: RuntimeState
    package let console: ConsoleSession

    package init(
        targetGraph: TargetGraph = TargetGraph(),
        elementStyles: CSSSession = CSSSession(),
        network: NetworkSession = NetworkSession(),
        runtime: RuntimeState = RuntimeState(),
        console: ConsoleSession = ConsoleSession()
    ) {
        self.targetGraph = targetGraph
        self.dom = DOMSession(targetGraph: targetGraph, elementStyles: elementStyles)
        self.network = network
        self.runtime = runtime
        self.console = console
    }

    package init(
        targetGraph: TargetGraph = TargetGraph(),
        dom: DOMSession,
        network: NetworkSession = NetworkSession(),
        runtime: RuntimeState = RuntimeState(),
        console: ConsoleSession = ConsoleSession()
    ) {
        self.targetGraph = targetGraph
        self.dom = dom
        self.network = network
        self.runtime = runtime
        self.console = console
    }

    package func reset() {
        dom.reset()
        network.reset()
        runtime.reset()
        console.reset()
    }
}

@MainActor
@Observable
package final class InspectorSession {
    package let attachment: AttachedInspection
    package var hasActiveConnection: Bool {
        connectionPhase.activeConnection != nil
    }
    package private(set) var lastError: InspectorSessionError?

    @ObservationIgnored private let configuration: InspectorSessionConfiguration
    @ObservationIgnored private var connectionPhase: InspectorConnectionPhase
    @ObservationIgnored private var protocolEventDispatchers: ProtocolDomainEventDispatcherRegistry

    private var connection: InspectorConnection? {
        connectionPhase.activeConnection
    }

    private var pendingConnection: InspectorConnection? {
        connectionPhase.pendingConnection
    }

    private var targetGraph: TargetGraph {
        attachment.targetGraph
    }

    private var dom: DOMSession {
        attachment.dom
    }

    private var network: NetworkSession {
        attachment.network
    }

    private var runtime: RuntimeState {
        attachment.runtime
    }

    private var console: ConsoleSession {
        attachment.console
    }

    package init(
        configuration: InspectorSessionConfiguration = .init(),
        attachment: AttachedInspection? = nil
    ) {
        self.configuration = configuration
        let resolvedAttachment = attachment ?? AttachedInspection()
        self.attachment = resolvedAttachment
        protocolEventDispatchers = ProtocolDomainEventDispatcherRegistry()
        lastError = nil
        connectionPhase = .idle
        configureProtocolEventDispatchers()
    }

    package init(
        configuration: InspectorSessionConfiguration = .init(),
        targetGraph: TargetGraph = TargetGraph(),
        elementStyles: CSSSession = CSSSession(),
        network: NetworkSession = NetworkSession(),
        runtime: RuntimeState = RuntimeState(),
        console: ConsoleSession = ConsoleSession()
    ) {
        self.configuration = configuration
        let attachment = AttachedInspection(
            targetGraph: targetGraph,
            elementStyles: elementStyles,
            network: network,
            runtime: runtime,
            console: console
        )
        self.attachment = attachment
        protocolEventDispatchers = ProtocolDomainEventDispatcherRegistry()
        lastError = nil
        connectionPhase = .idle
        configureProtocolEventDispatchers()
    }

    package init(
        configuration: InspectorSessionConfiguration = .init(),
        targetGraph: TargetGraph = TargetGraph(),
        dom: DOMSession,
        network: NetworkSession = NetworkSession(),
        runtime: RuntimeState = RuntimeState(),
        console: ConsoleSession = ConsoleSession()
    ) {
        self.configuration = configuration
        let attachment = AttachedInspection(
            targetGraph: targetGraph,
            dom: dom,
            network: network,
            runtime: runtime,
            console: console
        )
        self.attachment = attachment
        protocolEventDispatchers = ProtocolDomainEventDispatcherRegistry()
        lastError = nil
        connectionPhase = .idle
        configureProtocolEventDispatchers()
    }

    private func configureProtocolEventDispatchers() {
        protocolEventDispatchers = ProtocolDomainEventDispatcherRegistry([
            TargetProtocolDomainEventDispatcher(dom: attachment.dom) { [weak self] event, result in
                await self?.handleAppliedTargetEvent(event, result: result)
            },
            RuntimeProtocolEventDispatcher(handlers: [attachment.runtime, attachment.dom]),
            ConsoleProtocolEventDispatcher(handler: attachment.console, runtime: attachment.runtime),
            DOMProtocolEventDispatcher(session: attachment.dom),
            InspectorProtocolEventDispatcher(session: attachment.dom),
            CSSProtocolEventDispatcher(handler: attachment.dom),
            NetworkProtocolEventDispatcher(session: attachment.network),
        ])
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
                receiver: receiver,
                webView: webView,
                originalInspectability: originalInspectability
            )
        } catch {
            receiver.close()
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
        receiver: TransportReceiver? = nil,
        webView: WKWebView?,
        originalInspectability: Bool?
    ) async throws {
        await detach()
        let nextConnection = InspectorConnection(
            transport: transport,
            receiver: receiver,
            webView: webView,
            originalInspectability: originalInspectability
        )
        connectionPhase = .pending(nextConnection)
        bindProtocolChannel(for: nextConnection)
        lastError = nil
        await startPumps(connection: nextConnection)
        seedDOMSession(from: await transport.snapshot())
        seedRuntimeState(from: await transport.snapshot())
        syncTargets(for: nextConnection)

        do {
            let mainTarget = try await transport.waitForCurrentMainPageTarget(
                timeout: configuration.bootstrapTimeout
            )
            seedDOMSession(from: await transport.snapshot())
            seedRuntimeState(from: await transport.snapshot())
            syncTargets(for: nextConnection)
            try await bootstrap(mainTargetID: mainTarget.targetID, connection: nextConnection)
            try ensureCurrentConnection(nextConnection)
            connectionPhase = .active(nextConnection)
            dom.startDocumentRequestsForAttachedFrameTargets()
            startRuntimeConsoleEnableForAttachedTargets()
            lastError = nil
        } catch {
            guard connectionPhase.isCurrent(nextConnection) else {
                throw error
            }
            nextConnection.receiver?.close()
            stopPumps(nextConnection)
            connectionPhase = .idle
            await transport.detach()
            restoreInspectabilityIfNeeded(for: nextConnection)
            unbindProtocolChannel()
            dom.reset()
            network.reset()
            runtime.reset()
            console.reset()
            let sessionError = InspectorSessionError(String(describing: error))
            lastError = sessionError
            throw error
        }
    }

    package func detach() async {
        guard connectionPhase.hasAnyConnection else {
            return
        }

        let previousConnections = connectionPhase.connectionsForDetach
        connectionPhase = .idle
        unbindProtocolChannel()

        for previousConnection in previousConnections {
            cancelRuntimeConsoleEnableTasks(previousConnection)
            previousConnection.receiver?.close()
            stopPumps(previousConnection)
            await previousConnection.transport.detach()
            restoreInspectabilityIfNeeded(for: previousConnection)
        }
        dom.reset()
        network.reset()
        runtime.reset()
        console.reset()
        lastError = nil
    }

    package var hasInspectablePageWebView: Bool {
        connection?.webView != nil
    }

    package func reloadPage() async throws {
        let webView = try requireInspectableWebView()
        await dom.prepareForPageReload()
        dom.reset()
        network.reset()
        runtime.reset()
        console.reset()
        if let connection {
            seedDOMSession(from: await connection.transport.snapshot())
            seedRuntimeState(from: await connection.transport.snapshot())
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

    package func waitUntilRuntimeConsoleEnableFinished(targetID: ProtocolTargetIdentifier) async -> Bool {
        guard let connection else {
            return false
        }
        return await connection.targets.waitUntilRuntimeConsoleEnableTaskFinished(targetID: targetID)
    }

    private func bootstrap(mainTargetID: ProtocolTargetIdentifier, connection: InspectorConnection) async throws {
        _ = try await sendTargetCommand(domain: ProtocolDomain.inspector, method: "Inspector.enable", targetID: mainTargetID, connection: connection)
        try ensureCurrentConnection(connection)
        _ = try await sendTargetCommand(domain: ProtocolDomain.inspector, method: "Inspector.initialized", targetID: mainTargetID, connection: connection)
        try ensureCurrentConnection(connection)
        _ = try await sendTargetCommand(domain: ProtocolDomain.dom, method: "DOM.enable", targetID: mainTargetID, connection: connection)
        try ensureCurrentConnection(connection)
        try await runtime.enableDuringBootstrap(targetID: mainTargetID)
        try ensureCurrentConnection(connection)
        syncTargets(for: connection)
        connection.targets.target(for: mainTargetID)?.markEnabled(.runtime)

        _ = try await dom.performDuringBootstrap(.getDocument(targetID: mainTargetID))
        try ensureCurrentConnection(connection)

        _ = try await sendTargetCommand(
            domain: ProtocolDomain.network,
            method: "Network.enable",
            targetID: mainTargetID,
            routing: ProtocolCommandRouting.octopus(pageTarget: mainTargetID),
            connection: connection
        )
        try ensureCurrentConnection(connection)
        try await enableConsoleAgentIfSupported(
            targetID: mainTargetID,
            connection: connection,
            force: true,
            requiresActiveConnection: false
        )
        connection.targets.target(for: mainTargetID)?.markBootstrapped()
    }

    private func sendTargetCommand(
        domain: ProtocolDomain,
        method: String,
        targetID: ProtocolTargetIdentifier,
        routing: ProtocolCommandRouting? = nil,
        connection: InspectorConnection
    ) async throws -> ProtocolCommandResult {
        try await connection.transport.send(
            ProtocolCommand(
                domain: domain,
                method: method,
                routing: routing ?? ProtocolCommandRouting.target(targetID)
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

    private func stopPumps(_ connection: InspectorConnection) {
        connection.eventPump?.stop()
        connection.eventPump = nil
    }

    private func handleProtocolEvent(_ event: ProtocolEventEnvelope) async {
        do {
            _ = try await protocolEventDispatchers.dispatch(event)
        } catch {
            lastError = InspectorSessionError("\(event.method): \(error)")
        }
    }

    private func handleAppliedTargetEvent(
        _ event: ProtocolEventEnvelope,
        result: TargetProtocolEventResult
    ) async {
        if let createdTarget = result.createdTarget {
            runtime.applyTargetCreated(createdTarget)
        }
        if let connection {
            syncTargets(for: connection)
        }
        if let destroyedTargetID = result.destroyedTargetID {
            cancelRuntimeConsoleEnableTask(targetID: destroyedTargetID)
            runtime.applyTargetDestroyed(destroyedTargetID)
            console.applyTargetDestroyed(destroyedTargetID)
            discardConnectionTargetState(targetID: destroyedTargetID)
        }
        if hasActiveConnection,
           let createdTarget = result.createdTarget {
            if createdTarget.kind == .frame,
               createdTarget.capabilities.contains(ProtocolTargetCapabilities.dom) {
                dom.startFrameTargetDocumentRequestIfNeeded(targetID: createdTarget.id, reason: "frameTargetCreated")
            }
            startRuntimeConsoleEnableIfNeeded(targetID: createdTarget.id, reason: "targetCreated")
        }
        if event.method == "Target.didCommitProvisionalTarget",
           dom.currentPageRootNode == nil,
           let targetID = dom.currentPageTargetID,
           let connection {
            syncTargets(for: connection)
            let isBootstrapped = connection.targets.target(for: targetID)?.isBootstrapped == true
            dom.startPageTargetDocumentRequestAfterCommit(targetID: targetID, isBootstrapped: isBootstrapped) { [weak self, weak connection] in
                guard let self, let connection else {
                    return
                }
                try await self.bootstrap(mainTargetID: targetID, connection: connection)
            }
        }
        if event.method == "Target.didCommitProvisionalTarget",
           let targetCommit = result.targetCommit {
            if let committedTarget = dom.snapshot().targetsByID[targetCommit.newTargetID] {
                runtime.applyTargetCreated(committedTarget.record)
            }
            if let oldTargetID = targetCommit.consumedOldTargetID {
                cancelRuntimeConsoleEnableTask(targetID: oldTargetID)
                runtime.applyTargetCommitted(oldTargetID: oldTargetID, newTargetID: targetCommit.newTargetID)
                console.applyTargetCommitted(oldTargetID: oldTargetID, newTargetID: targetCommit.newTargetID)
                discardConnectionTargetState(targetID: oldTargetID)
            }
            dom.startFrameTargetDocumentRequestIfNeeded(targetID: targetCommit.newTargetID, reason: "frameTargetCommit")
            startRuntimeConsoleEnableIfNeeded(targetID: targetCommit.newTargetID, reason: "frameTargetCommit")
        }
    }

    private func startRuntimeConsoleEnableForAttachedTargets() {
        for target in dom.snapshot().targetsByID.values where target.isProvisional == false {
            startRuntimeConsoleEnableIfNeeded(targetID: target.id, reason: "attachedTarget")
        }
    }

    private func startRuntimeConsoleEnableIfNeeded(targetID: ProtocolTargetIdentifier, reason: String) {
        guard hasActiveConnection,
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
                try await runtime.enable(targetID: targetID)
                try ensureCurrentConnection(connection)
                target.markEnabled(.runtime)
            } catch {
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
        force: Bool = false,
        requiresActiveConnection: Bool = true
    ) async throws {
        syncTargets(for: connection)
        guard let target = connection.targets.target(for: targetID),
              target.shouldEnableConsole(using: console, force: force) else {
            return
        }
        do {
            if requiresActiveConnection {
                try await console.enable(targetID: targetID)
            } else {
                try await console.enableDuringBootstrap(targetID: targetID)
            }
            try ensureCurrentConnection(connection)
            target.markEnabled(.console)
        } catch {
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

    private func requireInspectableWebView() throws -> WKWebView {
        guard let webView = connection?.webView else {
            throw InspectorSessionError("Inspector session is not attached to a WKWebView.")
        }
        return webView
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

    private func seedRuntimeState(from snapshot: TransportSnapshot) {
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

    private func bindProtocolChannel(for connection: InspectorConnection) {
        let channel = ProtocolCommandChannel(
            transport: connection.transport,
            isCurrent: { [weak self, weak connection] in
                guard let self, let connection else {
                    return false
                }
                return self.isCurrentConnection(connection)
            },
            isAttached: { [weak self, weak connection] in
                guard let self, let connection else {
                    return false
                }
                return self.connectionPhase.isAttached(connection)
            },
            appliedSequence: { [weak connection] in
                connection?.eventPump?.appliedSequence ?? 0
            },
            shouldEnableCompatibilityCSS: { [weak self, weak connection] targetID in
                guard let self, let connection else {
                    return false
                }
                self.syncTargets(for: connection)
                return connection.targets.target(for: targetID)?.shouldEnableCompatibilityCSS() ?? false
            },
            markTargetDomainEnabled: { [weak connection] targetID, domain in
                connection?.targets.target(for: targetID)?.markEnabled(domain)
            }
        )
        let recordError: (InspectorSessionError?) -> Void = { [weak self] error in
            self?.lastError = error
        }
        dom.bindProtocolChannel(channel, recordError: recordError)
        network.bindProtocolChannel(channel, recordError: recordError)
        runtime.bindProtocolChannel(channel, recordError: recordError)
        console.bindProtocolChannel(channel, recordError: recordError)
    }

    private func unbindProtocolChannel() {
        dom.unbindProtocolChannel()
        network.unbindProtocolChannel()
        runtime.unbindProtocolChannel()
        console.unbindProtocolChannel()
    }

    private func ensureCurrentConnection(_ candidate: InspectorConnection) throws {
        guard isCurrentConnection(candidate) else {
            throw TransportError.transportClosed
        }
    }

    private func isCurrentConnection(_ candidate: InspectorConnection) -> Bool {
        connectionPhase.isCurrent(candidate)
    }

    package static func prepareInspectability<WebView: InspectorInspectableWebView>(for webView: WebView) -> Bool {
        let originalValue = webView.isInspectable
        webView.isInspectable = true
        return originalValue
    }

    package static func restoreInspectabilityIfNeeded<WebView: InspectorInspectableWebView>(
        on webView: WebView,
        originalValue: Bool?
    ) {
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
