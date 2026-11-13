import Foundation
import Observation
import ObservationBridge
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

@MainActor
@Test
func runtimeEnableReplayIsCapturedBeforeCommandReturns() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let enableGate = WebInspectorTestGate()
    let contextID = Runtime.ExecutionContext.ID("main")

    await runtime.backend.hold(domain: "Runtime", method: "enable", gate: enableGate)
    await enqueueStartupReplies(on: runtime.backend)

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    try await waitForRecordedCommands(on: runtime.backend, expected: [
            RecordedCommand(domain: "Inspector", method: "enable"),
            RecordedCommand(domain: "Inspector", method: "initialized"),
            RecordedCommand(domain: "Page", method: "enable"),
            RecordedCommand(domain: "Runtime", method: "enable")
        ])

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(id: contextID, name: "Main", kind: .normal)),
        target: target
    )
    try await waitUntil(in: context) {
        context.executionContexts.first?.id == RuntimeContext.ID(contextID)
    }

    await enableGate.open()
    try await waitUntil(in: context) { context.state == .attached }
    #expect(context.selectedContext?.id == RuntimeContext.ID(contextID))
}

@MainActor
@Test
func consoleEnableReplayIsCapturedBeforeCommandReturns() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let target = try await runtime.proxy.waitForCurrentPage()
    let enableGate = WebInspectorTestGate()

    await runtime.backend.hold(domain: "Console", method: "enable", gate: enableGate)
    await enqueueStartupReplies(on: runtime.backend)

    let container = WebInspectorContainer(proxy: runtime.proxy)
    let context = container.mainContext
    let results: WebInspectorFetchedResults<ConsoleMessage> = context.console.fetchedResults()
    try await waitForRecordedCommands(on: runtime.backend, expected: startupCommands)

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "replayed"
        )),
        target: target
    )
    try await waitUntil { results.items.map(\.text) == ["replayed"] }

    await enableGate.open()
    try await waitUntil(in: context) { context.state == .attached }
    #expect(results.items.map(\.text) == ["replayed"])
}

@MainActor
@Test
func transportBackedStartupCapturesRuntimeAndConsoleReplayBeforeEnableReplies() async throws {
    let backend = FakeTransportBackend()
    let transport = TransportSession(backend: backend)
    await installTransportPageTarget(in: transport, targetID: ProtocolTarget.ID("page-main"))
    let proxy = try await WebInspectorProxy(transport: transport)
    let target = try await proxy.waitForCurrentPage()
    #expect(target.id == .currentPage)
    let container = WebInspectorContainer(proxy: proxy)
    let context = container.mainContext
    let consoleResults: WebInspectorFetchedResults<ConsoleMessage> = context.console.fetchedResults()

    try await replyTransportInspectorAndPageInitialization(backend, transport: transport, targetID: ProtocolTarget.ID("page-main"))

    let runtimeEnable = try await waitForTransportTargetMessage(backend, method: "Runtime.enable")
    await receiveTransportTargetEvent(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        method: "Runtime.executionContextCreated",
        params: #"{"context":{"id":11,"name":"Main","frameId":"main-frame","type":"normal"}}"#
    )
    try await waitUntil(in: context) {
        context.executionContexts.first?.id == RuntimeContext.ID(Runtime.ExecutionContext.ID("11"))
    }
    await receiveTransportTargetReply(
        transport,
        targetID: runtimeEnable.targetIdentifier,
        messageID: try transportMessageID(runtimeEnable.message),
        result: "{}"
    )

    let networkEnable = try await waitForTransportTargetMessage(backend, method: "Network.enable")
    await receiveTransportTargetReply(
        transport,
        targetID: networkEnable.targetIdentifier,
        messageID: try transportMessageID(networkEnable.message),
        result: "{}"
    )

    try await replyTransportResourceTreeUnavailable(backend, transport: transport)

    let getDocument = try await waitForTransportTargetMessage(backend, method: "DOM.getDocument")
    await receiveTransportTargetReply(
        transport,
        targetID: getDocument.targetIdentifier,
        messageID: try transportMessageID(getDocument.message),
        result: ##"{"root":{"nodeId":1,"nodeType":9,"nodeName":"#document","localName":"","nodeValue":"","frameId":"main-frame","childNodeCount":0}}"##
    )

    let consoleEnable = try await waitForTransportTargetMessage(backend, method: "Console.enable")
    await receiveTransportTargetEvent(
        transport,
        targetID: consoleEnable.targetIdentifier,
        method: "Console.messageAdded",
        params: #"{"message":{"source":"console-api","level":"warning","text":"replayed","repeatCount":1}}"#
    )
    try await waitUntil { consoleResults.items.map(\.text) == ["replayed"] }
    await receiveTransportTargetReply(
        transport,
        targetID: consoleEnable.targetIdentifier,
        messageID: try transportMessageID(consoleEnable.message),
        result: "{}"
    )

    try await waitUntil(in: context) { context.state == .attached }
    #expect(context.rootNode?.id == DOMNode.ID(DOM.Node.ID("1")))
    #expect(context.selectedContext?.id == RuntimeContext.ID(Runtime.ExecutionContext.ID("11")))
    #expect(consoleResults.items.map(\.text) == ["replayed"])
}

@MainActor
@Test
func transportBackedFrameRuntimeAndConsoleEventsKeepTargetScope() async throws {
    let pageTargetID = ProtocolTarget.ID("page-main")
    let frameTargetID = ProtocolTarget.ID("frame-42-7")
    let frameTarget = WebInspectorTarget.ID(frameTargetID.rawValue)
    let scopedContextID = Runtime.ExecutionContext.ID("7", scopedToTargetRawValue: frameTargetID.rawValue)
    let (backend, transport, context) = try await startTransportBackedContext(
        targetID: pageTargetID,
        documentID: "1",
        protocolProfile: .latest
    )
    let consoleResults: WebInspectorFetchedResults<ConsoleMessage> = context.console.fetchedResults()
    let startupMessageCount = await backend.sentTargetMessages().count

    await installTransportFrameTarget(
        in: transport,
        pageTargetID: pageTargetID,
        targetID: frameTargetID,
        frameID: "frame-7.42",
        parentFrameID: "main-frame"
    )
    await receiveTransportTargetEvent(
        transport,
        targetID: frameTargetID,
        method: "Runtime.executionContextCreated",
        params: #"{"context":{"id":7,"name":"Frame","frameId":"frame-7.42","type":"normal"}}"#
    )
    try await waitUntil(in: context) {
        context.executionContexts.contains { $0.id == RuntimeContext.ID(scopedContextID) }
    }
    let frameContext = try #require(context.executionContexts.first { $0.id == RuntimeContext.ID(scopedContextID) })

    var capturedEvaluation: RuntimeEvaluation?
    let evaluationTask = Task { @MainActor in
        capturedEvaluation = try await context.runtime.evaluate("window", in: frameContext)
    }
    let evaluate = try await waitForTransportTargetMessage(
        backend,
        method: "Runtime.evaluate",
        after: startupMessageCount
    )
    #expect(evaluate.targetIdentifier == frameTargetID)
    let evaluateParameters = try transportTargetMessageParameters(evaluate.message)
    #expect(evaluateParameters["contextId"] as? Int == 7)
    await receiveTransportTargetReply(
        transport,
        targetID: evaluate.targetIdentifier,
        messageID: try transportMessageID(evaluate.message),
        result: #"{"result":{"type":"object","objectId":"frame-evaluation-object","description":"frame object"}}"#
    )
    try await evaluationTask.value
    let evaluation = try #require(capturedEvaluation)
    #expect(evaluation.object.proxyID?.targetScopeRawValue == frameTargetID.rawValue)
    #expect(evaluation.object.proxyID?.unscopedRawValue == "frame-evaluation-object")

    await receiveTransportTargetEvent(
        transport,
        targetID: frameTargetID,
        method: "Console.messageAdded",
        params: #"{"message":{"source":"console-api","level":"log","text":"frame log","networkRequestId":"frame-request-77","parameters":[{"type":"object","objectId":"frame-console-object","description":"console object"}],"repeatCount":1}}"#
    )
    try await waitUntil { consoleResults.items.map(\.text) == ["frame log"] }
    let consoleMessage = try #require(consoleResults.items.first)
    #expect(consoleMessage.targetID == frameTarget)
    #expect(consoleMessage.networkRequestID == NetworkRequest.ID(
        Network.Request.ID("frame-request-77", scopedToTargetRawValue: frameTargetID.rawValue)
    ))
    let consoleObject = try #require(consoleMessage.parameters.first)
    #expect(consoleObject.proxyID?.targetScopeRawValue == frameTargetID.rawValue)
    #expect(consoleObject.proxyID?.unscopedRawValue == "frame-console-object")
}

@MainActor
@Test
func consoleMessagesClearedForDistinctTargetsDoNotSendRuntimeCommands() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let commandCountBeforeClear = await runtime.backend.recordedCommands().count

    context.apply(
        Console.Event.messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        targetID: WebInspectorTarget.ID("console-frame-a")
    )
    context.apply(
        Console.Event.messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        targetID: WebInspectorTarget.ID("console-frame-b")
    )

    let clearCommands = await runtime.backend.recordedCommands().dropFirst(commandCountBeforeClear)
    #expect(!clearCommands.contains(RecordedCommand(domain: "Runtime", method: "releaseObjectGroup")))
}

@MainActor
@Test
func restartClearsRuntimeContextsBeforeEnableReplay() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let staleID = Runtime.ExecutionContext.ID("stale")
    let replayID = Runtime.ExecutionContext.ID("replayed")
    let enableGate = WebInspectorTestGate()

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(id: staleID, name: "Stale", kind: .normal)),
        target: target
    )
    try await waitUntil(in: context) {
        context.executionContexts.first?.id == RuntimeContext.ID(staleID)
    }

    await runtime.backend.hold(domain: "Runtime", method: "enable", gate: enableGate)
    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("restarted-document"), nodeType: 9, nodeName: "#document")
    )

    context.start()
    try await waitForRecordedCommands(on: runtime.backend, expected: startupCommands + shutdownCommands + [
            RecordedCommand(domain: "Inspector", method: "enable"),
            RecordedCommand(domain: "Inspector", method: "initialized"),
            RecordedCommand(domain: "Page", method: "enable"),
            RecordedCommand(domain: "Runtime", method: "enable"),
        ])
    #expect(context.executionContexts.isEmpty)
    #expect(context.selectedContext == nil)

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(id: replayID, name: "Replayed", kind: .normal)),
        target: target
    )
    try await waitUntil(in: context) {
        context.executionContexts.map(\.id) == [RuntimeContext.ID(replayID)]
    }

    await enableGate.open()
    try await waitUntil(in: context) { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restarted-document")) }
    #expect(context.selectedContext?.id == RuntimeContext.ID(replayID))
}

@MainActor
@Test
func restartClearsConsoleMessagesBeforeConsoleReplay() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let results: WebInspectorFetchedResults<ConsoleMessage> = context.console.fetchedResults()
    let enableGate = WebInspectorTestGate()

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "old"
        )),
        target: target
    )
    try await waitUntil { results.items.map(\.text) == ["old"] }

    await runtime.backend.hold(domain: "Console", method: "enable", gate: enableGate)
    await enqueueDomainDisableReplies(on: runtime.backend)
    await enqueueStartupReplies(
        on: runtime.backend,
        document: DOM.Node(id: DOM.Node.ID("restarted-document"), nodeType: 9, nodeName: "#document")
    )

    context.start()
    try await waitForRecordedCommands(on: runtime.backend, expected: startupCommands + shutdownCommands + startupCommands)
    #expect(results.items.isEmpty)

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            text: "old"
        )),
        target: target
    )
    try await waitUntil { results.items.map(\.text) == ["old"] }

    await enableGate.open()
    try await waitUntil(in: context) { context.rootNode?.id == DOMNode.ID(DOM.Node.ID("restarted-document")) }
    #expect(results.items.count == 1)
}

@MainActor
@Test
func consoleEventsPopulateRepeatAndClearFetchedMessages() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let requestID = Network.Request.ID("request-1")

    let results: WebInspectorFetchedResults<ConsoleMessage> = context.console.fetchedResults()
    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "warning"),
            type: Console.Kind(rawValue: "log"),
            text: "hello",
            url: "https://example.com/app.js",
            line: 12,
            column: 4,
            repeatCount: 1,
            networkRequestID: requestID,
            timestamp: 1
        )),
        target: target
    )

    try await waitUntil { results.items.count == 1 }
    let message = try #require(results.items.first)
    #expect(message.source == Console.Source(rawValue: "console-api"))
    #expect(message.level == Console.Level(rawValue: "warning"))
    #expect(message.kind == Console.Kind(rawValue: "log"))
    #expect(message.text == "hello")
    #expect(message.url == "https://example.com/app.js")
    #expect(message.line == 12)
    #expect(message.column == 4)
    #expect(message.repeatCount == 1)
    #expect(message.networkRequestID == NetworkRequest.ID(requestID))
    #expect(message.timestamp == 1)
    #expect(context.registeredMessage(for: message.id) === message)

    await runtime.backend.emit(
        .messageRepeatCountUpdated(count: 3, timestamp: 2),
        target: target
    )
    try await waitUntil { message.repeatCount == 3 }
    #expect(results.items.first === message)
    #expect(message.timestamp == 2)

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "javascript"),
            level: Console.Level(rawValue: "error"),
            text: "second"
        )),
        target: target
    )
    try await waitUntil { results.items.count == 2 }
    #expect(results.items.map(\.text) == ["hello", "second"])

    await runtime.backend.emit(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        target: target
    )
    try await waitUntil { results.items.isEmpty }
    #expect(context.registeredMessage(for: message.id) == nil)
}

@MainActor
@Test
func consoleRepeatUpdatesStayWithinTheirTarget() throws {
    let context = WebInspectorContext.preview()
    let firstTargetID = WebInspectorTarget.ID("console-frame-a")
    let secondTargetID = WebInspectorTarget.ID("console-frame-b")
    let unknownTargetID = WebInspectorTarget.ID("console-frame-unknown")

    context.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "first"
        )),
        targetID: firstTargetID
    )
    context.apply(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "second"
        )),
        targetID: secondTargetID
    )

    let results: WebInspectorFetchedResults<ConsoleMessage> = context.console.fetchedResults()
    let first = try #require(results.items.first { $0.targetID == firstTargetID })
    let second = try #require(results.items.first { $0.targetID == secondTargetID })

    context.apply(
        .messageRepeatCountUpdated(count: 3, timestamp: 3),
        targetID: firstTargetID
    )
    context.apply(
        .messageRepeatCountUpdated(count: 9, timestamp: 9),
        targetID: unknownTargetID
    )

    #expect(first.repeatCount == 3)
    #expect(first.timestamp == 3)
    #expect(second.repeatCount == 1)
    #expect(second.timestamp == nil)
}

@MainActor
@Test
func consoleMessageParametersRegisterRuntimeObjects() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let objectID = Runtime.RemoteObject.ID("console-object")
    let results: WebInspectorFetchedResults<ConsoleMessage> = context.console.fetchedResults()

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "first",
            parameters: [
                Runtime.RemoteObject(id: objectID, kind: .object, description: "before")
            ]
        )),
        target: target
    )
    try await waitUntil { results.items.count == 1 }
    let firstMessage = try #require(results.items.first)
    let firstParameter = try #require(firstMessage.parameters.first)
    #expect(firstParameter.description == "before")

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "second",
            parameters: [
                Runtime.RemoteObject(id: objectID, kind: .object, description: "after")
            ]
        )),
        target: target
    )
    try await waitUntil { results.items.count == 2 }
    let secondMessage = try #require(results.items.last)
    let secondParameter = try #require(secondMessage.parameters.first)

    #expect(firstParameter === secondParameter)
    #expect(firstParameter.description == "after")
}

@MainActor
@Test
func consoleMessagesClearedInvalidatesRuntimeObjectsWithoutRuntimeCommand() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let objectID = Runtime.RemoteObject.ID("console-stale-object")
    let results: WebInspectorFetchedResults<ConsoleMessage> = context.console.fetchedResults()

    await runtime.backend.emit(
        .messageAdded(Console.Message(
            source: Console.Source(rawValue: "console-api"),
            level: Console.Level(rawValue: "log"),
            text: "clear me",
            parameters: [
                Runtime.RemoteObject(id: objectID, kind: .object, description: "console object")
            ]
        )),
        target: target
    )
    try await waitUntil { results.items.count == 1 }
    let message = try #require(results.items.first)
    let parameter = try #require(message.parameters.first)

    let commandCountBeforeClear = await runtime.backend.recordedCommands().count
    await runtime.backend.emit(
        .messagesCleared(reason: Console.ClearReason(rawValue: "console-api")),
        target: target
    )

    try await waitUntil { results.items.isEmpty }
    #expect(parameter.canRequestProperties == false)
    do {
        _ = try await parameter.properties()
        Issue.record("Expected cleared console RuntimeObject to be stale.")
    } catch let error as WebInspectorProxyError {
        #expect(error == .disconnected("RuntimeObject is not registered in this WebInspectorContext."))
    }
    let clearCommands = await runtime.backend.recordedCommands().dropFirst(commandCountBeforeClear)
    #expect(!clearCommands.contains(RecordedCommand(domain: "Runtime", method: "releaseObjectGroup")))
    #expect(context.state == .attached)
}

@MainActor
@Test
func evaluateRegistersRuntimeObjectInSelectedContext() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let contextID = Runtime.ExecutionContext.ID("main")
    let objectID = Runtime.RemoteObject.ID("evaluation-result")

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Main",
            kind: .normal
        )),
        target: target
    )
    try await waitUntil(in: context) { context.executionContexts.count == 1 }
    let runtimeContext = try #require(context.executionContexts.first)
    context.selectContext(runtimeContext)

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: objectID,
                kind: .string,
                description: "hello",
                value: .string("hello")
            ),
            wasThrown: true,
            savedResultIndex: 7
        ),
        for: "Runtime",
        method: "evaluate"
    )

    let result = try await context.evaluate("throw 'hello'", in: runtimeContext)
    #expect(result.isException)
    #expect(result.object.kind == .string)
    #expect(result.object.value == .string("hello"))
    #expect(result.object.description == "hello")

    let commands = await runtime.backend.recordedCommands()
    let command = try #require(commands.last { $0.domain == "Runtime" && $0.method == "evaluate" })
    let payload = try #require(command.payload.cast(as: Runtime.EvaluatePayload.self))
    #expect(payload.expression == "throw 'hello'")
    #expect(payload.context == contextID)
}

@MainActor
@Test
func runtimeObjectPropertiesAndCollectionEntriesUseRuntimeCommands() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let objectID = Runtime.RemoteObject.ID("root-object")
    let childID = Runtime.RemoteObject.ID("child-object")
    let entryValueID = Runtime.RemoteObject.ID("entry-value")

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: objectID, kind: .object, description: "root")
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let evaluation = try await context.evaluate("window")

    await runtime.backend.enqueue(
        [
            Runtime.PropertyDescriptor(
                name: "answer",
                value: Runtime.RemoteObject(id: nil, kind: .number, description: "42", value: .number(42))
            ),
            Runtime.PropertyDescriptor(
                name: "child",
                value: Runtime.RemoteObject(id: childID, kind: .object, description: "child")
            ),
        ],
        for: "Runtime",
        method: "getProperties"
    )

    let properties = try await evaluation.object.properties()
    #expect(properties.count == 2)
    #expect(properties[0].name == "answer")
    #expect(properties[0].value == "42")
    #expect(properties[0].object == nil)
    let child = try #require(properties[1].object)
    #expect(child.description == "child")

    await runtime.backend.enqueue(
        [
            Runtime.CollectionEntry(
                key: Runtime.RemoteObject(id: nil, kind: .string, description: "key", value: .string("key")),
                value: Runtime.RemoteObject(id: entryValueID, kind: .object, description: "entry value")
            )
        ],
        for: "Runtime",
        method: "getCollectionEntries"
    )

    let entries = try await evaluation.object.collectionEntries()
    #expect(entries.count == 1)
    #expect(entries[0].key?.value == .string("key"))
    #expect(entries[0].value?.description == "entry value")

    let commands = await runtime.backend.recordedCommands()
    #expect(commands.contains(RecordedCommand(domain: "Runtime", method: "getProperties")))
    #expect(commands.contains(RecordedCommand(domain: "Runtime", method: "getCollectionEntries")))
}

@MainActor
@Test
func staleRuntimeObjectThrowsWithoutFailingContext() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let contextID = Runtime.ExecutionContext.ID("main")
    let objectID = Runtime.RemoteObject.ID("stale-object")

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Main",
            kind: .normal
        )),
        target: target
    )
    try await waitUntil(in: context) { context.executionContexts.count == 1 }

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: objectID, kind: .object, description: "stale")
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let evaluation = try await context.evaluate("window")

    await runtime.backend.emit(.executionContextsCleared(target: target.id), target: target)
    try await waitUntil(in: context) {
        context.executionContexts.isEmpty && context.selectedContext == nil
    }
    #expect(evaluation.object.canRequestProperties == false)

    do {
        _ = try await evaluation.object.properties()
        Issue.record("Expected stale runtime object to throw.")
    } catch let error as WebInspectorProxyError {
        #expect(error == .disconnected("RuntimeObject is not registered in this WebInspectorContext."))
    }
    #expect(context.state == .attached)
}

@MainActor
@Test
func lateEvaluateReplyDoesNotRegisterObjectAfterContextDestruction() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let contextID = Runtime.ExecutionContext.ID("late-evaluate-context")
    let evaluationGate = WebInspectorTestGate()

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Main",
            frameID: FrameID("main-frame"),
            kind: .normal
        )),
        target: target
    )
    try await waitUntil(in: context) { context.executionContexts.count == 1 }
    let runtimeContext = try #require(context.executionContexts.first)

    await runtime.backend.hold(domain: "Runtime", method: "evaluate", gate: evaluationGate)
    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID("late-evaluate-object"),
                kind: .object,
                description: "stale"
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )
    await runtime.backend.enqueue((), for: "Runtime", method: "releaseObject")

    var evaluationError: WebInspectorProxyError?
    let evaluationTask = Task { @MainActor in
        do {
            _ = try await context.evaluate("window", in: runtimeContext)
        } catch {
            evaluationError = error as? WebInspectorProxyError
        }
    }
    _ = await runtime.backend.waitForRecordedCommands(domain: "Runtime", method: "evaluate", count: 1)

    await runtime.backend.emit(.executionContextDestroyed(contextID), target: target)
    try await waitUntil(in: context) { context.executionContexts.isEmpty }
    await evaluationGate.open()

    await evaluationTask.value
    #expect(evaluationError == .disconnected("Runtime command result is no longer current."))
    let commands = await runtime.backend.recordedCommands()
    let releaseCommand = try #require(commands.last {
        $0.domain == "Runtime" && $0.method == "releaseObject"
    })
    let releasePayload = try #require(
        releaseCommand.payload.cast(as: Runtime.ReleaseObjectPayload.self)
    )
    #expect(releaseCommand.targetID == target.id)
    #expect(releasePayload.id == Runtime.RemoteObject.ID("late-evaluate-object"))
    #expect(context.state == .attached)
}

@MainActor
@Test
func evaluateRejectsAndReleasesReplyObjectScopedToDifferentTarget() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let frameTargetID = WebInspectorTarget.ID("runtime-frame")
    let otherTargetID = WebInspectorTarget.ID("other-runtime-frame")
    let contextID = Runtime.ExecutionContext.ID(
        "frame-context",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    let otherObjectID = Runtime.RemoteObject.ID(
        "foreign-object",
        scopedToTargetRawValue: otherTargetID.rawValue
    )

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Frame",
            frameID: FrameID("runtime-frame-id"),
            kind: .normal
        )),
        targetID: frameTargetID
    )
    let frameContext = try #require(context.executionContexts.first)

    // Live replies take their object scope from the reply route, so this
    // foreign scope can only come from a substituted backend.
    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: otherObjectID, kind: .object)
        ),
        for: "Runtime",
        method: "evaluate"
    )
    await runtime.backend.enqueue((), for: "Runtime", method: "releaseObject")

    do {
        _ = try await context.evaluate("window", in: frameContext)
        Issue.record("Expected an evaluation result from another target to be rejected.")
    } catch let error as WebInspectorProxyError {
        #expect(error == .disconnected("Runtime command result is no longer current."))
    }

    let commands = await runtime.backend.recordedCommands()
    #expect(
        commands.first {
            $0.domain == "Runtime" && $0.method == "evaluate"
        }?.targetID == frameTargetID
    )
    let releaseCommand = try #require(commands.first {
        $0.domain == "Runtime" && $0.method == "releaseObject"
    })
    let releasePayload = try #require(
        releaseCommand.payload.cast(as: Runtime.ReleaseObjectPayload.self)
    )
    #expect(releaseCommand.targetID == otherTargetID)
    #expect(releasePayload.id == otherObjectID)
    #expect(context.state == .attached)

    let frameObjectID = Runtime.RemoteObject.ID(
        "frame-object",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: frameObjectID, kind: .object)
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let evaluation = try await context.evaluate("window", in: frameContext)
    #expect(evaluation.object.canRequestProperties)
}

@MainActor
@Test
func propertiesRejectAndReleaseReplyAccessorScopedToDifferentTarget() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let frameTargetID = WebInspectorTarget.ID("property-runtime-frame")
    let otherTargetID = WebInspectorTarget.ID("other-property-runtime-frame")
    let contextID = Runtime.ExecutionContext.ID(
        "property-frame-context",
        scopedToTargetRawValue: frameTargetID.rawValue
    )

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Property frame",
            frameID: FrameID("property-frame-id"),
            kind: .normal
        )),
        targetID: frameTargetID
    )
    let frameContext = try #require(context.executionContexts.first)
    let rootObjectID = Runtime.RemoteObject.ID(
        "property-root",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(id: rootObjectID, kind: .object)
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let root = try await context.evaluate("window", in: frameContext).object

    let foreignAccessorID = Runtime.RemoteObject.ID(
        "foreign-getter",
        scopedToTargetRawValue: otherTargetID.rawValue
    )
    // Live replies take their object scope from the reply route, so this
    // foreign scope can only come from a substituted backend.
    await runtime.backend.enqueue(
        [
            Runtime.PropertyDescriptor(
                name: "value",
                get: Runtime.RemoteObject(id: foreignAccessorID, kind: .function)
            )
        ],
        for: "Runtime",
        method: "getProperties"
    )
    await runtime.backend.enqueue((), for: "Runtime", method: "releaseObject")

    do {
        _ = try await root.properties()
        Issue.record("Expected a property accessor from another target to be rejected.")
    } catch let error as WebInspectorProxyError {
        #expect(error == .disconnected("Runtime command result is no longer current."))
    }

    let commands = await runtime.backend.recordedCommands()
    #expect(
        commands.first {
            $0.domain == "Runtime" && $0.method == "getProperties"
        }?.targetID == frameTargetID
    )
    let releaseCommand = try #require(commands.first {
        $0.domain == "Runtime" && $0.method == "releaseObject"
    })
    let releasePayload = try #require(
        releaseCommand.payload.cast(as: Runtime.ReleaseObjectPayload.self)
    )
    #expect(releaseCommand.targetID == otherTargetID)
    #expect(releasePayload.id == foreignAccessorID)
    #expect(root.canRequestProperties)
    #expect(context.state == .attached)
}

@MainActor
@Test
func childFrameNavigationAndDetachClearOnlyChildRuntimeAuthority() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let mainContextID = Runtime.ExecutionContext.ID("main-context")
    let childContextID = Runtime.ExecutionContext.ID("child-context")
    let childFrameID = FrameID("child-frame")
    let propertiesGate = WebInspectorTestGate()

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: mainContextID,
            name: "Main",
            frameID: FrameID("main-frame"),
            kind: .normal
        )),
        target: target
    )
    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: childContextID,
            name: "Child",
            frameID: childFrameID,
            kind: .normal
        )),
        target: target
    )
    try await waitUntil(in: context) { context.executionContexts.count == 2 }
    let childContext = try #require(context.executionContexts.first {
        $0.id == RuntimeContext.ID(childContextID)
    })

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID("child-window"),
                kind: .object,
                description: "child window"
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let childWindow = try await context.evaluate("window", in: childContext).object

    await runtime.backend.hold(domain: "Runtime", method: "getProperties", gate: propertiesGate)
    await runtime.backend.enqueue(
        [
            Runtime.PropertyDescriptor(
                name: "lateChild",
                value: Runtime.RemoteObject(
                    id: Runtime.RemoteObject.ID("late-child-property"),
                    kind: .object
                )
            )
        ],
        for: "Runtime",
        method: "getProperties"
    )
    var propertiesError: WebInspectorProxyError?
    let propertiesTask = Task { @MainActor in
        do {
            _ = try await childWindow.properties()
        } catch {
            propertiesError = error as? WebInspectorProxyError
        }
    }
    _ = await runtime.backend.waitForRecordedCommands(domain: "Runtime", method: "getProperties", count: 1)

    let lifecycleBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(
        .frameNavigated(WebInspectorPageFrameLifecycle(
            id: childFrameID,
            parentID: FrameID("main-frame"),
            loaderID: "child-loader-2",
            name: "Child",
            url: "https://example.test/child-next",
            securityOrigin: "https://example.test",
            mimeType: "text/html"
        )),
        target: target
    )
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: lifecycleBaseline))
    #expect(context.executionContexts.map(\.id) == [RuntimeContext.ID(mainContextID)])

    await propertiesGate.open()
    await propertiesTask.value
    #expect(propertiesError == .disconnected("Runtime command result is no longer current."))
    #expect(context.executionContexts.map(\.id) == [RuntimeContext.ID(mainContextID)])

    let detachedContextID = Runtime.ExecutionContext.ID("detached-child-context")
    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: detachedContextID,
            name: "Detached child",
            frameID: childFrameID,
            kind: .normal
        )),
        target: target
    )
    try await waitUntil(in: context) { context.executionContexts.count == 2 }
    let detachBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(.frameDetached(frameID: childFrameID), target: target)
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: detachBaseline))
    #expect(context.executionContexts.map(\.id) == [RuntimeContext.ID(mainContextID)])
}

@MainActor
@Test
func newNormalFrameContextReplacesPriorTargetContextsAndObjects() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (_, context) = try await startContext(runtime: runtime)
    let frameTargetID = WebInspectorTarget.ID("frame-runtime-replacement")
    let frameID = FrameID("child-frame")
    let firstContextID = Runtime.ExecutionContext.ID(
        "1",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    let utilityContextID = Runtime.ExecutionContext.ID(
        "2",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    let replacementContextID = Runtime.ExecutionContext.ID(
        "3",
        scopedToTargetRawValue: frameTargetID.rawValue
    )

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: firstContextID,
            name: "First",
            frameID: frameID,
            kind: .normal
        )),
        targetID: frameTargetID
    )
    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: utilityContextID,
            name: "Utility",
            frameID: frameID,
            kind: .user
        )),
        targetID: frameTargetID
    )
    let firstContext = try #require(context.executionContexts.first {
        $0.id == RuntimeContext.ID(firstContextID)
    })

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID(
                    "old-object",
                    scopedToTargetRawValue: frameTargetID.rawValue
                ),
                kind: .object
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let oldObject = try await context.evaluate("window", in: firstContext).object

    await runtime.backend.enqueue(
        [Runtime.PropertyDescriptor(name: "frameProperty")],
        for: "Runtime",
        method: "getProperties"
    )
    _ = try await oldObject.properties()

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: firstContextID,
            name: "First Updated",
            frameID: frameID,
            kind: .normal
        )),
        targetID: frameTargetID
    )
    #expect(context.executionContexts.first { $0.id == firstContext.id } === firstContext)
    #expect(firstContext.name == "First Updated")
    #expect(oldObject.canRequestProperties)

    let frameCommands = await runtime.backend.recordedCommands()
        .filter { $0.domain == "Runtime" }
    #expect(frameCommands.first { $0.method == "evaluate" }?.targetID == frameTargetID)
    #expect(frameCommands.first { $0.method == "getProperties" }?.targetID == frameTargetID)

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: replacementContextID,
            name: "Replacement",
            frameID: frameID,
            kind: .normal
        )),
        targetID: frameTargetID
    )

    #expect(context.executionContexts.map(\.id) == [RuntimeContext.ID(replacementContextID)])
    #expect(oldObject.canRequestProperties == false)
    do {
        _ = try await oldObject.properties()
        Issue.record("Expected the replaced frame RuntimeObject to be stale.")
    } catch let error as WebInspectorProxyError {
        #expect(error == .disconnected("RuntimeObject is not registered in this WebInspectorContext."))
    }
}

@MainActor
@Test
func destroyedTargetRejectsLateCollectionEntriesReply() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (pageTarget, context) = try await startContext(runtime: runtime)
    let frameTargetID = WebInspectorTarget.ID("destroyed-runtime-frame")
    let contextID = Runtime.ExecutionContext.ID(
        "1",
        scopedToTargetRawValue: frameTargetID.rawValue
    )
    let collectionGate = WebInspectorTestGate()

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: contextID,
            name: "Frame",
            frameID: FrameID("destroyed-frame"),
            kind: .normal
        )),
        targetID: frameTargetID
    )
    let frameContext = try #require(context.executionContexts.first)
    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID(
                    "frame-collection",
                    scopedToTargetRawValue: frameTargetID.rawValue
                ),
                kind: .object
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let collection = try await context.evaluate("new Map", in: frameContext).object

    await runtime.backend.hold(domain: "Runtime", method: "getCollectionEntries", gate: collectionGate)
    await runtime.backend.enqueue(
        [
            Runtime.CollectionEntry(
                value: Runtime.RemoteObject(
                    id: Runtime.RemoteObject.ID(
                        "late-entry",
                        scopedToTargetRawValue: frameTargetID.rawValue
                    ),
                    kind: .object
                )
            )
        ],
        for: "Runtime",
        method: "getCollectionEntries"
    )
    await runtime.backend.enqueue((), for: "Runtime", method: "releaseObject")
    var entriesError: WebInspectorProxyError?
    let entriesTask = Task { @MainActor in
        do {
            _ = try await collection.collectionEntries()
        } catch {
            entriesError = error as? WebInspectorProxyError
        }
    }
    _ = await runtime.backend.waitForRecordedCommands(
        domain: "Runtime",
        method: "getCollectionEntries",
        count: 1
    )
    let frameCommands = await runtime.backend.recordedCommands()
        .filter { $0.domain == "Runtime" }
    #expect(frameCommands.first { $0.method == "evaluate" }?.targetID == frameTargetID)
    #expect(frameCommands.first { $0.method == "getCollectionEntries" }?.targetID == frameTargetID)

    let lifecycleBaseline = context.eventPumpAppliedSequenceForTesting
    await runtime.backend.emit(.targetDestroyed(targetID: frameTargetID), target: pageTarget)
    #expect(await context.waitForEventPumpAppliedSequenceForTesting(after: lifecycleBaseline))
    #expect(context.executionContexts.isEmpty)
    #expect(collection.canRequestProperties == false)
    await collectionGate.open()

    await entriesTask.value
    #expect(entriesError == .disconnected("Runtime command result is no longer current."))
    let commands = await runtime.backend.recordedCommands()
    let releaseCommand = try #require(commands.last {
        $0.domain == "Runtime" && $0.method == "releaseObject"
    })
    let releasePayload = try #require(
        releaseCommand.payload.cast(as: Runtime.ReleaseObjectPayload.self)
    )
    #expect(releaseCommand.targetID == frameTargetID)
    #expect(
        releasePayload.id == Runtime.RemoteObject.ID(
            "late-entry",
            scopedToTargetRawValue: frameTargetID.rawValue
        )
    )
    #expect(context.state == .attached)
}

@MainActor
@Test
func childScopedExecutionContextsClearedPreservesMainRuntimeAuthority() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (pageTarget, context) = try await startContext(runtime: runtime)
    let mainContextID = Runtime.ExecutionContext.ID("main-clear-context")
    let frameTargetID = WebInspectorTarget.ID("frame-clear-target")
    let childContextID = Runtime.ExecutionContext.ID(
        "child-clear-context",
        scopedToTargetRawValue: frameTargetID.rawValue
    )

    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: mainContextID,
            name: "Main",
            frameID: FrameID("main-frame"),
            kind: .normal
        )),
        targetID: pageTarget.id
    )
    context.apply(
        .executionContextCreated(Runtime.ExecutionContext(
            id: childContextID,
            name: "Child",
            frameID: FrameID("child-frame"),
            kind: .normal
        )),
        targetID: frameTargetID
    )
    let mainContext = try #require(context.executionContexts.first {
        $0.id == RuntimeContext.ID(mainContextID)
    })
    let childContext = try #require(context.executionContexts.first {
        $0.id == RuntimeContext.ID(childContextID)
    })

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID("main-clear-object"),
                kind: .object
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let mainObject = try await context.evaluate("window", in: mainContext).object
    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: Runtime.RemoteObject(
                id: Runtime.RemoteObject.ID(
                    "child-clear-object",
                    scopedToTargetRawValue: frameTargetID.rawValue
                ),
                kind: .object
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )
    let childObject = try await context.evaluate("window", in: childContext).object

    context.apply(
        .executionContextsCleared(target: frameTargetID),
        targetID: pageTarget.id
    )

    #expect(context.executionContexts.map(\.id) == [RuntimeContext.ID(mainContextID)])
    #expect(context.selectedContext === mainContext)
    #expect(mainObject.canRequestProperties)
    #expect(childObject.canRequestProperties == false)
}

@MainActor
@Test
func runtimeEventsPopulateContextsAndFallbackSelection() async throws {
    let runtime = try await WebInspectorProxyTestRuntime.start()
    let (target, context) = try await startContext(runtime: runtime)
    let mainID = Runtime.ExecutionContext.ID("main")
    let utilityID = Runtime.ExecutionContext.ID("utility")

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: mainID,
            name: "Main",
            kind: .normal
        )),
        target: target
    )
    try await waitUntil(in: context) { context.executionContexts.count == 1 }
    let mainContext = try #require(context.executionContexts.first)
    #expect(context.selectedContext === mainContext)
    #expect(mainContext.name == "Main")
    #expect(mainContext.kind == .normal)

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: mainID,
            name: "Main Updated",
            kind: .normal
        )),
        target: target
    )
    try await waitUntil { mainContext.name == "Main Updated" }
    #expect(context.executionContexts.first === mainContext)

    await runtime.backend.emit(
        .executionContextCreated(Runtime.ExecutionContext(
            id: utilityID,
            name: "Utility",
            kind: .user
        )),
        target: target
    )
    try await waitUntil(in: context) { context.executionContexts.count == 2 }
    let utilityContext = try #require(context.executionContexts.first { $0.id == RuntimeContext.ID(utilityID) })
    #expect(context.selectedContext === mainContext)

    context.selectContext(utilityContext)
    #expect(context.selectedContext === utilityContext)

    await runtime.backend.emit(
        .executionContextDestroyed(utilityID),
        target: target
    )
    try await waitUntil(in: context) {
        context.executionContexts.count == 1 && context.selectedContext === mainContext
    }
    #expect(context.executionContexts.first === mainContext)

    await runtime.backend.emit(
        .executionContextsCleared(target: target.id),
        target: target
    )
    try await waitUntil(in: context) {
        context.executionContexts.isEmpty && context.selectedContext == nil
    }
}
