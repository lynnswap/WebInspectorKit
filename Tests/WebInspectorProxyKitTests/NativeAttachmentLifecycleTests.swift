#if canImport(UIKit)
import Testing
import UIKit
import WebKit
@testable import WebInspectorProxyKit

@MainActor
@Test
func nativeAttachmentExplicitCloseOrdersReceiverDetachRestoreAndWaiters() async throws {
    let webView = WKWebView(frame: .zero)
    webView.isInspectable = false
    let recorder = NativeDetachRecorder()
    let gate = NativeDetachGate(blocks: true)
    let graph = NativeAttachmentTestGraph(
        webView: webView,
        recorder: recorder,
        gate: gate
    )
    let closeCompletion = NativeCloseCompletionProbe()
    let core = graph.core

    let waitTask = Task {
        try await core.waitUntilClosed()
        await closeCompletion.finish()
    }
    await core.waitForCloseWaiterForTesting()

    let closeTask = Task {
        await core.close()
    }
    await gate.waitUntilStarted()

    #expect(recorder.asyncDetachStartedCount == 1)
    #expect(recorder.asyncDetachCompletedCount == 0)
    #expect(recorder.synchronousDetachCount == 0)
    #expect(webView.isInspectable)
    #expect(await closeCompletion.isFinished == false)

    // NativeAttachment closes its receiver before beginning asynchronous
    // detach. Real callback-shaped delivery is therefore inert while detach
    // is still blocked.
    let snapshotDuringDetach = await core.snapshot()
    graph.backend.emitMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"late-page","type":"page","isProvisional":false}}}"#
    )
    graph.backend.emitFatalFailure("late native failure")
    #expect(await core.snapshot() == snapshotDuringDetach)
    #expect(await core.terminalCause == .explicitClose)

    await gate.release()
    await closeTask.value
    try await waitTask.value

    #expect(recorder.asyncDetachCompletedCount == 1)
    #expect(webView.isInspectable == false)
    #expect(await closeCompletion.isFinished)
}

@MainActor
@Test
func nativeAttachmentWaitsForActiveReceiverDrainBeforeDetachAndRestore() async {
    let webView = WKWebView(frame: .zero)
    webView.isInspectable = false
    let recorder = NativeDetachRecorder()
    let parser = NativeAttachmentMessageParserGate()
    let graph = NativeAttachmentTestGraph(
        webView: webView,
        recorder: recorder,
        gate: NativeDetachGate(blocks: false),
        parser: parser.parse
    )

    graph.backend.emitMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"late-page","type":"page","isProvisional":false}}}"#
    )
    await parser.waitUntilBlocked()

    let closeTask = Task {
        await graph.core.close()
    }
    while graph.receiver.closeWaiterCountForTesting() == 0 {
        await Task.yield()
    }

    #expect(recorder.asyncDetachStartedCount == 0)
    #expect(recorder.asyncDetachCompletedCount == 0)
    #expect(webView.isInspectable)
    #expect(await graph.core.snapshot().targetsByID.isEmpty)

    await parser.release()
    await closeTask.value

    #expect(recorder.asyncDetachStartedCount == 1)
    #expect(recorder.asyncDetachCompletedCount == 1)
    #expect(webView.isInspectable == false)
    #expect(await graph.core.snapshot().targetsByID.isEmpty)
}

@MainActor
@Test
func droppingNativeAttachmentGraphUsesSynchronousBackstop() async throws {
    let webView = WKWebView(frame: .zero)
    webView.isInspectable = false
    let recorder = NativeDetachRecorder()
    var graph: NativeAttachmentTestGraph? = NativeAttachmentTestGraph(
        webView: webView,
        recorder: recorder,
        gate: NativeDetachGate(blocks: false)
    )
    await installPageTarget(in: try #require(graph).core)
    var proxy: WebInspectorProxy? = try await WebInspectorProxy(
        transport: try #require(graph).core
    )

    weak let weakProxy = proxy
    weak let weakCore = graph?.core
    weak let weakBackend = graph?.backend
    weak let weakReceiver = graph?.receiver
    weak let weakAttachment = graph?.attachment

    proxy = nil
    graph = nil
    await recorder.waitForBackendDeinitialization()

    #expect(weakProxy == nil)
    #expect(weakCore == nil)
    #expect(weakBackend == nil)
    #expect(weakReceiver == nil)
    #expect(weakAttachment == nil)
    #expect(recorder.asyncDetachStartedCount == 0)
    #expect(recorder.asyncDetachCompletedCount == 0)
    #expect(recorder.synchronousDetachCount == 1)
    #expect(webView.isInspectable == false)
}

@MainActor
@Test
func nativeAttachmentDoubleCloseDetachesAndRestoresExactlyOnce() async {
    let webView = WKWebView(frame: .zero)
    webView.isInspectable = false
    let recorder = NativeDetachRecorder()
    let graph = NativeAttachmentTestGraph(
        webView: webView,
        recorder: recorder,
        gate: NativeDetachGate(blocks: false)
    )

    await graph.core.close()

    #expect(recorder.asyncDetachStartedCount == 1)
    #expect(recorder.asyncDetachCompletedCount == 1)
    #expect(webView.isInspectable == false)

    // If a second close tried to release the lease again, it would overwrite
    // this intervening value with the original false value.
    webView.isInspectable = true
    await graph.core.close()

    #expect(recorder.asyncDetachStartedCount == 1)
    #expect(recorder.asyncDetachCompletedCount == 1)
    #expect(recorder.synchronousDetachCount == 0)
    #expect(webView.isInspectable)
    webView.isInspectable = false
}

@MainActor
@Test
func nativeAttachmentsShareOneInspectabilityLeasePerWebView() async {
    let webView = WKWebView(frame: .zero)
    webView.isInspectable = false
    let firstRecorder = NativeDetachRecorder()
    let secondRecorder = NativeDetachRecorder()
    let first = NativeAttachmentTestGraph(
        webView: webView,
        recorder: firstRecorder,
        gate: NativeDetachGate(blocks: false)
    )
    let second = NativeAttachmentTestGraph(
        webView: webView,
        recorder: secondRecorder,
        gate: NativeDetachGate(blocks: false)
    )

    await first.core.close()

    #expect(firstRecorder.asyncDetachCompletedCount == 1)
    #expect(secondRecorder.asyncDetachCompletedCount == 0)
    #expect(webView.isInspectable)

    await second.core.close()

    #expect(secondRecorder.asyncDetachCompletedCount == 1)
    #expect(webView.isInspectable == false)
}

@MainActor
@Test
func explicitlyClosedNativeAttachmentGraphDeallocatesWithoutCycles() async throws {
    let webView = WKWebView(frame: .zero)
    webView.isInspectable = false
    let recorder = NativeDetachRecorder()
    var graph: NativeAttachmentTestGraph? = NativeAttachmentTestGraph(
        webView: webView,
        recorder: recorder,
        gate: NativeDetachGate(blocks: false)
    )
    await installPageTarget(in: try #require(graph).core)
    var proxy: WebInspectorProxy? = try await WebInspectorProxy(
        transport: try #require(graph).core
    )

    weak let weakProxy = proxy
    weak let weakCore = graph?.core
    weak let weakBackend = graph?.backend
    weak let weakReceiver = graph?.receiver
    weak let weakAttachment = graph?.attachment

    await proxy?.close()
    proxy = nil
    graph = nil
    await recorder.waitForBackendDeinitialization()

    #expect(weakProxy == nil)
    #expect(weakCore == nil)
    #expect(weakBackend == nil)
    #expect(weakReceiver == nil)
    #expect(weakAttachment == nil)
    #expect(recorder.asyncDetachStartedCount == 1)
    #expect(recorder.asyncDetachCompletedCount == 1)
    #expect(recorder.synchronousDetachCount == 0)
    #expect(webView.isInspectable == false)
}

@MainActor
@Test
func nativeReceiverCallbacksRemainDisabledAfterClose() async {
    let webView = WKWebView(frame: .zero)
    let graph = NativeAttachmentTestGraph(
        webView: webView,
        recorder: NativeDetachRecorder(),
        gate: NativeDetachGate(blocks: false)
    )

    await graph.core.close()
    let closedSnapshot = await graph.core.snapshot()

    graph.backend.emitMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"late-page","type":"page","isProvisional":false}}}"#
    )
    graph.backend.emitFatalFailure("late failure")

    #expect(await graph.core.snapshot() == closedSnapshot)
    #expect(await graph.core.terminalCause == .explicitClose)
}

@MainActor
private struct NativeAttachmentTestGraph {
    let receiver: TransportReceiver
    let backend: FakeNativeAttachmentBackend
    let attachment: NativeAttachment
    let core: ConnectionCore

    init(
        webView: WKWebView,
        recorder: NativeDetachRecorder,
        gate: NativeDetachGate,
        parser: @escaping ConnectionCore.MessageParser = {
            try await TransportMessageParser.parse($0)
        }
    ) {
        let receiver = TransportReceiver()
        let backend = FakeNativeAttachmentBackend(
            receiver: receiver,
            recorder: recorder,
            gate: gate
        )
        let page = NativeInspectablePage(webView: webView)
        let attachment = NativeAttachment(
            receiver: receiver,
            backend: backend,
            page: page
        )
        let core = ConnectionCore(
            backend: backend,
            messageParser: parser,
            closeAction: {
                await attachment.close()
            }
        )
        receiver.setCore(core)

        self.receiver = receiver
        self.backend = backend
        self.attachment = attachment
        self.core = core
    }
}

@MainActor
private final class FakeNativeAttachmentBackend: NativeAttachmentBackend {
    private nonisolated let receiver: TransportReceiver
    private nonisolated let recorder: NativeDetachRecorder
    private nonisolated let gate: NativeDetachGate

    init(
        receiver: TransportReceiver,
        recorder: NativeDetachRecorder,
        gate: NativeDetachGate
    ) {
        self.receiver = receiver
        self.recorder = recorder
        self.gate = gate
    }

    nonisolated func sendJSONString(_ message: String) async throws {
        _ = message
    }

    nonisolated func detach() async {
        await recorder.recordAsyncDetachStarted()
        await gate.beginDetach()
        await recorder.recordAsyncDetachCompleted()
    }

    func detachSynchronously() {
        recorder.recordSynchronousDetach()
    }

    func emitMessage(_ message: String) {
        receiver.receive(message)
    }

    func emitFatalFailure(_ message: String) {
        receiver.fail(message)
    }

    isolated deinit {
        recorder.recordBackendDeinitialized()
    }
}

@MainActor
private final class NativeDetachRecorder {
    private(set) var asyncDetachStartedCount = 0
    private(set) var asyncDetachCompletedCount = 0
    private(set) var synchronousDetachCount = 0
    private(set) var backendDeinitializationCount = 0
    private var backendDeinitializationWaiters: [CheckedContinuation<Void, Never>] = []

    func recordAsyncDetachStarted() {
        asyncDetachStartedCount += 1
    }

    func recordAsyncDetachCompleted() {
        asyncDetachCompletedCount += 1
    }

    func recordSynchronousDetach() {
        synchronousDetachCount += 1
    }

    func recordBackendDeinitialized() {
        backendDeinitializationCount += 1
        let waiters = backendDeinitializationWaiters
        backendDeinitializationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForBackendDeinitialization() async {
        guard backendDeinitializationCount == 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            if backendDeinitializationCount > 0 {
                continuation.resume()
            } else {
                backendDeinitializationWaiters.append(continuation)
            }
        }
    }
}

private actor NativeDetachGate {
    private let blocks: Bool
    private var didStart = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(blocks: Bool) {
        self.blocks = blocks
    }

    func beginDetach() async {
        didStart = true
        let startWaiters = self.startWaiters
        self.startWaiters.removeAll()
        for waiter in startWaiters {
            waiter.resume()
        }

        guard blocks, !isReleased else {
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
        guard !didStart else {
            return
        }
        await withCheckedContinuation { continuation in
            if didStart {
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

private actor NativeCloseCompletionProbe {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}

private actor NativeAttachmentMessageParserGate {
    private var isBlocked = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func parse(_ message: String) async throws -> ParsedProtocolMessage {
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

@MainActor
private func installPageTarget(in core: ConnectionCore) async {
    await core.receiveRootMessage(
        #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-main","type":"page","frameId":"main-frame","isProvisional":false}}}"#
    )
}

#endif
