import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebKit

@MainActor
@Test
func modelContainerPublishesLatestOwnedLifecycleState() async throws {
    try await withDataKitTestRuntime { runtime in
        let container = WebInspectorModelContainer(
            configuration: .init(enabledFeatures: [])
        )
        var states = container.stateUpdates.makeAsyncIterator()

        #expect(await states.next() == .detached)
        try await container.attach(owning: runtime.proxy)

        guard case let .attached(generation) = await states.next() else {
            Issue.record("Expected the latest attached state.")
            await container.close()
            return
        }
        #expect(
            container.state
                == .attached(generation: generation)
        )

        await container.detach()
        #expect(await states.next() == .detached)
        #expect(container.state == .detached)

        await container.close()
        #expect(await states.next() == .closed)
        #expect(await states.next() == nil)

        var lateStates = container.stateUpdates.makeAsyncIterator()
        #expect(await lateStates.next() == .closed)
        #expect(await lateStates.next() == nil)
    }
}

@MainActor
@Test
func webViewAttachmentReservationHasOneContainerOwner() async throws {
    try await withDataKitTestRuntime { firstRuntime in
        try await withDataKitTestRuntime { secondRuntime in
            let webView = WKWebView()
            let otherWebView = WKWebView()
            let first = WebInspectorModelContainer(
                configuration: .init(enabledFeatures: [])
            )
            let second = WebInspectorModelContainer(
                configuration: .init(enabledFeatures: [])
            )

            try await first.attach(to: webView) { firstRuntime.proxy }

            let sameViewFactory = WebInspectorContextReply<Void>()
            try await first.attach(to: webView) {
                sameViewFactory.succeed(())
                return secondRuntime.proxy
            }
            #expect(sameViewFactory.isPending)

            let otherViewFactory = WebInspectorContextReply<Void>()
            await #expect(throws: WebInspectorAttachmentError.alreadyAttached) {
                try await first.attach(to: otherWebView) {
                    otherViewFactory.succeed(())
                    return secondRuntime.proxy
                }
            }
            #expect(otherViewFactory.isPending)

            let competingFactory = WebInspectorContextReply<Void>()
            await #expect(
                throws: WebInspectorAttachmentError.webViewAlreadyAttached
            ) {
                try await second.attach(to: webView) {
                    competingFactory.succeed(())
                    return secondRuntime.proxy
                }
            }
            #expect(competingFactory.isPending)

            await first.detach()
            try await second.attach(to: webView) { secondRuntime.proxy }
            await first.close()
            await second.close()
        }
    }
}

@MainActor
@Test
func connectionFailureRejectsReattachmentUntilOwnedTeardownCompletes()
    async throws
{
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom, .network])
    )

    try await withDataKitTestRuntime { firstRuntime in
        try await withDataKitTestRuntime { secondRuntime in
            try await queueDOMAndNetworkStartup(on: firstRuntime)
            let networkFailure = await firstRuntime.wire.deferFailure(
                to: "Page.getResourceTree",
                message: "injected required Network bootstrap failure"
            )
            await firstRuntime.wire.respond(to: "DOM.setInspectModeEnabled")
            let pickerRetirement = await firstRuntime.wire.deferReply(
                to: "DOM.setInspectModeEnabled"
            )
            await queueDOMAndNetworkTeardown(on: firstRuntime)

            try await container.attach(owning: firstRuntime.proxy)
            _ = await firstRuntime.wire.observations.waitForCommands(
                method: "Page.getResourceTree",
                count: 1
            )
            await waitForFeature(.dom, toBecomeReadyIn: container)

            let picker = Task { try await container.dom.pickElement() }
            _ = await firstRuntime.wire.observations.waitForCompletedCommands(
                method: "DOM.setInspectModeEnabled",
                count: 1
            )
            await waitForPicker(.active, in: container)

            networkFailure.open()
            _ = await firstRuntime.wire.observations.waitForCommands(
                method: "DOM.setInspectModeEnabled",
                count: 2
            )

            var rejectedDuringTeardown = false
            do {
                try await container.attach(owning: secondRuntime.proxy)
                Issue.record("A failing connection accepted a replacement attachment.")
            } catch let error as WebInspectorAttachmentError {
                #expect(error == .attachmentInProgress)
                rejectedDuringTeardown = error == .attachmentInProgress
            } catch {
                Issue.record("Expected attachmentInProgress, got \(error).")
            }

            pickerRetirement.open()
            await #expect(throws: WebInspectorCommandError.containerClosed) {
                _ = try await picker.value
            }

            guard rejectedDuringTeardown else {
                await container.close()
                return
            }

            let failure = await waitForConnectionFailure(in: container)
            guard case let .requiredFeature(featureID, .bootstrap(description)) = failure else {
                Issue.record("Expected a required Network bootstrap failure, got \(failure).")
                await container.close()
                return
            }
            #expect(featureID == .network)
            #expect(description.message.contains("injected required Network bootstrap failure"))

            try await queueDOMAndNetworkStartup(on: secondRuntime)
            await secondRuntime.wire.respond(
                to: "Page.getResourceTree",
                with: try connectionResourceTreeResult()
            )
            await secondRuntime.wire.respond(to: "Page.reload")
            await queueDOMAndNetworkTeardown(on: secondRuntime)

            try await container.attach(owning: secondRuntime.proxy)
            await waitForFeature(.dom, toBecomeReadyIn: container)
            await waitForFeature(.network, toBecomeReadyIn: container)
            try await container.page.reload()
            await container.close()
        }
    }
}

@MainActor
@Test
func detachJoinsConcurrentContainerCloseThroughContextRetirement()
    async
{
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [])
    )
    let context = container.mainContext
    let controlStarted = DataKitRawWireGate()
    let releaseControl = DataKitRawWireGate()
    #expect(
        context.lifecycle.ingress.enqueueControl(
            _WebInspectorContextControlOperation { _ in
                controlStarted.open()
                await releaseControl.waiter.wait()
            }
        )
    )
    await controlStarted.waiter.wait()

    let closeTask = Task { @MainActor in
        await container.close()
    }
    while container.state != .closing {
        await Task.yield()
    }

    let detachStarted = DataKitRawWireGate()
    let allowDetach = DataKitRawWireGate()
    let returnedState = ContainerStateRecorder()
    let detachTask = Task { @MainActor in
        detachStarted.open()
        await allowDetach.waiter.wait()
        await container.detach()
        await returnedState.record(container.state)
    }
    await detachStarted.waiter.wait()
    allowDetach.open()

    for _ in 0..<100 {
        if await returnedState.snapshot() != nil { break }
        await Task.yield()
    }
    #expect(await returnedState.snapshot() == nil)

    releaseControl.open()
    await closeTask.value
    await detachTask.value
    #expect(await returnedState.snapshot() == .closed)
    #expect(container.state == .closed)
}

@MainActor
@Test
func detachDuringAttachmentJoinsCandidateRetirement() async throws {
    try await withDataKitTestRuntime { runtime in
        let webView = WKWebView()
        let container = WebInspectorModelContainer(
            configuration: .init(enabledFeatures: [])
        )
        let factoryEntered = DataKitRawWireGate()
        let candidate = WebInspectorContextReply<WebInspectorProxy>()
        let attachment = Task { @MainActor in
            try await container.attach(to: webView) {
                factoryEntered.open()
                return try await candidate.value()
            }
        }
        await factoryEntered.waiter.wait()

        let returnedState = ContainerStateRecorder()
        let detach = Task { @MainActor in
            await container.detach()
            await returnedState.record(container.state)
        }
        while container.state != .detaching(generation: .init(rawValue: 1)) {
            await Task.yield()
        }
        for _ in 0..<100 {
            if await returnedState.snapshot() != nil { break }
            await Task.yield()
        }
        #expect(await returnedState.snapshot() == nil)

        candidate.succeed(runtime.proxy)
        await detach.value
        await #expect(throws: CancellationError.self) {
            try await attachment.value
        }
        #expect(await returnedState.snapshot() == .detached)
        try await runtime.proxy.waitUntilClosed()

        let replacement = WebInspectorModelContainer(
            configuration: .init(enabledFeatures: [])
        )
        let replacementFactory = WebInspectorContextReply<Void>()
        await #expect(throws: CancellationError.self) {
            try await replacement.attach(to: webView) {
                replacementFactory.succeed(())
                throw CancellationError()
            }
        }
        #expect(!replacementFactory.isPending)
        await replacement.close()
        await container.close()
    }
}

@MainActor
@Test
func closeDuringAttachmentJoinsCandidateRetirement() async throws {
    try await withDataKitTestRuntime { runtime in
        let webView = WKWebView()
        let container = WebInspectorModelContainer(
            configuration: .init(enabledFeatures: [])
        )
        let factoryEntered = DataKitRawWireGate()
        let candidate = WebInspectorContextReply<WebInspectorProxy>()
        let attachment = Task { @MainActor in
            try await container.attach(to: webView) {
                factoryEntered.open()
                return try await candidate.value()
            }
        }
        await factoryEntered.waiter.wait()

        let returnedState = ContainerStateRecorder()
        let close = Task { @MainActor in
            await container.close()
            await returnedState.record(container.state)
        }
        while container.state != .closing {
            await Task.yield()
        }
        for _ in 0..<100 {
            if await returnedState.snapshot() != nil { break }
            await Task.yield()
        }
        #expect(await returnedState.snapshot() == nil)

        candidate.succeed(runtime.proxy)
        await close.value
        await #expect(throws: WebInspectorAttachmentError.containerClosed) {
            try await attachment.value
        }
        #expect(await returnedState.snapshot() == .closed)
        try await runtime.proxy.waitUntilClosed()

        let replacement = WebInspectorModelContainer(
            configuration: .init(enabledFeatures: [])
        )
        let replacementFactory = WebInspectorContextReply<Void>()
        await #expect(throws: CancellationError.self) {
            try await replacement.attach(to: webView) {
                replacementFactory.succeed(())
                throw CancellationError()
            }
        }
        #expect(!replacementFactory.isPending)
        await replacement.close()
    }
}

@MainActor
private func queueDOMAndNetworkStartup(
    on runtime: DataKitTestRuntime
) async throws {
    await runtime.wire.respond(to: "Page.enable")
    await runtime.wire.respond(to: "Network.enable")
    await runtime.wire.respond(to: "Inspector.enable")
    await runtime.wire.respond(to: "Inspector.initialized")
    await runtime.wire.respond(to: "CSS.enable")
    await runtime.wire.respond(
        to: "DOM.getDocument",
        with: try domDocumentResult(
            DOM.Node(
                id: DOM.Node.ID("document"),
                nodeType: 9,
                nodeName: "#document",
                frameID: FrameID("main-frame")
            )
        )
    )
}

@MainActor
private func queueDOMAndNetworkTeardown(
    on runtime: DataKitTestRuntime
) async {
    await runtime.wire.respond(to: "Network.disable")
    await runtime.wire.respond(to: "CSS.disable")
    await runtime.wire.respond(to: "Inspector.disable")
    await runtime.wire.respond(to: "Page.disable")
}

private func waitForPicker(
    _ expected: WebInspectorElementPickerState,
    in container: WebInspectorModelContainer
) async {
    var states = container.dom.elementPickerStateUpdates.makeAsyncIterator()
    while let state = await states.next() {
        if state == expected { return }
    }
    preconditionFailure("The picker state stream closed before reaching \(expected).")
}

private func waitForFeature(
    _ featureID: WebInspectorFeatureID,
    toBecomeReadyIn container: WebInspectorModelContainer
) async {
    var states = container.featureStateUpdates(for: featureID)
        .makeAsyncIterator()
    while let state = await states.next() {
        if case .ready = state { return }
    }
    preconditionFailure("The \(featureID.name) state stream closed before becoming ready.")
}

private func waitForConnectionFailure(
    in container: WebInspectorModelContainer
) async -> WebInspectorConnectionFailure {
    var states = container.stateUpdates.makeAsyncIterator()
    while let state = await states.next() {
        if case let .failed(_, failure) = state { return failure }
    }
    preconditionFailure("The container state stream closed before publishing failure.")
}

private func connectionResourceTreeResult() throws
    -> WebInspectorTestJSONObject
{
    try testJSONObject(
        #"""
        {
          "frameTree": {
            "frame": {
              "id": "main-frame",
              "loaderId": "main-frame-loader",
              "name": "",
              "url": "https://example.test/",
              "mimeType": "text/html"
            },
            "resources": []
          }
        }
        """#
    )
}

private actor ContainerStateRecorder {
    private var state: WebInspectorModelContainer.State?

    func record(_ state: WebInspectorModelContainer.State) {
        self.state = state
    }

    func snapshot() -> WebInspectorModelContainer.State? {
        state
    }
}
