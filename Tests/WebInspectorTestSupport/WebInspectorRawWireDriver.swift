import Foundation
import Synchronization
import Testing
import WebInspectorProxyKitTesting

/// Scripted replies and command observations layered on the public raw peer.
///
/// This test-only coordinator never injects event sequences, generations, or
/// target membership. Every command still traverses ProxyKit's production
/// connection core and receives exactly one raw peer reply or failure.
public actor WebInspectorRawWireDriver {
    /// Immutable command snapshots and lifecycle-safe asynchronous waiters.
    ///
    /// This value owns only the driver's observation broker. Suspending on it
    /// never retains the driver actor, so dropping the actor finishes pending
    /// waiters with the commands observed so far.
    public struct Observations: Sendable {
        fileprivate let broker: WebInspectorRawCommandObservationBroker

        fileprivate init(broker: WebInspectorRawCommandObservationBroker) {
            self.broker = broker
        }

        public var commands: [WebInspectorTestPeer.Command] {
            broker.recordedCommands()
        }

        public var commandMethods: [String] {
            commands.map(\.method)
        }

        public func waitForCommands(
            method: String,
            count: Int
        ) async -> [WebInspectorTestPeer.Command] {
            await broker.waitForCommands(method: method, count: count)
        }

        /// Waits until Core drains the matching replies or failures.
        public func waitForCompletedCommands(
            method: String,
            count: Int
        ) async -> [WebInspectorTestPeer.Command] {
            await broker.waitForCompletedCommands(method: method, count: count)
        }

        public var pendingWaiterCountForTesting: Int {
            broker.pendingWaiterCount
        }
    }

    private enum Response: Sendable {
        case result(WebInspectorTestJSONObject)
        case failure(code: Int?, message: String)
        indirect case deferred(UUID, WebInspectorTestGate.Waiter, Response)
    }

    private let peer: WebInspectorTestPeer
    private nonisolated let observationBroker: WebInspectorRawCommandObservationBroker
    public nonisolated let observations: Observations
    private var responses: [String: [Response]] = [:]
    private var gates: [UUID: WebInspectorTestGate] = [:]
    private var task: Task<Void, Never>?
    private var replyTasks: [UUID: Task<Void, Never>] = [:]
    private var hasStarted = false

    public init(peer: WebInspectorTestPeer) {
        let observationBroker = WebInspectorRawCommandObservationBroker()
        self.peer = peer
        self.observationBroker = observationBroker
        observations = Observations(broker: observationBroker)
    }

    isolated deinit {
        // Awaited gate cancellation and peer shutdown belong to stop(). The
        // external observation broker makes this synchronous backstop
        // reachable even while clients are suspended waiting for commands.
        task?.cancel()
        for replyTask in replyTasks.values {
            replyTask.cancel()
        }
        observationBroker.finish()
    }

    public func start() {
        precondition(!hasStarted, "WebInspectorRawWireDriver can start only once.")
        hasStarted = true
        let commands = peer.commands
        task = Self.makeConsumerTask(commands: commands, driver: self)
    }

    private nonisolated static func makeConsumerTask(
        commands: WebInspectorTestPeer.Commands,
        driver: WebInspectorRawWireDriver
    ) -> Task<Void, Never> {
        Task { [weak driver] in
            while !Task.isCancelled {
                do {
                    let command = try await commands.next()
                    guard !Task.isCancelled else {
                        return
                    }
                    guard let driver else {
                        return
                    }
                    await driver.scheduleReply(for: command)
                } catch is CancellationError {
                    return
                } catch WebInspectorTestPeerError.connectionClosed {
                    return
                } catch {
                    Issue.record("Raw Web Inspector wire driver failed: \(error)")
                    return
                }
            }
        }
    }

    public func respond(
        to method: String,
        with result: WebInspectorTestJSONObject = .empty
    ) {
        enqueue(.result(result), for: method)
    }

    public func fail(
        _ method: String,
        code: Int? = nil,
        message: String
    ) {
        enqueue(.failure(code: code, message: message), for: method)
    }

    public func deferReply(
        to method: String,
        with result: WebInspectorTestJSONObject = .empty
    ) -> WebInspectorTestGate {
        deferResponse(.result(result), to: method)
    }

    public func deferFailure(
        to method: String,
        code: Int? = nil,
        message: String
    ) -> WebInspectorTestGate {
        deferResponse(.failure(code: code, message: message), to: method)
    }

    public func emitRootEvent(
        method: String,
        parameters: WebInspectorTestJSONObject = .empty
    ) async throws {
        try await peer.emitRootEvent(method: method, parameters: parameters)
    }

    public func emitTargetEvent(
        targetID: String,
        method: String,
        parameters: WebInspectorTestJSONObject = .empty
    ) async throws {
        try await peer.emitTargetEvent(
            targetID: targetID,
            method: method,
            parameters: parameters
        )
    }

    public func stop() async {
        let runningTask = task
        task = nil
        runningTask?.cancel()
        let activeGates = gates.values
        gates.removeAll(keepingCapacity: false)
        for gate in activeGates {
            gate.cancel()
        }
        let activeReplyTasks = Array(replyTasks.values)
        replyTasks.removeAll(keepingCapacity: false)
        for replyTask in activeReplyTasks {
            replyTask.cancel()
        }
        await runningTask?.value
        for replyTask in activeReplyTasks {
            await replyTask.value
        }
        observationBroker.finish()
    }

    private func scheduleReply(for command: WebInspectorTestPeer.Command) {
        guard task != nil else {
            return
        }
        observationBroker.record(command)
        let method = command.method
        let response: Response
        if var queued = responses[method], !queued.isEmpty {
            response = queued.removeFirst()
            responses[method] = queued.isEmpty ? nil : queued
        } else {
            Issue.record("Unexpected raw Web Inspector command: \(method)")
            response = .failure(
                code: nil,
                message: "No raw test reply registered for \(method)."
            )
        }

        let replyID = UUID()
        let peer = self.peer
        replyTasks[replyID] = Self.makeReplyTask(
            peer: peer,
            command: command,
            response: response,
            replyID: replyID,
            driver: self
        )
    }

    private nonisolated static func makeReplyTask(
        peer: WebInspectorTestPeer,
        command: WebInspectorTestPeer.Command,
        response: Response,
        replyID: UUID,
        driver: WebInspectorRawWireDriver
    ) -> Task<Void, Never> {
        Task { [weak driver] in
            do {
                let resolved = try await Self.resolve(response)
                switch resolved {
                case let .result(result):
                    try await peer.reply(to: command, with: result)
                case let .failure(code, message):
                    try await peer.fail(command, code: code, message: message)
                case .deferred:
                    preconditionFailure("Nested deferred raw responses are not supported.")
                }
                await driver?.complete(command)
            } catch is CancellationError {
                // Explicit stop owns cancellation and awaits this task.
            } catch WebInspectorTestPeerError.connectionClosed {
                // Connection teardown is terminal for outstanding replies.
            } catch WebInspectorTestPeerError.staleCommand {
                // Connection teardown invalidated this correlation.
            } catch {
                Issue.record("Raw Web Inspector wire reply failed: \(error)")
            }
            await driver?.finishReply(id: replyID, response: response)
        }
    }

    private nonisolated static func resolve(_ response: Response) async throws -> Response {
        switch response {
        case let .deferred(_, waiter, deferredResponse):
            try await waiter.waitUntilOpen()
            return deferredResponse
        case .result, .failure:
            return response
        }
    }

    private func finishReply(id: UUID, response: Response) {
        if case let .deferred(gateID, _, _) = response {
            gates[gateID] = nil
        }
        replyTasks[id] = nil
    }

    private func enqueue(_ response: Response, for method: String) {
        responses[method, default: []].append(response)
    }

    private func deferResponse(
        _ response: Response,
        to method: String
    ) -> WebInspectorTestGate {
        let gate = WebInspectorTestGate()
        let gateID = UUID()
        gates[gateID] = gate
        enqueue(.deferred(gateID, gate.waiter, response), for: method)
        return gate
    }

    private func complete(_ command: WebInspectorTestPeer.Command) {
        observationBroker.recordCompletion(command)
    }
}

private final class WebInspectorRawCommandObservationBroker: Sendable {
    private enum Collection: Sendable {
        case received
        case completed
    }

    private struct Waiter: Sendable {
        let id: UInt64
        let collection: Collection
        let method: String
        let count: Int
        let continuation: CheckedContinuation<[WebInspectorTestPeer.Command], Never>
    }

    private struct State: Sendable {
        var received: [WebInspectorTestPeer.Command] = []
        var completed: [WebInspectorTestPeer.Command] = []
        var waiters: [Waiter] = []
        var registeringWaiterIDs: Set<UInt64> = []
        var nextWaiterID: UInt64 = 0
        var isFinished = false
    }

    private enum RegistrationAction {
        case wait
        case resume([WebInspectorTestPeer.Command])
    }

    private let state = Mutex(State())

    func recordedCommands() -> [WebInspectorTestPeer.Command] {
        state.withLock { $0.received }
    }

    var pendingWaiterCount: Int {
        state.withLock { $0.waiters.count }
    }

    func record(_ command: WebInspectorTestPeer.Command) {
        append(command, to: .received)
    }

    func recordCompletion(_ command: WebInspectorTestPeer.Command) {
        append(command, to: .completed)
    }

    func waitForCommands(
        method: String,
        count: Int
    ) async -> [WebInspectorTestPeer.Command] {
        await wait(for: .received, method: method, count: count)
    }

    func waitForCompletedCommands(
        method: String,
        count: Int
    ) async -> [WebInspectorTestPeer.Command] {
        await wait(for: .completed, method: method, count: count)
    }

    func finish() {
        let resumptions = state.withLock {
            state -> [(
                continuation: CheckedContinuation<[WebInspectorTestPeer.Command], Never>,
            commands: [WebInspectorTestPeer.Command]
        )] in
            guard !state.isFinished else {
                return []
            }
            state.isFinished = true
            state.registeringWaiterIDs.removeAll(keepingCapacity: false)
            let resumptions = state.waiters.map { waiter in
                (waiter.continuation, Self.matches(for: waiter, in: state))
            }
            state.waiters.removeAll(keepingCapacity: false)
            return resumptions
        }
        for resumption in resumptions {
            resumption.continuation.resume(returning: resumption.commands)
        }
    }

    private func append(
        _ command: WebInspectorTestPeer.Command,
        to collection: Collection
    ) {
        let resumptions = state.withLock {
            state -> [(
                continuation: CheckedContinuation<[WebInspectorTestPeer.Command], Never>,
            commands: [WebInspectorTestPeer.Command]
        )] in
            guard !state.isFinished else {
                return []
            }
            switch collection {
            case .received:
                state.received.append(command)
            case .completed:
                state.completed.append(command)
            }

            var pending: [Waiter] = []
            var resumptions:
                [(
                    continuation: CheckedContinuation<[WebInspectorTestPeer.Command], Never>,
                commands: [WebInspectorTestPeer.Command]
            )] = []
            for waiter in state.waiters {
                let matches = Self.matches(for: waiter, in: state)
                if matches.count >= waiter.count {
                    resumptions.append((waiter.continuation, matches))
                } else {
                    pending.append(waiter)
                }
            }
            state.waiters = pending
            return resumptions
        }
        for resumption in resumptions {
            resumption.continuation.resume(returning: resumption.commands)
        }
    }

    private func wait(
        for collection: Collection,
        method: String,
        count: Int
    ) async -> [WebInspectorTestPeer.Command] {
        precondition(count > 0, "A raw command waiter count must be positive.")
        let waiterID = state.withLock { state -> UInt64 in
            precondition(
                state.nextWaiterID < UInt64.max,
                "The raw command observation broker exhausted its waiter identifier space."
            )
            state.nextWaiterID += 1
            let waiterID = state.nextWaiterID
            state.registeringWaiterIDs.insert(waiterID)
            return waiterID
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let action = state.withLock { state -> RegistrationAction in
                    let matches = Self.matches(
                        collection: collection,
                        method: method,
                        in: state
                    )
                    if state.registeringWaiterIDs.remove(waiterID) == nil
                        || state.isFinished
                        || matches.count >= count
                    {
                        return .resume(matches)
                    }
                    state.waiters.append(
                        Waiter(
                            id: waiterID,
                        collection: collection,
                        method: method,
                        count: count,
                        continuation: continuation
                    ))
                    return .wait
                }
                if case let .resume(commands) = action {
                    continuation.resume(returning: commands)
                }
            }
        } onCancel: {
            let resumption = state.withLock {
                state -> (
                    continuation: CheckedContinuation<[WebInspectorTestPeer.Command], Never>,
                commands: [WebInspectorTestPeer.Command]
            )? in
                guard let index = state.waiters.firstIndex(where: { $0.id == waiterID }) else {
                    state.registeringWaiterIDs.remove(waiterID)
                    return nil
                }
                let waiter = state.waiters.remove(at: index)
                return (waiter.continuation, Self.matches(for: waiter, in: state))
            }
            if let resumption {
                resumption.continuation.resume(returning: resumption.commands)
            }
        }
    }

    private static func matches(
        for waiter: Waiter,
        in state: State
    ) -> [WebInspectorTestPeer.Command] {
        matches(collection: waiter.collection, method: waiter.method, in: state)
    }

    private static func matches(
        collection: Collection,
        method: String,
        in state: State
    ) -> [WebInspectorTestPeer.Command] {
        let commands: [WebInspectorTestPeer.Command]
        switch collection {
        case .received:
            commands = state.received
        case .completed:
            commands = state.completed
        }
        return commands.filter { $0.method == method }
    }
}
