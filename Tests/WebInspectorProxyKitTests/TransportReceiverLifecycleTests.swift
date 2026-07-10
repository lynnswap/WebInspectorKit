import Dispatch
import Foundation
import Testing
import WebInspectorTestSupport
@testable import WebInspectorProxyKit

@MainActor
@Test
func nativeInitialTargetDiscoveryAwaitsMainQueueCallbacksAndCoreDrain() async throws {
    let parser = ControlledMessageParser(blockingInvocation: 1)
    let graph = ReceiverCoreGraph(parser: parser.parse)
    let completion = ReceiverCompletionProbe()

    DispatchQueue.main.async {
        graph.receiver.receive(pageTargetCreatedMessage(id: "initial-page"))
    }
    let discoveryTask = Task { @MainActor in
        try await NativeConnectionCoreFactory.awaitInitialTargetDiscovery(
            receiver: graph.receiver,
            core: graph.core
        )
        await completion.finish()
    }

    await parser.waitUntilBlocked()
    await graph.receiver.waitForDrainWaiterForTesting()
    #expect(await completion.isFinished == false)
    #expect(await graph.core.snapshot().targetsByID.isEmpty)

    await parser.release()
    try await discoveryTask.value

    #expect(await completion.isFinished)
    #expect(await graph.core.snapshot().currentMainPageTargetID == ProtocolTarget.ID("initial-page"))
    await graph.core.close()
}

@Test
func receiverDrainWatermarkDoesNotWaitForNewerLiveMessages() async {
    let parser = ControlledMessageParser(blockingInvocation: 2)
    let graph = ReceiverCoreGraph(parser: parser.parse)

    graph.receiver.receive(pageTargetCreatedMessage(id: "initial-page"))
    let initialTail = graph.receiver.tailOrdinal()
    await graph.receiver.waitUntilDrained(through: initialTail)

    graph.receiver.receive(pageTargetCreatedMessage(id: "live-page"))
    await parser.waitUntilBlocked()
    let liveTail = graph.receiver.tailOrdinal()
    #expect(liveTail > initialTail)

    let initialWaitCompletion = ReceiverCompletionProbe()
    let initialWait = Task {
        await graph.receiver.waitUntilDrained(through: initialTail)
        await initialWaitCompletion.finish()
    }
    await initialWaitCompletion.waitUntilFinished()

    #expect(await graph.core.snapshot().targetsByID[ProtocolTarget.ID("live-page")] == nil)
    await parser.release()
    await graph.receiver.waitUntilDrained(through: liveTail)
    await initialWait.value
    #expect(await graph.core.snapshot().targetsByID[ProtocolTarget.ID("live-page")] != nil)
    await graph.core.close()
}

@MainActor
@Test
func nativeInitialTargetDiscoveryFailsWhenCloseInterruptsItsDrain() async {
    let parser = ControlledMessageParser(blockingInvocation: 1)
    let graph = ReceiverCoreGraph(parser: parser.parse)

    DispatchQueue.main.async {
        graph.receiver.receive(pageTargetCreatedMessage(id: "never-ready"))
    }
    let discoveryTask = Task { @MainActor in
        try await NativeConnectionCoreFactory.awaitInitialTargetDiscovery(
            receiver: graph.receiver,
            core: graph.core
        )
    }

    await parser.waitUntilBlocked()
    await graph.receiver.waitForDrainWaiterForTesting()
    let closeTask = Task {
        await graph.core.close()
    }
    await waitForReceiverCloseWaiterCount(1, receiver: graph.receiver)

    await #expect(throws: TransportSession.Error.transportClosed) {
        try await discoveryTask.value
    }

    await parser.release()
    await closeTask.value
    #expect(await graph.core.snapshot().targetsByID.isEmpty)
}

@Test
func receiverCloseWaitsForRootParseAndPreventsPostCloseMutation() async {
    let parser = ControlledMessageParser(blockingInvocation: 1)
    let graph = ReceiverCoreGraph(parser: parser.parse)
    let closeCompletion = ReceiverCompletionProbe()

    graph.receiver.receive(pageTargetCreatedMessage(id: "late-page"))
    await parser.waitUntilBlocked()

    let closeTask = Task {
        await graph.core.close()
        await closeCompletion.finish()
    }
    await waitForReceiverCloseWaiterCount(1, receiver: graph.receiver)

    #expect(await closeCompletion.isFinished == false)
    #expect(await graph.core.snapshot().targetsByID.isEmpty)

    await parser.release()
    await closeTask.value

    #expect(await closeCompletion.isFinished)
    #expect(await graph.core.snapshot().targetsByID.isEmpty)
    #expect(await graph.core.terminalCause == .explicitClose)
}

@Test
func parserFailureAfterExplicitCloseDoesNotReplaceTerminalCause() async {
    let parser = ControlledMessageParser(blockingInvocation: 1)
    let graph = ReceiverCoreGraph(parser: parser.parse)

    graph.receiver.receive(pageTargetCreatedMessage(id: "never-applied"))
    await parser.waitUntilBlocked()

    let closeTask = Task {
        await graph.core.close()
    }
    await waitForReceiverCloseWaiterCount(1, receiver: graph.receiver)

    await parser.release(throwing: true)
    await closeTask.value

    #expect(await graph.core.terminalCause == .explicitClose)
    #expect(await graph.core.snapshot().targetsByID.isEmpty)
}

@Test
func receiverCloseDuringNestedParsePreventsNestedRegistryMutation() async {
    let parser = ControlledMessageParser(blockingInvocation: 3)
    let graph = ReceiverCoreGraph(parser: parser.parse)
    await graph.core.receiveRootMessage(pageTargetCreatedMessage(id: "page-main"))
    let baseline = await graph.core.snapshot()

    graph.receiver.receive(
        targetDispatchMessage(
            targetID: "page-main",
            message: #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":91,"frameId":"main-frame"}}}"#
        )
    )
    await parser.waitUntilBlocked()

    let closeTask = Task {
        await graph.core.close()
    }
    await waitForReceiverCloseWaiterCount(1, receiver: graph.receiver)

    await parser.release()
    await closeTask.value

    #expect(await graph.core.snapshot() == baseline)
    #expect(await graph.core.terminalCause == .explicitClose)
}

@Test
func malformedInboundMessageHandsTerminationOffWithoutReceiverDeadlock() async throws {
    let graph = ReceiverCoreGraph()

    graph.receiver.receive("not-json")

    await #expect(throws: WebInspectorProxyError.protocolViolation("Malformed root protocol message.")) {
        try await graph.core.waitUntilClosed()
    }
    #expect(await graph.core.terminalCause == .protocolViolation("Malformed root protocol message."))
    #expect(await graph.backend.isDetached())
}

@Test
func fatalCallbackDuringParseSealsReceiverBeforeTerminalCleanup() async throws {
    let parser = ControlledMessageParser(blockingInvocation: 1)
    let graph = ReceiverCoreGraph(parser: parser.parse)

    graph.receiver.receive(pageTargetCreatedMessage(id: "late-page"))
    await parser.waitUntilBlocked()

    let fatalHandoff = try #require(graph.receiver.fail("native fatal during parse"))
    await fatalHandoff.value
    await waitForReceiverCloseWaiterCount(1, receiver: graph.receiver)

    #expect(await graph.core.terminalCause == .fatal("native fatal during parse"))
    #expect(await graph.core.snapshot().targetsByID.isEmpty)

    await parser.release()

    await #expect(throws: WebInspectorProxyError.disconnected("native fatal during parse")) {
        try await graph.core.waitUntilClosed()
    }
    #expect(await graph.core.snapshot().targetsByID.isEmpty)
}

@Test
func nativeFatalSignalBeforeExplicitCloseKeepsFatalTerminalCause() async throws {
    let closeCounter = ReceiverInvocationCounter()
    let graph = ReceiverCoreGraph(closeActionObserver: {
        await closeCounter.record()
    })

    let fatalHandoff = try #require(graph.receiver.fail("fatal wins"))
    let closeTask = Task {
        await graph.core.close()
    }
    await fatalHandoff.value
    await closeTask.value

    await #expect(throws: WebInspectorProxyError.disconnected("fatal wins")) {
        try await graph.core.waitUntilClosed()
    }
    #expect(await graph.core.terminalCause == .fatal("fatal wins"))
    #expect(await graph.backend.isDetached())
    #expect(await closeCounter.count == 1)
}

@Test
func explicitCloseClaimBeforeNativeFatalKeepsNormalTerminalCause() async throws {
    let closeGate = ReceiverAsyncGate()
    let backend = FakeTransportBackend()
    let core = ConnectionCore(
        backend: backend,
        closeAction: {
            await closeGate.waitUntilReleased()
        }
    )

    let closeTask = Task {
        await core.close()
    }
    await closeGate.waitUntilStarted()

    #expect(core.failFromNativeCallback("too late") == nil)

    await closeGate.release()
    await closeTask.value
    try await core.waitUntilClosed()
    #expect(await core.terminalCause == .explicitClose)
}

@Test
func receiverResumesAllConcurrentCloseWaitersAfterOneDrainStops() async {
    let parser = ControlledMessageParser(blockingInvocation: 1)
    let graph = ReceiverCoreGraph(parser: parser.parse)
    let firstCompletion = ReceiverCompletionProbe()
    let secondCompletion = ReceiverCompletionProbe()

    graph.receiver.receive(#"{"method":"Unknown.event","params":{}}"#)
    await parser.waitUntilBlocked()

    let firstClose = Task {
        await graph.receiver.close()
        await firstCompletion.finish()
    }
    let secondClose = Task {
        await graph.receiver.close()
        await secondCompletion.finish()
    }
    await waitForReceiverCloseWaiterCount(2, receiver: graph.receiver)

    #expect(await firstCompletion.isFinished == false)
    #expect(await secondCompletion.isFinished == false)

    await parser.release()
    await firstClose.value
    await secondClose.value

    #expect(await firstCompletion.isFinished)
    #expect(await secondCompletion.isFinished)
    await graph.core.close()
}

@Test
func terminalTaskDoesNotKeepCoreAliveAcrossExternalCloseWait() async {
    let closeGate = ReceiverAsyncGate()
    let operationCompletion = ReceiverCompletionProbe()
    let backend = FakeTransportBackend()
    var core: ConnectionCore? = ConnectionCore(
        backend: backend,
        closeAction: {
            await closeGate.waitUntilReleased()
            await operationCompletion.finish()
        }
    )
    weak let weakCore = core

    let terminalHandoff = core?.failFromNativeCallback("terminal operation")
    await terminalHandoff?.value
    await closeGate.waitUntilStarted()
    core = nil

    #expect(weakCore == nil)
    await closeGate.release()
    await operationCompletion.waitUntilFinished()
}

@Test
func explicitCloseKeepsLegacyAndStructuredStreamsOpenUntilReceiverQuiesces() async throws {
    let parser = ControlledMessageParser(blockingInvocation: 2)
    let graph = ReceiverCoreGraph(parser: parser.parse)
    await graph.core.receiveRootMessage(pageTargetCreatedMessage(id: "page-main"))
    let proxy = try await WebInspectorProxy(transport: graph.core)
    let legacyStream = await graph.core.events(for: .network)
    let legacyCompletion = ReceiverCompletionProbe()
    let structuredReady = ReceiverAsyncGate()
    let structuredCompletion = ReceiverCompletionProbe()

    let legacyTask = Task {
        var iterator = legacyStream.makeAsyncIterator()
        let event = await iterator.next()
        await legacyCompletion.finish()
        return event
    }
    let structuredTask = Task {
        do {
            return try await proxy.page.dom.withEvents { events in
                var iterator = events.makeAsyncIterator()
                _ = try await iterator.next()
                await structuredReady.waitUntilReleased()
                let terminal = try await iterator.next()
                await structuredCompletion.finish()
                return terminal == nil
            }
        } catch {
            return false
        }
    }
    await structuredReady.waitUntilStarted()
    await structuredReady.release()

    graph.receiver.receive(#"{"method":"Unknown.event","params":{}}"#)
    await parser.waitUntilBlocked()

    let closeTask = Task {
        await proxy.close()
    }
    await waitForReceiverCloseWaiterCount(1, receiver: graph.receiver)

    #expect(await legacyCompletion.isFinished == false)
    #expect(await structuredCompletion.isFinished == false)
    #expect(await graph.core.activeEventScopeSubscriberCountForTesting() == 1)

    await parser.release()
    await closeTask.value

    #expect(await legacyTask.value == nil)
    #expect(await structuredTask.value)
    #expect(await legacyCompletion.isFinished)
    #expect(await structuredCompletion.isFinished)
}

private struct ReceiverCoreGraph: Sendable {
    let receiver: TransportReceiver
    let backend: FakeTransportBackend
    let core: ConnectionCore

    init(
        parser: @escaping ConnectionCore.MessageParser = {
            try await TransportMessageParser.parse($0)
        },
        closeActionObserver: @escaping @Sendable () async -> Void = {}
    ) {
        let receiver = TransportReceiver()
        let backend = FakeTransportBackend()
        let core = ConnectionCore(
            backend: backend,
            responseTimeout: nil,
            messageParser: parser,
            closeAction: {
                await receiver.close()
                await closeActionObserver()
                await backend.detach()
            }
        )
        receiver.setCore(core)
        self.receiver = receiver
        self.backend = backend
        self.core = core
    }
}

private actor ControlledMessageParser {
    private struct InjectedFailure: Error {}

    private let blockingInvocation: Int
    private var invocationCount = 0
    private var isBlocked = false
    private var isReleased = false
    private var shouldThrow = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(blockingInvocation: Int) {
        precondition(blockingInvocation > 0)
        self.blockingInvocation = blockingInvocation
    }

    func parse(_ message: String) async throws -> ParsedProtocolMessage {
        invocationCount += 1
        guard invocationCount == blockingInvocation else {
            return try await TransportMessageParser.parse(message)
        }

        isBlocked = true
        let startWaiters = self.startWaiters
        self.startWaiters.removeAll()
        for waiter in startWaiters {
            waiter.resume()
        }

        if !isReleased {
            await withCheckedContinuation { continuation in
                if isReleased {
                    continuation.resume()
                } else {
                    releaseWaiters.append(continuation)
                }
            }
        }
        if shouldThrow {
            throw InjectedFailure()
        }
        return try await TransportMessageParser.parse(message)
    }

    func waitUntilBlocked() async {
        guard !isBlocked else {
            return
        }
        await withCheckedContinuation { continuation in
            if isBlocked {
                continuation.resume()
            } else {
                startWaiters.append(continuation)
            }
        }
    }

    func release(throwing: Bool = false) {
        shouldThrow = throwing
        isReleased = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in releaseWaiters {
            waiter.resume()
        }
    }
}

private actor ReceiverAsyncGate {
    private var isStarted = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        isStarted = true
        let startWaiters = self.startWaiters
        self.startWaiters.removeAll()
        for waiter in startWaiters {
            waiter.resume()
        }
        guard !isReleased else {
            return
        }
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                releaseWaiters.append(continuation)
            }
        }
    }

    func waitUntilStarted() async {
        guard !isStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            if isStarted {
                continuation.resume()
            } else {
                startWaiters.append(continuation)
            }
        }
    }

    func release() {
        isReleased = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in releaseWaiters {
            waiter.resume()
        }
    }
}

private actor ReceiverCompletionProbe {
    private(set) var isFinished = false
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []

    func finish() {
        guard !isFinished else {
            return
        }
        isFinished = true
        let finishWaiters = self.finishWaiters
        self.finishWaiters.removeAll()
        for waiter in finishWaiters {
            waiter.resume()
        }
    }

    func waitUntilFinished() async {
        guard !isFinished else {
            return
        }
        await withCheckedContinuation { continuation in
            if isFinished {
                continuation.resume()
            } else {
                finishWaiters.append(continuation)
            }
        }
    }
}

private actor ReceiverInvocationCounter {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private func waitForReceiverCloseWaiterCount(
    _ count: Int,
    receiver: TransportReceiver
) async {
    while receiver.closeWaiterCountForTesting() < count {
        await Task.yield()
    }
}

private func pageTargetCreatedMessage(id: String) -> String {
    #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(id)","type":"page","frameId":"main-frame","isProvisional":false}}}"#
}

private func targetDispatchMessage(targetID: String, message: String) -> String {
    let escapedMessage = message
        .replacingOccurrences(of: #"\"#, with: #"\\"#)
        .replacingOccurrences(of: #"""#, with: #"\""#)
    return #"{"method":"Target.dispatchMessageFromTarget","params":{"targetId":"\#(targetID)","message":"\#(escapedMessage)"}}"#
}
