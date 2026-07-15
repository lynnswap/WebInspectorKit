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
func DOMBootstrapPreservesEveryEventReceivedBeforeTheDocumentReply() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )

    do {
        try await withDataKitTestRuntime { runtime in
            await runtime.wire.respond(to: "Page.enable")
            await runtime.wire.respond(to: "Inspector.enable")
            await runtime.wire.respond(to: "Inspector.initialized")
            await runtime.wire.respond(to: "CSS.enable")
            let documentReply = await runtime.wire.deferReply(
                to: "DOM.getDocument",
                with: try domDocumentResult(
                    DOM.Node(
                        id: DOM.Node.ID("document"),
                        nodeType: 9,
                        nodeName: "#document",
                        frameID: FrameID("main-frame"),
                        childNodeCount: 1,
                        children: [
                            DOM.Node(
                                id: DOM.Node.ID("body"),
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

            try await container.attach(owning: runtime.proxy)
            _ = await runtime.wire.observations.waitForCommands(
                method: "DOM.getDocument",
                count: 1
            )

            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "DOM.attributeModified",
                parameters: try testJSONObject(
                    #"{"nodeId":"body","name":"data-burst","value":"preserved"}"#
                )
            )
            for index in 0..<2_049 {
                try await runtime.wire.emitTargetEvent(
                    targetID: "page-main",
                    method: "DOM.futureBurstEvent",
                    parameters: try testJSONObject(
                        #"{"index":\#(index)}"#
                    )
                )
            }
            documentReply.open()

            #expect(await waitForDOMReady(in: container))
            if case .attached = container.state {
                // Expected.
            } else {
                Issue.record("DOM bootstrap burst terminated the attachment.")
            }
            await container.close()
        }
    } catch {
        await container.close()
        throw error
    }
}

@MainActor
@Test
func DOMEventForAnUnmaterializedNodeDoesNotTerminateTheAttachment() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareDOMAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            #expect(await waitForDOMReady(in: container))
            let initialRevision = try #require(domReadyRevision(container.dom.state))

            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "DOM.willDestroyDOMNode",
                parameters: try testJSONObject(#"{"nodeId":"unmaterialized"}"#)
            )
            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "DOM.attributeModified",
                parameters: try testJSONObject(
                    #"{"nodeId":"body","name":"data-after-unknown","value":"preserved"}"#
                )
            )

            #expect(await waitForDOMRevision(after: initialRevision, in: container))
            if case .attached = container.state {
                // Expected.
            } else {
                Issue.record("An event for an unmaterialized DOM node terminated the attachment.")
            }
            await container.close()
        }
    } catch {
        await container.close()
        throw error
    }
}

@MainActor
@Test
func ordinaryDocumentNavigationAdvancesOnlyTheDOMBindingEpoch() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )
    let results = WebInspectorFetchedResultsController<DOMNode>(
        modelContext: container.mainContext
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareDOMAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            #expect(await waitForDOMReady(in: container))
            try await results.performFetch()
            let initialScope = try #require(
                results.fetchedObjects?.first?.id.canonicalStorage.documentScope
            )

            let nextDocumentReply = await runtime.wire.deferReply(
                to: "DOM.getDocument",
                with: try domDocumentResult(
                    DOM.Node(
                        id: DOM.Node.ID("next-document"),
                        nodeType: 9,
                        nodeName: "#document",
                        frameID: FrameID("main-frame"),
                        childNodeCount: 1,
                        children: [
                            DOM.Node(
                                id: DOM.Node.ID("next-body"),
                                nodeType: 1,
                                nodeName: "BODY",
                                localName: "body"
                            )
                        ]
                    )
                )
            )
            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "DOM.documentUpdated"
            )
            _ = await runtime.wire.observations.waitForCommands(
                method: "DOM.getDocument",
                count: 2
            )
            nextDocumentReply.open()

            #expect(
                await waitForDOMRawIDs(
                    ["next-document", "next-body"],
                    in: results
                )
            )
            let nextObjects = try #require(results.fetchedObjects)
            let nextScope = try #require(
                nextObjects.first?.id.canonicalStorage.documentScope
            )
            #expect(nextScope.attachmentGeneration == initialScope.attachmentGeneration)
            #expect(nextScope.pageGeneration == initialScope.pageGeneration)
            #expect(
                nextScope.domBindingEpoch.rawValue
                    == initialScope.domBindingEpoch.rawValue + 1
            )
            #expect(nextObjects.allSatisfy {
                $0.id.canonicalStorage.documentScope == nextScope
            })
            for method in ["Page.enable", "Inspector.enable", "CSS.enable"] {
                #expect(runtime.wire.observations.commandMethods.filter {
                    $0 == method
                }.count == 1)
            }

            await results.close()
            await container.close()
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
func pickerCarriesInspectAcrossOrdinaryDocumentBootstrap() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareDOMAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            #expect(await waitForDOMReady(in: container))

            await runtime.wire.respond(to: "DOM.setInspectModeEnabled")
            let nextDocumentReply = await runtime.wire.deferReply(
                to: "DOM.getDocument",
                with: try domDocumentResult(
                    DOM.Node(
                        id: DOM.Node.ID("next-document"),
                        nodeType: 9,
                        nodeName: "#document",
                        frameID: FrameID("main-frame"),
                        childNodeCount: 1,
                        children: [
                            DOM.Node(
                                id: DOM.Node.ID("next-body"),
                                nodeType: 1,
                                nodeName: "BODY",
                                localName: "body"
                            )
                        ]
                    )
                )
            )
            let selection = Task {
                try await container.dom.pickElement()
            }
            _ = await runtime.wire.observations.waitForCompletedCommands(
                method: "DOM.setInspectModeEnabled",
                count: 1
            )
            #expect(await waitForPickerState(.active, in: container))

            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "DOM.documentUpdated"
            )
            _ = await runtime.wire.observations.waitForCommands(
                method: "DOM.getDocument",
                count: 2
            )
            try await emitDOMInspect(
                bodyID: "next-body",
                through: runtime.wire
            )
            nextDocumentReply.open()

            #expect(rawDOMNodeID(try await selection.value) == "next-body")
            #expect(container.dom.elementPickerState == .idle)
            #expect(runtime.wire.observations.commandMethods.filter {
                $0 == "Page.enable"
            }.count == 1)
            await container.close()
        }
    } catch {
        await container.close()
        throw error
    }
}

@MainActor
@Test
func inspectorPickerWaitsForRequestNodePathCommitBeforePublishingSelection() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareDOMAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            #expect(await waitForDOMReady(in: container))

            await runtime.wire.respond(to: "DOM.setInspectModeEnabled")
            let requestNodeReply = await runtime.wire.deferReply(
                to: "DOM.requestNode",
                with: try testJSONObject(#"{"nodeId":"deep-node"}"#)
            )
            let selection = Task {
                try await container.dom.pickElement()
            }
            _ = await runtime.wire.observations.waitForCompletedCommands(
                method: "DOM.setInspectModeEnabled",
                count: 1
            )
            #expect(await waitForPickerState(.active, in: container))

            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "Inspector.inspect",
                parameters: try testJSONObject(
                    #"{"object":{"objectId":"remote-node","type":"object","subtype":"node"},"hints":{}}"#
                )
            )
            _ = await runtime.wire.observations.waitForCommands(
                method: "DOM.requestNode",
                count: 1
            )
            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "DOM.setChildNodes",
                parameters: try testJSONObject(
                    #"{"parentId":"body","nodes":[{"nodeId":"deep-node","nodeType":1,"nodeName":"SPAN","localName":"span","nodeValue":"","childNodeCount":0}]}"#
                )
            )
            requestNodeReply.open()

            #expect(rawDOMNodeID(try await selection.value) == "deep-node")
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
func ordinaryDocumentNavigationRejectsTheOldPickerResolutionAndIgnoresItsLateReply() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareDOMAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            #expect(await waitForDOMReady(in: container))

            await runtime.wire.respond(to: "DOM.setInspectModeEnabled")
            let requestNodeReply = await runtime.wire.deferReply(
                to: "DOM.requestNode",
                with: try testJSONObject(#"{"nodeId":"body"}"#)
            )
            await runtime.wire.respond(
                to: "DOM.getDocument",
                with: try domDocumentResult(
                    DOM.Node(
                        id: DOM.Node.ID("next-document"),
                        nodeType: 9,
                        nodeName: "#document",
                        frameID: FrameID("main-frame"),
                        childNodeCount: 0
                    )
                )
            )
            let selection = Task {
                try await container.dom.pickElement()
            }
            _ = await runtime.wire.observations.waitForCompletedCommands(
                method: "DOM.setInspectModeEnabled",
                count: 1
            )
            #expect(await waitForPickerState(.active, in: container))

            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "Inspector.inspect",
                parameters: try testJSONObject(
                    #"{"object":{"objectId":"old-remote-node","type":"object","subtype":"node"},"hints":{}}"#
                )
            )
            _ = await runtime.wire.observations.waitForCommands(
                method: "DOM.requestNode",
                count: 1
            )
            #expect(await waitForPickerState(.resolvingSelection, in: container))

            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "DOM.documentUpdated"
            )
            do {
                _ = try await selection.value
                Issue.record("The old-document picker resolution unexpectedly succeeded.")
            } catch let error as WebInspectorElementPickerError {
                guard case .selectionResolutionFailed = error else {
                    Issue.record("Unexpected picker error: \(error)")
                    await container.close()
                    return
                }
            }
            #expect(container.dom.elementPickerState == .idle)
            #expect(await waitForDOMReady(in: container))

            requestNodeReply.open()
            for _ in 0..<10 { await Task.yield() }
            #expect(runtime.wire.observations.commandMethods.filter {
                $0 == "DOM.highlightNode"
            }.isEmpty)
            await container.close()
        }
    } catch {
        await container.close()
        throw error
    }
}

@MainActor
@Test
func frameDocumentUpdatedDoesNotInvalidateTheMainDocumentBinding() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareDOMAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            #expect(await waitForDOMReady(in: container))
            let initialRevision = try #require(domReadyRevision(container.dom.state))

            await runtime.wire.respond(to: "CSS.enable")
            await runtime.wire.respond(to: "CSS.disable")
            try await runtime.peer.createTarget(
                .init(
                    id: "frame-one",
                    type: "web-page",
                    frameID: "child-frame",
                    parentFrameID: "main-frame"
                )
            )
            _ = await runtime.wire.observations.waitForCompletedCommands(
                method: "CSS.enable",
                count: 2
            )

            try await runtime.wire.emitTargetEvent(
                targetID: "frame-one",
                method: "DOM.documentUpdated"
            )
            try await runtime.wire.emitTargetEvent(
                targetID: "page-main",
                method: "DOM.attributeModified",
                parameters: try testJSONObject(
                    #"{"nodeId":"body","name":"data-after-frame-update","value":"yes"}"#
                )
            )

            #expect(await waitForDOMRevision(after: initialRevision, in: container))
            #expect(runtime.wire.observations.commandMethods.filter {
                $0 == "DOM.getDocument"
            }.count == 1)
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
@Test
func pickerDisableFailureSendsOnceAndKeepsBackendActiveForTheNextIntent() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.dom])
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareDOMAttachment(runtime)
            try await container.attach(owning: runtime.proxy)
            #expect(await waitForDOMReady(in: container))

            await runtime.wire.respond(to: "DOM.setInspectModeEnabled")
            let selection = Task {
                try await container.dom.pickElement()
            }
            _ = await runtime.wire.observations.waitForCompletedCommands(
                method: "DOM.setInspectModeEnabled",
                count: 1
            )
            #expect(await waitForPickerState(.active, in: container))

            await runtime.wire.fail(
                "DOM.setInspectModeEnabled",
                message: "disable rejected"
            )
            selection.cancel()
            _ = await runtime.wire.observations.waitForCompletedCommands(
                method: "DOM.setInspectModeEnabled",
                count: 2
            )
            do {
                _ = try await selection.value
                Issue.record("Picker cancellation unexpectedly succeeded.")
            } catch let error as WebInspectorElementPickerError {
                guard case .disableFailed = error else {
                    Issue.record("Unexpected picker error: \(error)")
                    await container.close()
                    return
                }
            }
            #expect(container.dom.elementPickerState == .active)
            let firstIntentCommands = runtime.wire.observations.commands.filter {
                $0.method == "DOM.setInspectModeEnabled"
            }
            #expect(firstIntentCommands.count == 2)

            await runtime.wire.respond(to: "DOM.setInspectModeEnabled")
            await container.dom.cancelElementPicker()
            _ = await runtime.wire.observations.waitForCompletedCommands(
                method: "DOM.setInspectModeEnabled",
                count: 3
            )
            #expect(await waitForPickerState(.idle, in: container))
            let parameters = try runtime.wire.observations.commands.filter {
                $0.method == "DOM.setInspectModeEnabled"
            }.map {
                try $0.parameters.decode(PickerEnabledParameter.self).enabled
            }
            #expect(parameters == [true, false, false])
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
    for _ in 0..<10_000 {
        if case .ready = container.dom.state {
            return true
        }
        if case .failed = container.state {
            return false
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForDOMRevision(
    after revision: UInt64,
    in container: WebInspectorModelContainer
) async -> Bool {
    for _ in 0..<1_000 {
        if let current = domReadyRevision(container.dom.state), current > revision {
            return true
        }
        await Task.yield()
    }
    return false
}

private func domReadyRevision(
    _ state: WebInspectorFeatureState
) -> UInt64? {
    guard case let .ready(_, revision) = state else { return nil }
    return revision.rawValue
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
