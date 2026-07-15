import Dispatch
import Foundation
import Testing
import WebInspectorTestSupport
@testable import WebInspectorProxyKit

@MainActor
@Test
func nativeInitialTargetDiscoveryAppliesEverySynchronousMainQueueCallback() async throws {
    let graph = ReceiverTransportGraph()

    DispatchQueue.main.async {
        graph.receiver.receive(
            targetCreatedMessage(
                id: "initial-page",
                type: "page"
            )
        )
    }
    DispatchQueue.main.async {
        graph.receiver.receive(
            targetCreatedMessage(
                id: "initial-frame",
                type: "frame"
            )
        )
    }

    try await NativeInspectorConnectionFactory.awaitInitialTargetDiscovery(
        receiver: graph.receiver,
        transport: graph.transport
    )

    let snapshot = await graph.transport.snapshot()
    let page = try #require(snapshot.targetsByID[ProtocolTarget.ID("initial-page")])
    let frame = try #require(snapshot.targetsByID[ProtocolTarget.ID("initial-frame")])
    #expect(snapshot.currentMainPageTargetID == page.id)
    #expect(page.capabilities == .pageDefault)
    #expect(frame.capabilities.isEmpty)

    await graph.close()
}

@MainActor
@Test
func nativeInitialTargetDiscoveryDoesNotCompleteDuringFinalCallback() async throws {
    let parser = ControlledMessageParser(blockingInvocation: 2)
    let graph = ReceiverTransportGraph(parser: parser.parse)
    let completion = CompletionProbe()

    DispatchQueue.main.async {
        graph.receiver.receive(
            targetCreatedMessage(
                id: "initial-page",
                type: "page"
            )
        )
    }
    DispatchQueue.main.async {
        graph.receiver.receive(
            targetCreatedMessage(
                id: "initial-frame",
                type: "frame"
            )
        )
    }

    let discoveryTask = Task { @MainActor in
        try await NativeInspectorConnectionFactory.awaitInitialTargetDiscovery(
            receiver: graph.receiver,
            transport: graph.transport
        )
        await completion.finish()
    }

    await parser.waitUntilBlocked()
    #expect(await completion.isFinished == false)
    #expect(
        await graph.transport.snapshot().targetsByID[ProtocolTarget.ID("initial-frame")] == nil
    )

    await parser.release()
    try await discoveryTask.value

    #expect(await completion.isFinished)
    #expect(
        await graph.transport.snapshot().targetsByID[ProtocolTarget.ID("initial-frame")] != nil
    )
    await graph.close()
}

@Test
func receiverDrainWatermarkDoesNotWaitForNewerLiveCallback() async {
    let parser = ControlledMessageParser(blockingInvocation: 2)
    let graph = ReceiverTransportGraph(parser: parser.parse)

    graph.receiver.receive(
        targetCreatedMessage(
            id: "initial-page",
            type: "page"
        )
    )
    let initialTail = graph.receiver.tailOrdinal()
    graph.receiver.receive(
        targetCreatedMessage(
            id: "live-frame",
            type: "frame"
        )
    )
    let liveTail = graph.receiver.tailOrdinal()
    await parser.waitUntilBlocked()

    let completion = CompletionProbe()
    let initialWait = Task {
        await graph.receiver.waitUntilDrained(through: initialTail)
        await completion.finish()
    }
    await completion.waitUntilFinished()

    #expect(liveTail > initialTail)
    #expect(
        await graph.transport.snapshot().targetsByID[ProtocolTarget.ID("live-frame")] == nil
    )

    await parser.release()
    await graph.receiver.waitUntilDrained(through: liveTail)
    await initialWait.value

    #expect(
        await graph.transport.snapshot().targetsByID[ProtocolTarget.ID("live-frame")] != nil
    )
    await graph.close()
}

@MainActor
@Test
func nativeConnectionCloseAwaitsActiveReceiverTurnBeforeBackendDetach() async {
    let parser = ControlledMessageParser(blockingInvocation: 1)
    let graph = ReceiverTransportGraph(parser: parser.parse)
    let closeCompletion = CompletionProbe()
    let connection = NativeInspectorConnection(
        transport: graph.transport,
        receiver: graph.receiver,
        reloadPage: {},
        canReloadPage: { false },
        cleanup: {}
    )

    graph.receiver.receive(
        targetCreatedMessage(
            id: "active-page",
            type: "page"
        )
    )
    await parser.waitUntilBlocked()

    let closeTask = Task {
        await connection.close()
        await closeCompletion.finish()
    }
    await waitForReceiverCloseWaiter(receiver: graph.receiver)

    #expect(await closeCompletion.isFinished == false)
    #expect(await graph.backend.isDetached() == false)
    #expect(
        await graph.transport.snapshot().targetsByID[ProtocolTarget.ID("active-page")] == nil
    )

    await parser.release()
    await closeTask.value

    #expect(await closeCompletion.isFinished)
    #expect(await graph.backend.isDetached())
    #expect(
        await graph.transport.snapshot().targetsByID[ProtocolTarget.ID("active-page")] != nil
    )
}

private struct ReceiverTransportGraph: Sendable {
    let receiver: TransportReceiver
    let backend: FakeTransportBackend
    let transport: TransportSession

    init(
        parser: @escaping TransportSession.MessageParser = {
            try await TransportMessageParser.parse($0)
        }
    ) {
        let receiver = TransportReceiver()
        let backend = FakeTransportBackend()
        let transport = TransportSession(
            backend: backend,
            messageParser: parser
        )
        receiver.setTransport(transport)
        self.receiver = receiver
        self.backend = backend
        self.transport = transport
    }

    func close() async {
        await receiver.close()
        await transport.detach()
    }
}

private actor ControlledMessageParser {
    private let blockingInvocation: Int
    private var invocationCount = 0
    private var isBlocked = false
    private var isReleased = false
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

    func release() {
        isReleased = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in releaseWaiters {
            waiter.resume()
        }
    }
}

private actor CompletionProbe {
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

private func waitForReceiverCloseWaiter(receiver: TransportReceiver) async {
    while receiver.closeWaiterCountForTesting() == 0 {
        await Task.yield()
    }
}

private func targetCreatedMessage(
    id: String,
    type: String
) -> String {
    #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"\#(id)","type":"\#(type)","isProvisional":false,"isPaused":false}}}"#
}
