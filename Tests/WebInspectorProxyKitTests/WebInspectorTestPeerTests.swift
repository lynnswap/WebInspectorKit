import Testing
import WebInspectorProxyKit
@testable import WebInspectorProxyKitTesting
@testable import WebInspectorTestSupport

@Test
func testJSONObjectCanonicalizesObjectEquality() throws {
    let first = try WebInspectorTestJSONObject(json: #"{"b":2,"a":1}"#)
    let second = try WebInspectorTestJSONObject(json: "{ \"a\" : 1, \"b\" : 2 }")

    #expect(first == second)
    #expect(try first.decode(JSONFixture.self) == JSONFixture(a: 1, b: 2))
    #expect(throws: WebInspectorTestPeerError.invalidJSONObject) {
        try WebInspectorTestJSONObject(json: "[1, 2]")
    }
}

@Test
func peerDeliversRootCommandsFIFOAndRepliesExactlyOnce() async throws {
    let peer = WebInspectorTestPeer()
    let core = await peer.makeConnection(configuration: .init())

    let firstTask = Task {
        try await core.send(ProtocolCommand(
            domain: .target,
            method: "Target.first",
            routing: .root
        ))
    }
    let first = try await peer.commands.next()
    #expect(first.destination == .root)
    #expect(first.method == "Target.first")

    let secondTask = Task {
        try await core.send(ProtocolCommand(
            domain: .target,
            method: "Target.second",
            routing: .root
        ))
    }
    let second = try await peer.commands.next()
    #expect(second.destination == .root)
    #expect(second.method == "Target.second")

    try await peer.reply(to: first)
    try await peer.reply(to: second)
    _ = try await firstTask.value
    _ = try await secondTask.value
    await #expect(throws: WebInspectorTestPeerError.commandAlreadyCompleted) {
        try await peer.reply(to: first)
    }
    await core.close()
}

@Test
func targetedReplyCompletesOuterAndInnerCorrelation() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let operation = Task {
        try await target.page.reload()
    }

    let command = try await runtime.peer.commands.next()
    #expect(command.destination == .target("page-main"))
    #expect(command.method == "Page.reload")
    try await runtime.peer.reply(to: command)
    try await operation.value
    await runtime.close()
}

@Test
func commandAndEventAdmissionRejectCoreCloseBeforePeerDetach() async throws {
    let peer = WebInspectorTestPeer()
    let core = await peer.makeConnection(configuration: .init())
    let operation = Task {
        try await core.send(ProtocolCommand(
            domain: .target,
            method: "Target.pending",
            routing: .root
        ))
    }
    let command = try await peer.commands.next()

    let closeActionEntered = WebInspectorTestGate()
    let permitClose = WebInspectorTestGate()
    await core.replaceCloseActionForTesting {
        closeActionEntered.open()
        await permitClose.waiter.wait()
    }
    let close = Task {
        await core.close()
    }
    await closeActionEntered.waiter.wait()

    await #expect(throws: WebInspectorTestPeerError.staleCommand) {
        try await peer.reply(to: command)
    }
    await #expect(throws: WebInspectorTestPeerError.connectionClosed) {
        try await peer.emitRootEvent(method: "Target.late")
    }

    permitClose.open()
    await close.value
    await #expect(throws: TransportSession.Error.self) {
        try await operation.value
    }
}

@Test
func peerRejectsForeignAndStaleCorrelationsWithoutTombstones() async throws {
    let firstRuntime = try await WebInspectorProxyTestRuntime.start()
    let secondRuntime = try await WebInspectorProxyTestRuntime.start()
    let firstTarget = try await firstRuntime.proxy.waitForCurrentPage()

    let operation = Task {
        try await firstTarget.page.reload()
    }
    let command = try await firstRuntime.peer.commands.next()
    await #expect(throws: WebInspectorTestPeerError.foreignCommand) {
        try await secondRuntime.peer.reply(to: command)
    }

    await firstRuntime.peer.closeConnection()
    await #expect(throws: WebInspectorTestPeerError.staleCommand) {
        try await firstRuntime.peer.reply(to: command)
    }
    await #expect(throws: WebInspectorProxyError.closed) {
        try await operation.value
    }
    await secondRuntime.close()
}

@Test
func cancellingNextCommandWaiterDoesNotConsumeTheNextWireCommand() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let cancelledWaiter = Task {
        try await runtime.peer.commands.next()
    }
    cancelledWaiter.cancel()
    await #expect(throws: CancellationError.self) {
        try await cancelledWaiter.value
    }

    let operation = Task {
        try await target.page.reload()
    }
    let command = try await runtime.peer.commands.next()
    #expect(command.method == "Page.reload")
    try await runtime.peer.reply(to: command)
    try await operation.value
    await runtime.close()
}

@Test
func suspendedNextCommandWaiterDoesNotRetainUnattachedPeer() async throws {
    var peer: WebInspectorTestPeer? = WebInspectorTestPeer()
    weak let weakPeer = peer
    let waiter = Task { [weak peer] in
        guard let commands = peer?.commands else {
            return nil as WebInspectorTestPeer.Command?
        }
        return try await commands.next()
    }

    while peer?.commands.pendingWaiterCountForTesting == 0 {
        await Task.yield()
    }
    peer = nil

    let didReleasePeer = await eventually { weakPeer == nil }
    #expect(didReleasePeer)
    if !didReleasePeer {
        waiter.cancel()
    }
    await #expect(throws: WebInspectorTestPeerError.connectionClosed) {
        try await waiter.value
    }
}

@Test
func peerTerminationWinsWhenItPrecedesCommandWaiterRegistration() async throws {
    var peer: WebInspectorTestPeer? = WebInspectorTestPeer()
    weak let weakPeer = peer
    let commands = try #require(peer).commands
    let waiterAllocated = WebInspectorTestGate()
    let permitRegistration = WebInspectorTestGate()
    let waiter = Task {
        try await commands.nextForTesting {
            waiterAllocated.open()
            await permitRegistration.waiter.wait()
        }
    }

    await waiterAllocated.waiter.wait()
    peer = nil
    #expect(weakPeer == nil)
    permitRegistration.open()

    await #expect(throws: WebInspectorTestPeerError.connectionClosed) {
        try await waiter.value
    }
}

@Test
func testGateOpenAndTaskCancellationLinearizeBeforeWaiterRegistration() async throws {
    let openFirstGate = WebInspectorTestGate()
    let openFirstAllocated = NonCancellableBarrier()
    let permitOpenFirstRegistration = NonCancellableBarrier()
    let openFirstWaiter = Task {
        try await openFirstGate.waiter.waitUntilOpenForTesting {
            await openFirstAllocated.open()
            await permitOpenFirstRegistration.wait()
        }
    }
    await openFirstAllocated.wait()
    openFirstGate.open()
    openFirstWaiter.cancel()
    await permitOpenFirstRegistration.open()
    try await openFirstWaiter.value

    let cancellationFirstGate = WebInspectorTestGate()
    let cancellationFirstAllocated = NonCancellableBarrier()
    let permitCancellationFirstRegistration = NonCancellableBarrier()
    let cancellationFirstWaiter = Task {
        try await cancellationFirstGate.waiter.waitUntilOpenForTesting {
            await cancellationFirstAllocated.open()
            await permitCancellationFirstRegistration.wait()
        }
    }
    await cancellationFirstAllocated.wait()
    cancellationFirstWaiter.cancel()
    cancellationFirstGate.open()
    await permitCancellationFirstRegistration.open()
    await #expect(throws: CancellationError.self) {
        try await cancellationFirstWaiter.value
    }
}

@Test
func testGateWaitHandleDoesNotRetainController() async throws {
    var gate: WebInspectorTestGate? = WebInspectorTestGate()
    weak let weakGate = gate
    let waiter = try #require(gate).waiter
    let task = Task {
        await waiter.wait()
    }

    while waiter.pendingWaiterCountForTesting == 0 {
        await Task.yield()
    }
    gate = nil

    #expect(weakGate == nil)
    await task.value
    #expect(waiter.pendingWaiterCountForTesting == 0)
}

@Test
func proxyOwnsRawPeerAfterRuntimeWrapperIsReleased() async throws {
    var runtime: WebInspectorProxyTestRuntime? = try await .start()
    var proxy: WebInspectorProxy? = try #require(runtime).proxy
    weak let weakPeer = try #require(runtime).peer
    runtime = nil

    #expect(weakPeer != nil)
    do {
        let retainedProxy = try #require(proxy)
        let retainedPeer = try #require(weakPeer)
        let operation = Task {
            try await retainedProxy.reload()
        }
        let command = try await retainedPeer.commands.next()
        #expect(command.destination == .target("page-main"))
        #expect(command.method == "Page.reload")
        try await retainedPeer.reply(to: command)
        try await operation.value
    }

    await proxy?.close()
    proxy = nil
    #expect(await eventually { weakPeer == nil })
}

@Test
func rawWireDriverConsumesLaterCommandsWhileAnEarlierReplyIsDeferred() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let driver = WebInspectorRawWireDriver(peer: runtime.peer)
    await driver.start()
    let reloadGate = await driver.deferReply(to: "Page.reload")
    await driver.respond(to: "DOM.hideHighlight")

    let reload = Task {
        try await target.page.reload()
    }
    _ = await driver.observations.waitForCommands(method: "Page.reload", count: 1)

    let hideHighlight = Task {
        try await target.dom.hideHighlight()
    }
    _ = await driver.observations.waitForCompletedCommands(method: "DOM.hideHighlight", count: 1)
    try await hideHighlight.value

    #expect(driver.observations.commandMethods == [
        "Page.reload",
        "DOM.hideHighlight",
    ])
    reloadGate.open()
    try await reload.value

    await runtime.close()
    await driver.stop()
}

@Test
func rawWireDriverStopCancelsAndAwaitsDeferredReplies() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let driver = WebInspectorRawWireDriver(peer: runtime.peer)
    await driver.start()
    _ = await driver.deferReply(to: "Page.reload")

    let reload = Task {
        try await target.page.reload()
    }
    _ = await driver.observations.waitForCommands(method: "Page.reload", count: 1)

    await driver.stop()
    await runtime.close()
    await #expect(throws: WebInspectorProxyError.closed) {
        try await reload.value
    }
}

@Test
func rawWireDriverConsumerTaskDoesNotRetainIdleDriver() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    weak var weakDriver: WebInspectorRawWireDriver?

    do {
        let driver = WebInspectorRawWireDriver(peer: runtime.peer)
        weakDriver = driver
        await driver.start()
    }

    #expect(weakDriver == nil)
    await runtime.close()
}

@Test
func suspendedRawWireObservationDoesNotRetainDriver() async {
    let peer = WebInspectorTestPeer()
    var driver: WebInspectorRawWireDriver? = WebInspectorRawWireDriver(peer: peer)
    weak let weakDriver = driver
    let waiter = Task { [weak driver] () -> [WebInspectorTestPeer.Command] in
        guard let observations = driver?.observations else {
            return []
        }
        return await observations.waitForCommands(method: "Page.reload", count: 1)
    }

    while driver?.observations.pendingWaiterCountForTesting == 0 {
        await Task.yield()
    }
    driver = nil

    let didReleaseDriver = await eventually { weakDriver == nil }
    #expect(didReleaseDriver)
    if !didReleaseDriver {
        waiter.cancel()
    }
    #expect(await waiter.value.isEmpty)
}

@Test
func stoppedRawWireDriverReleasesDeferredReplyTask() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    weak var weakDriver: WebInspectorRawWireDriver?
    var reload: Task<Void, any Error>?

    do {
        let driver = WebInspectorRawWireDriver(peer: runtime.peer)
        weakDriver = driver
        await driver.start()
        _ = await driver.deferReply(to: "Page.reload")
        reload = Task {
            try await target.page.reload()
        }
        _ = await driver.observations.waitForCommands(method: "Page.reload", count: 1)
        await driver.stop()
    }

    #expect(weakDriver == nil)
    await runtime.close()
    let reloadTask = try #require(reload)
    await #expect(throws: WebInspectorProxyError.closed) {
        try await reloadTask.value
    }
}

private struct JSONFixture: Codable, Equatable, Sendable {
    let a: Int
    let b: Int
}

private func eventually(
    timeout: Duration = .seconds(1),
    _ predicate: () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !predicate() {
        guard clock.now < deadline else {
            return false
        }
        await Task.yield()
    }
    return true
}

private actor NonCancellableBarrier {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}
