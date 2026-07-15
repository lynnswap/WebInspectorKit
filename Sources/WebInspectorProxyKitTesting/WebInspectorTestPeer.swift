import CoreFoundation
import Foundation
import Synchronization
import WebInspectorProxyKit

/// Errors produced by the raw Web Inspector test peer.
public enum WebInspectorTestPeerError: Error, Equatable, Sendable {
    /// A JSON fixture was invalid or its top-level value was not an object.
    case invalidJSONObject

    /// ProxyKit emitted a malformed protocol command.
    case malformedOutboundCommand

    /// The simulated connection is no longer open.
    case connectionClosed

    /// The command was created by another peer.
    case foreignCommand

    /// The command belonged to this peer before its connection terminated.
    case staleCommand

    /// The command has already received its one reply or failure.
    case commandAlreadyCompleted
}

/// A concrete raw-wire WebKit peer for ProxyKit and DataKit tests.
///
/// The peer implements only the transport boundary. Commands and events still
/// pass through ProxyKit's production connection core, registry, router, JSON
/// codecs, reply boundaries, and capability leases.
public actor WebInspectorTestPeer {
    /// One outbound Web Inspector protocol command.
    public struct Command: Equatable, Sendable {
        /// An opaque command correlation owned by one peer connection.
        public struct Correlation: Hashable, Sendable {
            fileprivate let peerID: UUID
            fileprivate let ordinal: UInt64

            fileprivate init(peerID: UUID, ordinal: UInt64) {
                self.peerID = peerID
                self.ordinal = ordinal
            }
        }

        /// The wire destination selected by ProxyKit.
        public enum Destination: Equatable, Sendable {
            /// The root inspector connection.
            case root

            /// A physical WebKit target identifier.
            case target(String)
        }

        /// The opaque correlation used by ``WebInspectorTestPeer/reply(to:with:)``
        /// and ``WebInspectorTestPeer/fail(_:message:)``.
        public let correlation: Correlation

        /// The root or target wire destination.
        public let destination: Destination

        /// The raw Web Inspector protocol method, such as `DOM.getDocument`.
        public let method: String

        /// The validated protocol `params` object.
        public let parameters: WebInspectorTestJSONObject

        fileprivate init(
            correlation: Correlation,
            destination: Destination,
            method: String,
            parameters: WebInspectorTestJSONObject
        ) {
            self.correlation = correlation
            self.destination = destination
            self.method = method
            self.parameters = parameters
        }
    }

    /// The peer-owned FIFO channel of commands emitted by ProxyKit.
    ///
    /// This immutable value owns only the external mailbox, not its peer. A
    /// suspended ``next()`` therefore cannot keep a dropped connection owner
    /// alive. Peer termination resumes every pending consumer with
    /// ``WebInspectorTestPeerError/connectionClosed``.
    public struct Commands: Sendable {
        fileprivate let mailbox: WebInspectorTestCommandMailbox

        fileprivate init(mailbox: WebInspectorTestCommandMailbox) {
            self.mailbox = mailbox
        }

        /// Waits for the next outbound command in exact transport FIFO order.
        ///
        /// Cancellation removes only this waiter and never consumes a future
        /// command.
        public func next() async throws -> Command {
            try await mailbox.next()
        }

        func nextForTesting(
            afterWaiterAllocation action: @escaping @Sendable () async -> Void
        ) async throws -> Command {
            try await mailbox.next(afterWaiterAllocation: action)
        }

        var pendingWaiterCountForTesting: Int {
            mailbox.pendingWaiterCount
        }
    }

    /// Raw fields for a WebKit `Target.targetCreated` event.
    public struct Target: Equatable, Sendable {
        /// The default committed main-page target installed by the test runtime.
        public static let initialPage = Target(
            id: "page-main",
            type: "page"
        )

        /// The physical target identifier.
        public let id: String

        /// The raw WebKit target type.
        public let type: String

        /// Whether the target is provisional.
        public let isProvisional: Bool

        /// Whether the target begins paused.
        public let isPaused: Bool

        /// Creates raw target fields for a target-created wire event.
        public init(
            id: String,
            type: String,
            isProvisional: Bool = false,
            isPaused: Bool = false
        ) {
            self.id = id
            self.type = type
            self.isProvisional = isProvisional
            self.isPaused = isPaused
        }
    }

    private enum State {
        case unattached
        case open
        case closed
    }

    private enum ReplyRoute: Sendable {
        case root(commandID: UInt64)
        case target(targetID: String, innerCommandID: UInt64, outerCommandID: UInt64)
    }

    private struct DecodedCommand: Sendable {
        let destination: Command.Destination
        let method: String
        let parameters: WebInspectorTestJSONObject
        let replyRoute: ReplyRoute
    }

    private let peerID: UUID
    private nonisolated let commandMailbox: WebInspectorTestCommandMailbox
    /// Commands emitted by ProxyKit through this peer's transport endpoint.
    public nonisolated let commands: Commands
    private weak var core: ConnectionCore?
    private var receiver: ConnectionReceiver?
    private var state: State
    private var nextCommandOrdinal: UInt64
    private var outstandingCommands: [UInt64: ReplyRoute]
    private var postDrainActionForTesting: (@Sendable () async -> Void)?

    package init() {
        let commandMailbox = WebInspectorTestCommandMailbox()
        peerID = UUID()
        self.commandMailbox = commandMailbox
        commands = Commands(mailbox: commandMailbox)
        core = nil
        receiver = nil
        state = .unattached
        nextCommandOrdinal = 0
        outstandingCommands = [:]
        postDrainActionForTesting = nil
    }

    isolated deinit {
        commandMailbox.finish()
        receiver?.closeSynchronously()
        outstandingCommands.removeAll(keepingCapacity: false)
    }

    /// Sends one successful protocol reply for `command`.
    ///
    /// A targeted command produces the same two inbound messages as WebKit: an
    /// outer `Target.sendMessageToTarget` acknowledgement followed by the inner
    /// target reply. Reusing a command throws
    /// ``WebInspectorTestPeerError/commandAlreadyCompleted``.
    public func reply(
        to command: Command,
        with result: WebInspectorTestJSONObject = .empty
    ) async throws {
        let route = try await takeReplyRoute(for: command)
        do {
            try await receive(
                replyMessages(
                    for: route,
                    result: result,
                    protocolError: nil
                )
            )
        } catch WebInspectorTestPeerError.connectionClosed {
            throw WebInspectorTestPeerError.staleCommand
        }
    }

    /// Sends one failing protocol reply for `command`.
    public func fail(
        _ command: Command,
        code: Int? = nil,
        message: String
    ) async throws {
        let route = try await takeReplyRoute(for: command)
        do {
            try await receive(
                replyMessages(
                    for: route,
                    result: nil,
                    protocolError: (code, message)
                )
            )
        } catch WebInspectorTestPeerError.connectionClosed {
            throw WebInspectorTestPeerError.staleCommand
        }
    }

    /// Emits a raw `Target.targetCreated` event and waits until Core applies it.
    public func createTarget(
        _ target: Target,
        deliveredBy parentTargetID: String? = nil
    ) async throws {
        let parameters = try WebInspectorTestJSONObject(encoding:
            TargetCreatedParameters(targetInfo: .init(target))
        )
        if let parentTargetID {
            try await emitTargetEvent(
                targetID: parentTargetID,
                method: "Target.targetCreated",
                parameters: parameters
            )
        } else {
            try await emitRootEvent(
                method: "Target.targetCreated",
                parameters: parameters
            )
        }
    }

    /// Emits a raw `Target.didCommitProvisionalTarget` event and waits until
    /// Core applies the retarget mutation.
    public func commitProvisionalTarget(
        from oldTargetID: String,
        to newTargetID: String
    ) async throws {
        let parameters = try WebInspectorTestJSONObject(
            encoding:
                TargetCommitParameters(oldTargetId: oldTargetID, newTargetId: newTargetID)
        )
        try await emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            parameters: parameters
        )
    }

    /// Emits a raw `Target.targetDestroyed` event and waits until Core applies it.
    public func destroyTarget(id: String) async throws {
        let parameters = try WebInspectorTestJSONObject(
            encoding:
                TargetDestroyedParameters(targetId: id)
        )
        try await emitRootEvent(method: "Target.targetDestroyed", parameters: parameters)
    }

    /// Emits one root protocol event and waits for Core's accepted-message
    /// barrier. Event sequence and domain watermarks are generated only by Core.
    public func emitRootEvent(
        method: String,
        parameters: WebInspectorTestJSONObject = .empty
    ) async throws {
        try await receive([
            try Self.eventMessage(method: method, parameters: parameters)
        ])
    }

    /// Emits one target protocol event and waits for Core's accepted-message
    /// barrier. The peer supplies only raw WebKit wire input.
    public func emitTargetEvent(
        targetID: String,
        method: String,
        parameters: WebInspectorTestJSONObject = .empty
    ) async throws {
        let innerMessage = try Self.eventMessage(method: method, parameters: parameters)
        try await receive([
            try Self.targetDispatchMessage(targetID: targetID, message: innerMessage)
        ])
    }

    /// Simulates a clean remote EOF and waits for the connection to close.
    ///
    /// Normal test ownership ends with ``WebInspectorProxyTestRuntime/close()``.
    /// Use this method only when clean peer-initiated termination is the input
    /// under test.
    public func closeConnection() async {
        guard let core else {
            finishConnection()
            return
        }
        await core.close()
    }

    /// Simulates a fatal transport failure and waits for terminal completion.
    public func failConnection(with message: String) async {
        guard case .open = state, let receiver, let core else {
            return
        }
        let handoff = receiver.fail(message)
        await handoff?.value
        _ = try? await core.waitUntilClosed()
    }

    fileprivate func attach(core: ConnectionCore, receiver: ConnectionReceiver) {
        precondition(
            state == .unattached,
            "A WebInspectorTestPeer can attach to only one connection."
        )
        self.core = core
        self.receiver = receiver
        state = .open
    }

    fileprivate func acceptOutboundMessage(_ message: String) throws {
        guard case .open = state else {
            throw WebInspectorTestPeerError.connectionClosed
        }
        let decoded = try Self.decodeOutboundMessage(message)
        precondition(
            nextCommandOrdinal < UInt64.max,
            "WebInspectorTestPeer exhausted its command correlation space."
        )
        nextCommandOrdinal += 1
        let correlation = Command.Correlation(
            peerID: peerID,
            ordinal: nextCommandOrdinal
        )
        let command = Command(
            correlation: correlation,
            destination: decoded.destination,
            method: decoded.method,
            parameters: decoded.parameters
        )
        precondition(
            outstandingCommands[nextCommandOrdinal] == nil,
            "A WebInspectorTestPeer correlation was reused."
        )
        outstandingCommands[nextCommandOrdinal] = decoded.replyRoute
        commandMailbox.append(command)
    }

    fileprivate func transportDidDetach() async {
        let attachedReceiver = receiver
        finishConnection()
        await attachedReceiver?.close()
        receiver = nil
        core = nil
    }

    func setPostDrainActionForTesting(
        _ action: (@Sendable () async -> Void)?
    ) {
        postDrainActionForTesting = action
    }

    private func takeReplyRoute(for command: Command) async throws -> ReplyRoute {
        guard command.correlation.peerID == peerID,
            command.correlation.ordinal <= nextCommandOrdinal
        else {
            throw WebInspectorTestPeerError.foreignCommand
        }
        guard case .open = state else {
            throw WebInspectorTestPeerError.staleCommand
        }
        guard outstandingCommands[command.correlation.ordinal] != nil else {
            throw WebInspectorTestPeerError.commandAlreadyCompleted
        }
        do {
            _ = try await requireCoreAdmission()
        } catch WebInspectorTestPeerError.connectionClosed {
            throw WebInspectorTestPeerError.staleCommand
        }
        guard case .open = state else {
            throw WebInspectorTestPeerError.staleCommand
        }
        guard
            let route = outstandingCommands.removeValue(
                forKey: command.correlation.ordinal
            )
        else {
            throw WebInspectorTestPeerError.commandAlreadyCompleted
        }
        return route
    }

    private func receive(_ messages: [String]) async throws {
        let admittedCore = try await requireCoreAdmission()
        guard case .open = state,
              let receiver,
            core === admittedCore
        else {
            throw WebInspectorTestPeerError.connectionClosed
        }
        precondition(messages.isEmpty == false, "A test peer receive must contain at least one message.")
        var through: UInt64?
        for message in messages {
            guard let acceptedOrdinal = receiver.receive(message) else {
                finishConnection()
                throw WebInspectorTestPeerError.connectionClosed
            }
            through = acceptedOrdinal
        }
        guard let through else {
            preconditionFailure("A non-empty test peer receive produced no watermark.")
        }
        await receiver.waitUntilDrained(through: through)
        let postDrainAction = postDrainActionForTesting
        postDrainActionForTesting = nil
        await postDrainAction?()
        do {
            try await admittedCore.requireOpen()
            guard case .open = state, core === admittedCore else {
                throw WebInspectorTestPeerError.connectionClosed
            }
        } catch {
            if await admittedCore.wasExplicitlyClosed {
                // Explicit owner close may begin immediately after the reply
                // fulfills its command. Wait for an active receiver drain to
                // become quiescent before deciding whether this input was
                // completed or discarded by close.
                await receiver.close()
                if receiver.hasCompletedDrain(through: through) {
                    finishConnection()
                    return
                }
            }
            finishConnection()
            throw WebInspectorTestPeerError.connectionClosed
        }
    }

    private func requireCoreAdmission() async throws -> ConnectionCore {
        guard case .open = state, let core else {
            throw WebInspectorTestPeerError.connectionClosed
        }
        do {
            try await core.requireOpen()
        } catch {
            finishConnection()
            throw WebInspectorTestPeerError.connectionClosed
        }
        guard case .open = state, self.core === core else {
            throw WebInspectorTestPeerError.connectionClosed
        }
        return core
    }

    private func replyMessages(
        for route: ReplyRoute,
        result: WebInspectorTestJSONObject?,
        protocolError: (code: Int?, message: String)?
    ) throws -> [String] {
        switch route {
        case let .root(commandID):
            return [
                try Self.replyMessage(
                    commandID: commandID,
                    result: result,
                    protocolError: protocolError
                )
            ]
        case let .target(targetID, innerCommandID, outerCommandID):
            let outerAcknowledgement = try Self.replyMessage(
                commandID: outerCommandID,
                result: .empty,
                protocolError: nil
            )
            let innerReply = try Self.replyMessage(
                commandID: innerCommandID,
                result: result,
                protocolError: protocolError
            )
            return [
                outerAcknowledgement,
                try Self.targetDispatchMessage(
                    targetID: targetID,
                    message: innerReply
                ),
            ]
        }
    }

    private func finishConnection() {
        guard state != .closed else {
            return
        }
        state = .closed
        outstandingCommands.removeAll(keepingCapacity: false)
        commandMailbox.finish()
    }

    private static func decodeOutboundMessage(_ message: String) throws -> DecodedCommand {
        guard let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outerID = commandID(in: object),
            let method = object["method"] as? String
        else {
            throw WebInspectorTestPeerError.malformedOutboundCommand
        }

        let parameters = try parametersObject(in: object)
        guard method == "Target.sendMessageToTarget" else {
            return DecodedCommand(
                destination: .root,
                method: method,
                parameters: parameters,
                replyRoute: .root(commandID: outerID)
            )
        }

        guard let wrapper = object["params"] as? [String: Any],
              let targetID = wrapper["targetId"] as? String,
              let innerMessage = wrapper["message"] as? String,
              let innerData = innerMessage.data(using: .utf8),
              let innerObject = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
              let innerID = commandID(in: innerObject),
              let innerMethod = innerObject["method"] as? String,
            innerMethod != "Target.sendMessageToTarget"
        else {
            throw WebInspectorTestPeerError.malformedOutboundCommand
        }

        return DecodedCommand(
            destination: .target(targetID),
            method: innerMethod,
            parameters: try parametersObject(in: innerObject),
            replyRoute: .target(
                targetID: targetID,
                innerCommandID: innerID,
                outerCommandID: outerID
            )
        )
    }

    private static func commandID(in object: [String: Any]) -> UInt64? {
        guard let number = object["id"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let value = number.doubleValue
        guard value.isFinite,
              value >= 0,
              value.rounded(.towardZero) == value,
            value <= Double(UInt64.max)
        else {
            return nil
        }
        return number.uint64Value
    }

    private static func parametersObject(
        in command: [String: Any]
    ) throws -> WebInspectorTestJSONObject {
        guard let parameters = command["params"] else {
            return .empty
        }
        guard let object = parameters as? [String: Any] else {
            throw WebInspectorTestPeerError.malformedOutboundCommand
        }
        return try WebInspectorTestJSONObject(validatedObject: object)
    }

    private static func eventMessage(
        method: String,
        parameters: WebInspectorTestJSONObject
    ) throws -> String {
        "{\"method\":\(try jsonStringLiteral(method)),\"params\":\(parameters.utf8String)}"
    }

    private static func replyMessage(
        commandID: UInt64,
        result: WebInspectorTestJSONObject?,
        protocolError: (code: Int?, message: String)?
    ) throws -> String {
        if let protocolError {
            let code = protocolError.code.map { "\"code\":\($0)," } ?? ""
            return
                "{\"id\":\(commandID),\"error\":{\(code)\"message\":\(try jsonStringLiteral(protocolError.message))}}"
        }
        guard let result else {
            preconditionFailure("A successful test reply requires a result object.")
        }
        return "{\"id\":\(commandID),\"result\":\(result.utf8String)}"
    }

    private static func targetDispatchMessage(
        targetID: String,
        message: String
    ) throws -> String {
        "{\"method\":\"Target.dispatchMessageFromTarget\",\"params\":{"
            + "\"targetId\":\(try jsonStringLiteral(targetID))," + "\"message\":\(try jsonStringLiteral(message))}}"
    }

    private static func jsonStringLiteral(_ value: String) throws -> String {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw WebInspectorTestPeerError.malformedOutboundCommand
        }
        guard let string = String(data: data, encoding: .utf8) else {
            throw WebInspectorTestPeerError.malformedOutboundCommand
        }
        return string
    }
}

private final class WebInspectorTestPeerTransportBackend: ConnectionBackend {
    private let peer: WebInspectorTestPeer

    init(peer: WebInspectorTestPeer) {
        self.peer = peer
    }

    func sendJSONString(_ message: String) async throws {
        try await peer.acceptOutboundMessage(message)
    }

    func detach() async {
        await peer.transportDidDetach()
    }
}

private final class WebInspectorTestCommandMailbox: Sendable {
    private struct Waiter: Sendable {
        let id: UInt64
        let continuation: CheckedContinuation<WebInspectorTestPeer.Command, any Error>
    }

    private struct State: Sendable {
        var commands: [WebInspectorTestPeer.Command] = []
        var commandStartIndex = 0
        var waiters: [Waiter] = []
        var nextWaiterID: UInt64 = 0
        var registeringWaiterIDs: Set<UInt64> = []
        var isFinished = false
    }

    private enum RegistrationAction {
        case wait
        case command(WebInspectorTestPeer.Command)
        case cancelled
        case finished
    }

    private let state = Mutex(State())

    var pendingWaiterCount: Int {
        state.withLock { $0.waiters.count }
    }

    func append(_ command: WebInspectorTestPeer.Command) {
        let waiter = state.withLock { state -> Waiter? in
            guard !state.isFinished else {
                return nil
            }
            if !state.waiters.isEmpty {
                return state.waiters.removeFirst()
            }
            state.commands.append(command)
            return nil
        }
        waiter?.continuation.resume(returning: command)
    }

    func next(
        afterWaiterAllocation: (@Sendable () async -> Void)? = nil
    ) async throws -> WebInspectorTestPeer.Command {
        try Task.checkCancellation()
        let waiterID = state.withLock { state -> UInt64 in
            precondition(
                state.nextWaiterID < UInt64.max,
                "WebInspectorTestPeer exhausted its command waiter space."
            )
            state.nextWaiterID += 1
            let waiterID = state.nextWaiterID
            state.registeringWaiterIDs.insert(waiterID)
            return waiterID
        }
        return try await withTaskCancellationHandler {
            await afterWaiterAllocation?()
            return try await withCheckedThrowingContinuation { continuation in
                let action = register(waiterID, continuation: continuation)
                switch action {
                case .wait:
                    break
                case let .command(command):
                    continuation.resume(returning: command)
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .finished:
                    continuation.resume(throwing: WebInspectorTestPeerError.connectionClosed)
                }
            }
        } onCancel: {
            cancel(waiterID)
        }
    }

    func finish() {
        let waiters = state.withLock { state -> [Waiter] in
            guard !state.isFinished else {
                return []
            }
            state.isFinished = true
            state.commands.removeAll(keepingCapacity: false)
            state.commandStartIndex = 0
            let waiters = state.waiters
            state.waiters.removeAll(keepingCapacity: false)
            return waiters
        }
        for waiter in waiters {
            waiter.continuation.resume(throwing: WebInspectorTestPeerError.connectionClosed)
        }
    }

    private func register(
        _ waiterID: UInt64,
        continuation: CheckedContinuation<WebInspectorTestPeer.Command, any Error>
    ) -> RegistrationAction {
        state.withLock { state in
            guard state.registeringWaiterIDs.remove(waiterID) != nil else {
                return .cancelled
            }
            if state.isFinished {
                return .finished
            }
            if state.commandStartIndex < state.commands.count {
                let command = state.commands[state.commandStartIndex]
                state.commandStartIndex += 1
                compactCommandsIfNeeded(in: &state)
                return .command(command)
            }
            state.waiters.append(Waiter(id: waiterID, continuation: continuation))
            return .wait
        }
    }

    private func cancel(_ waiterID: UInt64) {
        let waiter = state.withLock { state -> Waiter? in
            guard !state.isFinished else {
                return nil
            }
            guard let index = state.waiters.firstIndex(where: { $0.id == waiterID }) else {
                state.registeringWaiterIDs.remove(waiterID)
                return nil
            }
            return state.waiters.remove(at: index)
        }
        waiter?.continuation.resume(throwing: CancellationError())
    }

    private func compactCommandsIfNeeded(in state: inout State) {
        guard state.commandStartIndex > 64,
            state.commandStartIndex * 2 >= state.commands.count
        else {
            return
        }
        state.commands.removeFirst(state.commandStartIndex)
        state.commandStartIndex = 0
    }
}

private struct TargetCreatedParameters: Encodable {
    let targetInfo: TargetInfo

    struct TargetInfo: Encodable {
        let targetId: String
        let type: String
        let isProvisional: Bool
        let isPaused: Bool

        init(_ target: WebInspectorTestPeer.Target) {
            targetId = target.id
            type = target.type
            isProvisional = target.isProvisional
            isPaused = target.isPaused
        }
    }
}

private struct TargetCommitParameters: Encodable {
    let oldTargetId: String
    let newTargetId: String
}

private struct TargetDestroyedParameters: Encodable {
    let targetId: String
}

extension WebInspectorTestPeer {
    package func makeConnection(
        configuration: WebInspectorProxy.Configuration,
        protocolProfile: WebInspectorProtocolProfile
    ) async -> ConnectionCore {
        let receiver = ConnectionReceiver()
        let backend = WebInspectorTestPeerTransportBackend(peer: self)
        let core = ConnectionCore(
            backend: backend,
            protocolProfile: protocolProfile,
            responseTimeout: configuration.responseTimeout
        )
        receiver.setCore(core)
        attach(core: core, receiver: receiver)
        return core
    }
}
