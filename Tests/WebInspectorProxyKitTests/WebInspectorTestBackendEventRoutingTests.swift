import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@Test(.timeLimit(.minutes(1)))
func testBackendCancelledCommandWaitReleasesRegistrationAndAllowsLaterWaits() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let registered = ReplyPromise<Void>()
    let cancelledWait = Task {
        try await runtime.backend.waitForRecordedCommandsForTesting(
            domain: "Page",
            method: "reload",
            count: 1,
            onWaiterRegistered: { registered.fulfill(.success(())) }
        )
    }
    try await registered.value()
    #expect(await runtime.backend.cancellableRecordedCommandWaiterCountForTesting() == 1)

    cancelledWait.cancel()
    await #expect(throws: CancellationError.self) {
        try await cancelledWait.value
    }
    #expect(await runtime.backend.cancellableRecordedCommandWaiterCountForTesting() == 0)

    let nextRegistered = ReplyPromise<Void>()
    let nextWait = Task {
        try await runtime.backend.waitForRecordedCommandsForTesting(
            domain: "Page",
            method: "reload",
            count: 1,
            onWaiterRegistered: { nextRegistered.fulfill(.success(())) }
        )
    }
    try await nextRegistered.value()
    let publicWait = Task {
        await runtime.backend.waitForRecordedCommands(domain: "Page", method: "reload", count: 1)
    }
    await runtime.backend.enqueue((), for: "Page", method: "reload")
    try await target.page.reload()

    let expected = [RecordedCommand(domain: "Page", method: "reload")]
    #expect(try await nextWait.value == expected)
    #expect(await publicWait.value == expected)
    #expect(await runtime.backend.cancellableRecordedCommandWaiterCountForTesting() == 0)
    await runtime.proxy.close()
}

@Test
func testBackendEmissionWithoutRecipientsAdvancesOrderedFeedSequence() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()

    await runtime.backend.emit(.documentUpdated, target: target)
    let cancelledFeed = await runtime.backend.orderedEvents(
        route: target.route,
        targetID: target.id,
        terminalFailureHandler: { _ in }
    )
    #expect(cancelledFeed.initialSequence == 1)
    let cancelledTask = Task {
        var iterator = cancelledFeed.events.makeAsyncIterator()
        return try await iterator.next()
    }
    cancelledTask.cancel()
    #expect(try await cancelledTask.value == nil)

    await runtime.backend.emit(.documentUpdated, target: target)
    let lateFeed = await runtime.backend.orderedEvents(
        route: target.route,
        targetID: target.id,
        terminalFailureHandler: { _ in }
    )
    #expect(lateFeed.initialSequence == 2)

    await runtime.backend.emit(.mediaQueryResultChanged, target: target)
    await runtime.backend.finishEventSubscriptions(throwing: nil)
    var iterator = lateFeed.events.makeAsyncIterator()
    let delivered = try #require(try await iterator.next())
    #expect(delivered.sequence == 3)
    guard case .css(.mediaQueryResultChanged) = delivered.event else {
        Issue.record("Expected only the event emitted after the late subscription.")
        return
    }
    #expect(try await iterator.next() == nil)
    await runtime.proxy.close()
}

@Test
func testBackendOrderedFeedsSeparateRoutesAndPreserveReplyWatermarks() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let original = try await runtime.proxy.waitForCurrentPage()
    let retargeted = WebInspectorTarget(
        id: original.id,
        kind: original.kind,
        frameID: original.frameID,
        isProvisional: original.isProvisional,
        proxy: runtime.proxy,
        route: RoutingTargetID("retargeted-route")
    )
    let originalFeed = await runtime.backend.orderedEvents(
        route: original.route,
        targetID: original.id,
        terminalFailureHandler: { _ in }
    )
    let retargetedFeed = await runtime.backend.orderedEvents(
        route: retargeted.route,
        targetID: retargeted.id,
        terminalFailureHandler: { _ in }
    )
    #expect(originalFeed.initialSequence == 0)
    #expect(retargetedFeed.initialSequence == 0)

    await runtime.backend.emit(.documentUpdated, target: original)
    await runtime.backend.emit(.mediaQueryResultChanged, target: retargeted)
    await runtime.backend.enqueue((), for: "CSS", method: "enable")
    let reply = try await runtime.backend.dispatchCommandWithReplyBoundary(
        WebInspectorProxyCommand<Void, Void>(
            targetID: retargeted.id,
            route: retargeted.route,
            domain: .css,
            method: "enable",
            payload: ()
        )
    )
    #expect(reply.receivedSequence == 2)
    await runtime.backend.finishEventSubscriptions(throwing: nil)

    var originalEvents = originalFeed.events.makeAsyncIterator()
    var retargetedEvents = retargetedFeed.events.makeAsyncIterator()
    let originalFirst = try #require(try await originalEvents.next())
    let retargetedFirst = try #require(try await retargetedEvents.next())
    #expect(originalFirst.sequence == 1)
    #expect(retargetedFirst.sequence == 1)
    #expect(retargetedFirst.event == nil)
    guard case .dom(.documentUpdated) = originalFirst.event else {
        Issue.record("Expected the original route to receive its DOM event.")
        return
    }

    let originalSecond = try #require(try await originalEvents.next())
    let retargetedSecond = try #require(try await retargetedEvents.next())
    #expect(originalSecond.sequence == 2)
    #expect(retargetedSecond.sequence == 2)
    #expect(originalSecond.event == nil)
    guard case .css(.mediaQueryResultChanged) = retargetedSecond.event else {
        Issue.record("Expected the retargeted route to receive its CSS event.")
        return
    }
    #expect(try await originalEvents.next() == nil)
    #expect(try await retargetedEvents.next() == nil)
    await runtime.proxy.close()
}
