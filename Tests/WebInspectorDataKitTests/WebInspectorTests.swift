import Foundation
import Observation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@MainActor
private func applyFinishedRequest(_ id: String, to context: WebInspectorContext) {
    let requestID = Network.Request.ID(id)
    context.apply(
        .requestWillBeSent(
            id: requestID,
            request: Network.Request(id: requestID, url: "https://example.com/\(id)", method: "GET"),
            resourceType: .fetch,
            redirectResponse: nil,
            timestamp: 1
        ))
}

@MainActor
@Test
func latestAttachReplacesAnAttachmentThatIsStillStarting() async throws {
    let inspector = WebInspector()
    let firstRuntime = try await WebInspectorProxyTestRuntime.start()
    let secondRuntime = try await WebInspectorProxyTestRuntime.start()
    let firstStarted = WebInspectorTestGate()
    let firstGate = WebInspectorTestGate()
    #expect(inspector.state == .detached)

    let firstAttach = Task { @MainActor in
        try await inspector.attach(makeContainer: {
            await firstStarted.open()
            await withTaskCancellationHandler {
                await firstGate.wait()
            } onCancel: {
                Task { await firstGate.open() }
            }
            return WebInspectorContainer(proxy: firstRuntime.proxy)
        })
    }
    await firstStarted.wait()
    #expect(inspector.state == .attaching)

    let secondContainer = WebInspectorContainer(proxy: secondRuntime.proxy)
    let secondWasApplied = try await inspector.attach(makeContainer: { secondContainer })

    #expect(secondWasApplied)
    #expect(try await firstAttach.value == false)
    #expect(inspector.context === secondContainer.mainContext)
    // The superseded attachment was closed before the second one started.
    try await firstRuntime.proxy.waitUntilClosed()

    await inspector.detachAndWait()
    #expect(inspector.state == .detached)
    try await secondRuntime.proxy.waitUntilClosed()
}

@MainActor
@Test
func detachReportsDetachedBeforeTheAttachmentHasEnded() async throws {
    let context = WebInspectorContext.preview()
    let inspector = WebInspector(context: context)
    applyFinishedRequest("before-detach", to: context)
    #expect(inspector.state == .attached)
    #expect(inspector.network.requests.count == 1)

    inspector.detach()
    #expect(inspector.state == .detached)

    await inspector.waitUntilIdle()
    #expect(inspector.state == .detached)
    #expect(inspector.context !== context)
    #expect(inspector.network.requests.isEmpty)
}

@MainActor
@Test
func failedAttachReportsTheFailureUntilTheNextCall() async throws {
    let inspector = WebInspector()
    let failure = WebInspectorProxyError.disconnected("The web view has no inspectable page.")

    await #expect(throws: failure) {
        try await inspector.attach(makeContainer: { throw failure })
    }
    #expect(inspector.state == .failed(failure))

    await inspector.detachAndWait()
    #expect(inspector.state == .detached)
}

@MainActor
@Test
func collectionChangesContinueAcrossAttachments() async throws {
    let first = WebInspectorContext.preview()
    let second = WebInspectorContext.preview()
    let inspector = WebInspector(context: first)
    var changes = inspector.network.requestChanges.makeAsyncIterator()

    applyFinishedRequest("first", to: first)
    let firstRequest = try #require(inspector.network.requests.first)
    applyFinishedRequest("carried", to: second)
    let carriedRequest = try #require(second.network.requests.first)

    inspector.install(second)
    // The replaced context no longer reaches the inspector's stream.
    applyFinishedRequest("after-replacement", to: first)
    applyFinishedRequest("second", to: second)
    let secondRequest = try #require(second.network.requests.last)

    #expect(await changes.next() == .inserted([firstRequest]))
    #expect(await changes.next() == .removedAll)
    #expect(await changes.next() == .inserted([carriedRequest]))
    #expect(await changes.next() == .inserted([secondRequest]))
    #expect(inspector.network.requests == [carriedRequest, secondRequest])
}

@MainActor
@Test
func domainStateIsObservableAcrossAttachments() async throws {
    let first = WebInspectorContext.preview()
    first.seedDOMDocument(DOM.Node(id: DOM.Node.ID("first-document"), nodeType: 9, nodeName: "#document"))
    let inspector = WebInspector(context: first)
    let firstRoot = try #require(inspector.dom.rootNode)

    let selectionChanged = SynchronousObservationProbe()
    withObservationTracking {
        _ = inspector.dom.selectedNode
    } onChange: {
        selectionChanged.markChanged()
    }
    inspector.dom.select(firstRoot)
    #expect(selectionChanged.hasChanged)
    #expect(inspector.dom.selectedNode === firstRoot)

    let second = WebInspectorContext.preview()
    second.seedDOMDocument(DOM.Node(id: DOM.Node.ID("second-document"), nodeType: 9, nodeName: "#document"))
    let rootChanged = SynchronousObservationProbe()
    withObservationTracking {
        _ = inspector.dom.rootNode
    } onChange: {
        rootChanged.markChanged()
    }
    inspector.install(second)
    #expect(rootChanged.hasChanged)
    #expect(inspector.dom.rootNode === second.rootNode)
    #expect(inspector.dom.selectedNode == nil)
}
