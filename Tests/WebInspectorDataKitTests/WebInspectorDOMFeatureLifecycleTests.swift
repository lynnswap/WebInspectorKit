import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit

@MainActor
@Test
func DOMReattachmentAtomicallyReplacesThePreviousAttachmentRecords() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )
    let results = WebInspectorFetchedResultsController<DOMNode>(
        modelContext: container.mainContext
    )

    do {
        try await withDataKitTestRuntime { firstRuntime in
            try await prepareDOMAttachment(
                firstRuntime,
                documentID: "first-document",
                bodyID: "first-body"
            )
            try await container.attach(owning: firstRuntime.proxy)
            try await results.performFetch()

            let firstObjects = try #require(results.fetchedObjects)
            #expect(Set(firstObjects.map(rawDOMNodeID)) == ["first-document", "first-body"])
            let firstGeneration = try #require(
                firstObjects.first?.id.canonicalStorage.documentScope.attachmentGeneration
            )

            await container.detach()

            try await withDataKitTestRuntime { secondRuntime in
                try await prepareDOMAttachment(
                    secondRuntime,
                    documentID: "second-document",
                    bodyID: "second-body"
                )
                try await container.attach(owning: secondRuntime.proxy)

                #expect(
                    await waitForDOMRawIDs(
                        ["second-document", "second-body"],
                        in: results
                    )
                )
                let secondObjects = try #require(results.fetchedObjects)
                #expect(
                    Set(secondObjects.map(rawDOMNodeID))
                        == ["second-document", "second-body"]
                )
                #expect(
                    secondObjects.allSatisfy {
                        $0.id.canonicalStorage.documentScope.attachmentGeneration
                            != firstGeneration
                    }
                )

                await results.close()
                await container.close()
            }
        }
    } catch {
        await results.close()
        await container.close()
        throw error
    }
}

@MainActor
@Test
func pickerConsumesInspectThatArrivesBeforeTheEnableReplyAndCanReenable() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareDOMAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            #expect(await waitForDOMReady(in: container))

            let enableReply = await runtime.wire.deferReply(
                to: "DOM.setInspectModeEnabled"
            )
            let firstSelection = Task {
                try await container.dom.pickElement()
            }
            _ = await runtime.wire.observations.waitForCommands(
                method: "DOM.setInspectModeEnabled",
                count: 1
            )
            try await emitDOMInspect(bodyID: "body", through: runtime.wire)
            #expect(
                await waitForPickerState(
                    .resolvingSelection,
                    in: container
                )
            )

            enableReply.open()
            #expect(rawDOMNodeID(try await firstSelection.value) == "body")
            #expect(container.dom.elementPickerState == .idle)

            await runtime.wire.respond(to: "DOM.setInspectModeEnabled")
            let secondSelection = Task {
                try await container.dom.pickElement()
            }
            _ = await runtime.wire.observations.waitForCompletedCommands(
                method: "DOM.setInspectModeEnabled",
                count: 2
            )
            #expect(await waitForPickerState(.active, in: container))
            try await emitDOMInspect(bodyID: "body", through: runtime.wire)

            #expect(rawDOMNodeID(try await secondSelection.value) == "body")
            #expect(container.dom.elementPickerState == .idle)
            await container.close()
        }
    } catch {
        await container.close()
        throw error
    }
}

@MainActor
@Test
func pickerCancellationAfterEarlyInspectDoesNotWaitForTheEnableReply() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareDOMAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            #expect(await waitForDOMReady(in: container))

            let enableReply = await runtime.wire.deferReply(
                to: "DOM.setInspectModeEnabled"
            )
            let selection = Task {
                try await container.dom.pickElement()
            }
            _ = await runtime.wire.observations.waitForCommands(
                method: "DOM.setInspectModeEnabled",
                count: 1
            )
            try await emitDOMInspect(bodyID: "body", through: runtime.wire)
            #expect(
                await waitForPickerState(
                    .resolvingSelection,
                    in: container
                )
            )

            selection.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await selection.value
            }
            #expect(container.dom.elementPickerState == .idle)

            enableReply.open()
            await container.close()
        }
    } catch {
        await container.close()
        throw error
    }
}

@MainActor
@Test
func pickerCallerCancellationDuringEnableJoinsReplyAndDisablesBackend() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareDOMAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            #expect(await waitForDOMReady(in: container))

            let enableReply = await runtime.wire.deferReply(
                to: "DOM.setInspectModeEnabled"
            )
            await runtime.wire.respond(to: "DOM.setInspectModeEnabled")
            let selection = Task {
                try await container.dom.pickElement()
            }
            _ = await runtime.wire.observations.waitForCommands(
                method: "DOM.setInspectModeEnabled",
                count: 1
            )

            selection.cancel()
            #expect(await waitForPickerState(.disabling, in: container))
            #expect(
                runtime.wire.observations.commands.filter {
                    $0.method == "DOM.setInspectModeEnabled"
                }.count == 1
            )

            enableReply.open()
            await #expect(throws: CancellationError.self) {
                _ = try await selection.value
            }

            let pickerCommands = runtime.wire.observations.commands.filter {
                $0.method == "DOM.setInspectModeEnabled"
            }
            #expect(
                try pickerCommands.map {
                    try $0.parameters.decode(PickerEnabledParameter.self).enabled
                } == [true, false]
            )
            #expect(container.dom.elementPickerState == .idle)
            await container.close()
        }
    } catch {
        await container.close()
        throw error
    }
}

@MainActor
private func prepareDOMAttachment(
    _ runtime: DataKitTestRuntime,
    documentID: String = "document",
    bodyID: String = "body"
) async throws {
    await runtime.wire.respond(to: "Page.enable")
    await runtime.wire.respond(to: "Inspector.enable")
    await runtime.wire.respond(to: "Inspector.initialized")
    await runtime.wire.respond(to: "CSS.enable")
    await runtime.wire.respond(
        to: "DOM.getDocument",
        with: try domDocumentResult(
            DOM.Node(
                id: DOM.Node.ID(documentID),
                nodeType: 9,
                nodeName: "#document",
                frameID: FrameID("main-frame"),
                childNodeCount: 1,
                children: [
                    DOM.Node(
                        id: DOM.Node.ID(bodyID),
                        nodeType: 1,
                        nodeName: "BODY",
                        localName: "body"
                    )
                ]
            )
        )
    )
    await runtime.wire.respond(to: "CSS.disable")
    await runtime.wire.respond(to: "Inspector.disable")
    await runtime.wire.respond(to: "Page.disable")
}

@MainActor
private func waitForDOMReady(
    in container: WebInspectorModelContainer
) async -> Bool {
    for _ in 0..<1_000 {
        if case .ready = container.dom.state {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForDOMRawIDs(
    _ expected: Set<String>,
    in results: WebInspectorFetchedResultsController<DOMNode>
) async -> Bool {
    for _ in 0..<1_000 {
        if Set((results.fetchedObjects ?? []).map(rawDOMNodeID)) == expected {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForPickerState(
    _ expected: WebInspectorElementPickerState,
    in container: WebInspectorModelContainer
) async -> Bool {
    for _ in 0..<1_000 {
        if container.dom.elementPickerState == expected {
            return true
        }
        await Task.yield()
    }
    return false
}

private func emitDOMInspect(
    bodyID: String,
    through wire: DataKitRawWireDriver
) async throws {
    try await wire.emitTargetEvent(
        targetID: "page-main",
        method: "DOM.inspect",
        parameters: try testJSONObject(#"{"nodeId":"\#(bodyID)"}"#)
    )
}

private func rawDOMNodeID(_ node: DOMNode) -> String {
    rawDOMNodeID(node.id)
}

private func rawDOMNodeID(_ id: DOMNode.ID) -> String {
    id.canonicalStorage.rawNodeID.rawValue
}

private struct PickerEnabledParameter: Decodable {
    let enabled: Bool
}
