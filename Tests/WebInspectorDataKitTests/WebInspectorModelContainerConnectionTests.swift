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
func networkBootstrapFailureFailsTheConnection() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom, .network])
    )

    try await withDataKitTestRuntime { runtime in
        try await queueDOMAndNetworkStartup(on: runtime)
        let networkFailure = await runtime.wire.deferFailure(
            to: "Page.getResourceTree",
            message: "injected Network bootstrap failure"
        )
        await queueDOMAndNetworkTeardown(on: runtime)

        try await container.attach(owning: runtime.proxy)
        _ = await runtime.wire.observations.waitForCommands(
            method: "Page.getResourceTree",
            count: 1
        )
        await waitForFeature(.dom, toBecomeReadyIn: container)

        networkFailure.open()
        let description = await waitForContainerFailure(in: container)
        #expect(description.message.contains("injected Network bootstrap failure"))
        guard case .failed = container.state else {
            Issue.record("Network bootstrap failure did not fail the connection: \(container.state).")
            await container.close()
            return
        }
        #expect(container.dom.state == .disabled)
        #expect(container.network.state == .disabled)

        await container.close()
    }
}

@MainActor
@Test
func unsupportedNetworkCapabilityDoesNotFailSiblingFeatures() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom, .network])
    )

    try await withDataKitTestRuntime { runtime in
        try await queueDOMAndNetworkStartup(on: runtime)
        let networkUnsupported = await runtime.wire.deferFailure(
            to: "Page.getResourceTree",
            code: -32_601,
            message: "'Page.getResourceTree' was not found"
        )
        await queueDOMAndNetworkTeardown(on: runtime)

        try await container.attach(owning: runtime.proxy)
        _ = await runtime.wire.observations.waitForCommands(
            method: "Page.getResourceTree",
            count: 1
        )
        await waitForFeature(.dom, toBecomeReadyIn: container)

        networkUnsupported.open()
        let requirements = await waitForFeatureToBecomeUnsupported(
            .network,
            in: container
        )
        #expect(requirements == ["Page.getResourceTree"])
        guard case .attached = container.state else {
            Issue.record(
                "Static Network unsupported state failed the container: \(container.state)."
            )
            await container.close()
            return
        }
        guard case .ready = container.dom.state else {
            Issue.record("DOM did not remain ready: \(container.dom.state).")
            await container.close()
            return
        }
        await #expect(
            throws: WebInspectorFetchError.featureUnsupported(
                .network,
                requirements: ["Page.getResourceTree"]
            )
        ) {
            _ = try await container.mainContext.fetchIdentifiers(
                WebInspectorFetchDescriptor<NetworkEntry>()
            )
        }

        await container.close()
    }
}

@MainActor
@Test
func networkBootstrapRemainsAttachedAcrossALargePreBootstrapEventBurst() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.network])
    )

    try await withDataKitTestRuntime { runtime in
        await runtime.wire.respond(to: "Page.enable")
        await runtime.wire.respond(to: "Network.enable")
        let resourceTreeReply = await runtime.wire.deferReply(
            to: "Page.getResourceTree",
            with: try connectionResourceTreeResult()
        )
        await runtime.wire.respond(to: "Network.disable")
        await runtime.wire.respond(to: "Page.disable")

        let attachment = Task {
            try await container.attach(owning: runtime.proxy)
        }
        _ = await runtime.wire.observations.waitForCommands(
            method: "Page.getResourceTree",
            count: 1
        )

        for index in 0..<4_097 {
            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "Page.loadEventFired",
                parameters: try testJSONObject(
                    #"{"timestamp":\#(index)}"#
                )
            )
        }
        resourceTreeReply.open()
        try await attachment.value
        #expect(
            await featureBecameReady(
                .network,
                in: container
            )
        )

        if case .attached = container.state {
            // Expected.
        } else {
            Issue.record("Network bootstrap burst terminated the attachment.")
        }
        await container.close()
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

@MainActor
private func featureBecameReady(
    _ featureID: WebInspectorFeatureID,
    in container: WebInspectorModelContainer
) async -> Bool {
    for _ in 0..<10_000 {
        if case .ready = container.featureState(for: featureID) {
            return true
        }
        if case .failed = container.state {
            return false
        }
        await Task.yield()
    }
    return false
}

private func waitForFeatureToBecomeUnsupported(
    _ featureID: WebInspectorFeatureID,
    in container: WebInspectorModelContainer
) async -> [String] {
    var states = container.featureStateUpdates(for: featureID)
        .makeAsyncIterator()
    while let state = await states.next() {
        if case let .unsupported(requirements) = state {
            return requirements
        }
    }
    preconditionFailure(
        "The \(featureID.name) state stream closed before becoming unsupported."
    )
}

private func waitForContainerFailure(
    in container: WebInspectorModelContainer
) async -> WebInspectorFailureDescription {
    var states = container.stateUpdates.makeAsyncIterator()
    while let state = await states.next() {
        if case let .failed(_, .native(description)) = state {
            return description
        }
    }
    preconditionFailure(
        "The container state stream closed before publishing connection failure."
    )
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
