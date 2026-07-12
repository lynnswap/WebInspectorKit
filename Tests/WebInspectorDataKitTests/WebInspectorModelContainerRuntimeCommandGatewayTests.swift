import Foundation
import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

private enum RuntimeGatewayTestError: Error {
    case timedOut
}

private struct RuntimeGatewayFixture {
    let container: WebInspectorModelContainer
    let runtime: WebInspectorProxyTestRuntime
    let wire: WebInspectorRawWireDriver
    let domains: Set<WebInspectorModelContainer.Domain>

    static func start(
        domains: Set<WebInspectorModelContainer.Domain> = [.console, .runtime]
    ) async throws -> Self {
        let runtime = try await WebInspectorProxyTestRuntime.start()
        let wire = WebInspectorRawWireDriver(peer: runtime.peer)
        await wire.start()
        await wire.respond(to: "Page.enable")
        if domains.contains(.console) {
            await wire.respond(to: "Console.enable")
        }
        if domains.contains(.runtime) || domains.contains(.console) {
            await wire.respond(to: "Runtime.enable")
        }
        let container = WebInspectorModelContainer(
            configuration: .init(domains: domains)
        )
        try await container.attach(owning: runtime.proxy)
        return Self(
            container: container,
            runtime: runtime,
            wire: wire,
            domains: domains
        )
    }

    func close() async {
        if domains.contains(.runtime) || domains.contains(.console) {
            await wire.respond(to: "Runtime.disable")
        }
        if domains.contains(.console) {
            await wire.respond(to: "Console.disable")
        }
        await wire.respond(to: "Page.disable")
        await container.close()
        await runtime.close()
        await wire.stop()
    }
}

private func withRuntimeGatewayFixture<Output: Sendable>(
    domains: Set<WebInspectorModelContainer.Domain> = [.console, .runtime],
    _ operation: @escaping @Sendable (RuntimeGatewayFixture) async throws -> Output
) async throws -> Output {
    let fixture = try await RuntimeGatewayFixture.start(domains: domains)
    do {
        let output = try await operation(fixture)
        await fixture.close()
        return output
    } catch {
        await fixture.close()
        throw error
    }
}

@Test
func consoleParameterGraphRoutesThroughItsPhysicalAgent() async throws {
    try await withRuntimeGatewayFixture(domains: [.console]) { fixture in
        try await fixture.runtime.peer.createTarget(
            .init(
                id: "frame-runtime-agent",
                type: "frame",
                frameID: "child-frame",
                parentFrameID: "main-frame"
            )
        )
        try await requireRuntimeGatewayTarget(
            WebInspectorTarget.ID("frame-runtime-agent"),
            in: fixture.container.core
        )
        let messageID = try await emitCanonicalConsoleMessage(
            text: "child object",
            rawObjectID: "child-object",
            targetID: "frame-runtime-agent",
            wire: fixture.wire,
            core: fixture.container.core
        )
        let graph = try await fixture.container.core
            .claimConsoleParameterGraph(
                messageID: messageID,
                parameterIndex: 0
            )
        await fixture.wire.respond(
            to: "Runtime.getProperties",
            with: try rawRuntimePropertiesResult([
                Runtime.PropertyDescriptor(
                    name: "nested",
                    value: Runtime.RemoteObject(
                        id: Runtime.RemoteObject.ID("nested-object"),
                        kind: .object,
                        description: "nested"
                    ),
                    enumerable: true,
                    isOwn: true
                )
            ])
        )

        let properties = try await fixture.container.core.runtimeProperties(
            of: graph.root.id
        )
        let property = try #require(properties.first)
        #expect(property.name == "nested")
        #expect(property.value?.payload.description == "nested")
        #expect(property.value?.id.graph == graph.token)

        let commands = fixture.wire.observations.commands.filter {
            $0.method == "Runtime.getProperties"
        }
        let command = try #require(commands.first)
        #expect(commands.count == 1)
        #expect(command.destination == .target("frame-runtime-agent"))
        let parameters = try command.parameters.decode(
            RuntimeObjectCommandParameters.self
        )
        #expect(parameters.objectId == "child-object")

        try await fixture.container.core.closeRuntimeObjectGraph(graph.token)
        #expect(
            fixture.wire.observations.commands.contains {
                $0.method == "Runtime.releaseObjectGroup"
            } == false
        )
    }
}

@Test
func independentGroupCloseDrainsClaimsAndCallerCancellationOnlyLeavesWait()
    async throws
{
    try await withRuntimeGatewayFixture(domains: [.runtime]) { fixture in
        let group = try await fixture.container.core.createRuntimeObjectGroup(
            named: "drain"
        )
        let evaluationGate = await fixture.wire.deferReply(
            to: "Runtime.evaluate",
            with: try rawRuntimeEvaluationResult(
                Runtime.EvaluationResult(
                    object: Runtime.RemoteObject(
                        id: Runtime.RemoteObject.ID("evaluated-object"),
                        kind: .object,
                        description: "evaluated"
                    )
                )
            )
        )
        await fixture.wire.respond(to: "Runtime.releaseObjectGroup")
        let core = fixture.container.core
        let evaluation = Task.detached {
            try await core.evaluateRuntimeExpression(
                "({ value: 1 })",
                in: group.token
            )
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "Runtime.evaluate",
            count: 1
        )
        evaluation.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await evaluation.value
        }

        let close = Task.detached {
            try await core.closeRuntimeObjectGraph(group.token)
        }
        await requireRuntimeGatewayOpenGraphCount(0, in: core)
        await #expect(
            throws: WebInspectorRuntimeCommandGatewayError.graphClosed
        ) {
            _ = try await core.evaluateRuntimeExpression(
                "2 + 2",
                in: group.token
            )
        }
        #expect(
            fixture.wire.observations.commands.contains {
                $0.method == "Runtime.releaseObjectGroup"
            } == false
        )

        evaluationGate.open()
        try await close.value
        try await core.closeRuntimeObjectGraph(group.token)

        let releases = fixture.wire.observations.commands.filter {
            $0.method == "Runtime.releaseObjectGroup"
        }
        let release = try #require(releases.first)
        #expect(releases.count == 1)
        let parameters = try release.parameters.decode(
            RuntimeGroupCommandParameters.self
        )
        guard case let .other(expectedWireName) = group.wireGroup else {
            Issue.record("Independent Runtime group used Console ownership.")
            return
        }
        #expect(parameters.objectGroup == expectedWireName)
        let metrics = await core.runtimeCommandGatewayMetrics
        #expect(metrics.operationCount == 0)
        #expect(metrics.wireGroupReleaseCount == 1)
    }
}

@Test
func independentGroupCloseWaiterCancellationDoesNotCancelWireRelease()
    async throws
{
    try await withRuntimeGatewayFixture(domains: [.runtime]) { fixture in
        let group = try await fixture.container.core.createRuntimeObjectGroup(
            named: "cancelled-close-waiter"
        )
        let releaseGate = await fixture.wire.deferReply(
            to: "Runtime.releaseObjectGroup"
        )
        let core = fixture.container.core
        let firstClose = Task.detached {
            try await core.closeRuntimeObjectGraph(group.token)
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "Runtime.releaseObjectGroup",
            count: 1
        )
        firstClose.cancel()
        await #expect(throws: CancellationError.self) {
            try await firstClose.value
        }

        let secondClose = Task.detached {
            try await core.closeRuntimeObjectGraph(group.token)
        }
        releaseGate.open()
        try await secondClose.value
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "Runtime.releaseObjectGroup"
            }.count == 1
        )
    }
}

@Test
func independentGroupReleaseFailureIsTerminalAndNeverRetriesTheWireCommand()
    async throws
{
    try await withRuntimeGatewayFixture(domains: [.runtime]) { fixture in
        let group = try await fixture.container.core.createRuntimeObjectGroup(
            named: "failed-release"
        )
        await fixture.wire.fail(
            "Runtime.releaseObjectGroup",
            message: "release failed"
        )
        let core = fixture.container.core

        await #expect(throws: WebInspectorRuntimeCommandGatewayError.self) {
            try await core.closeRuntimeObjectGraph(group.token)
        }
        await #expect(throws: WebInspectorRuntimeCommandGatewayError.self) {
            try await core.closeRuntimeObjectGraph(group.token)
        }
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "Runtime.releaseObjectGroup"
            }.count == 1
        )
        let metrics = await core.runtimeCommandGatewayMetrics
        #expect(metrics.wireGroupReleaseCount == 1)
    }
}

@Test
func consoleClearInvalidatesOnlyConsoleGraphsWithoutExtraWireRelease()
    async throws
{
    try await withRuntimeGatewayFixture { fixture in
        let messageID = try await emitCanonicalConsoleMessage(
            text: "console owned",
            rawObjectID: "console-object",
            wire: fixture.wire,
            core: fixture.container.core
        )
        let consoleGraph = try await fixture.container.core
            .claimConsoleParameterGraph(
                messageID: messageID,
                parameterIndex: 0
            )
        let independent = try await fixture.container.core
            .createRuntimeObjectGroup(named: "survives-console-clear")
        let propertyGate = await fixture.wire.deferReply(
            to: "Runtime.getProperties",
            with: try rawRuntimePropertiesResult([])
        )
        let core = fixture.container.core
        let properties = Task.detached {
            try await core.runtimeProperties(of: consoleGraph.root.id)
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "Runtime.getProperties",
            count: 1
        )

        try await fixture.wire.emitRaw(
            .messagesCleared(reason: Console.ClearReason(rawValue: "frontend")),
            target: WebInspectorTarget.ID("page-main")
        )
        await #expect(
            throws: WebInspectorRuntimeCommandGatewayError.staleAuthority
        ) {
            _ = try await properties.value
        }
        propertyGate.open()

        await fixture.wire.respond(
            to: "Runtime.evaluate",
            with: try rawRuntimeEvaluationResult(
                Runtime.EvaluationResult(
                    object: Runtime.RemoteObject(
                        id: nil,
                        kind: .number,
                        value: .number(4)
                    )
                )
            )
        )
        let evaluation = try await core.evaluateRuntimeExpression(
            "2 + 2",
            in: independent.token
        )
        #expect(evaluation.object.payload.value == .number(4))

        await fixture.wire.respond(to: "Runtime.releaseObjectGroup")
        try await core.closeRuntimeObjectGraph(independent.token)
        let releases = fixture.wire.observations.commands.filter {
            $0.method == "Runtime.releaseObjectGroup"
        }
        #expect(releases.count == 1)
    }
}

@Test
func frameDetachConservativelyInvalidatesConsoleGraphsWithoutFrameAuthority()
    async throws
{
    try await withRuntimeGatewayFixture(domains: [.console]) { fixture in
        try await fixture.wire.emitRaw(
            .frameNavigated(
                WebInspectorPageFrameLifecycle(
                    id: FrameID("ordinary-subframe"),
                    parentID: FrameID("main-frame"),
                    loaderID: "subframe-loader",
                    name: nil,
                    url: "https://example.test/frame",
                    securityOrigin: "https://example.test",
                    mimeType: "text/html"
                )
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        let messageID = try await emitCanonicalConsoleMessage(
            text: "frame-derived console object",
            rawObjectID: "frame-derived-object",
            wire: fixture.wire,
            core: fixture.container.core
        )
        let graph = try await fixture.container.core
            .claimConsoleParameterGraph(
                messageID: messageID,
                parameterIndex: 0
            )

        try await fixture.wire.emitRaw(
            .frameDetached(frameID: FrameID("ordinary-subframe")),
            target: WebInspectorTarget.ID("page-main")
        )
        await #expect(
            throws: WebInspectorRuntimeCommandGatewayError.staleAuthority
        ) {
            _ = try await fixture.container.core.runtimeProperties(
                of: graph.root.id
            )
        }
        #expect(
            fixture.wire.observations.commands.contains {
                $0.method == "Runtime.getProperties"
                    || $0.method == "Runtime.releaseObjectGroup"
            } == false
        )
    }
}

@Test
func boundContextDestroyDoesNotInvalidateAnIndependentUnboundGroup()
    async throws
{
    try await withRuntimeGatewayFixture(domains: [.runtime]) { fixture in
        let contextID = try await emitCanonicalRuntimeContext(
            rawID: "bound-context",
            wire: fixture.wire,
            core: fixture.container.core
        )
        let bound = try await fixture.container.core.createRuntimeObjectGroup(
            named: "bound",
            boundTo: contextID
        )
        let unbound = try await fixture.container.core.createRuntimeObjectGroup(
            named: "unbound"
        )

        try await fixture.wire.emitRaw(
            .executionContextDestroyed(
                Runtime.ExecutionContext.ID("bound-context")
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        await #expect(
            throws: WebInspectorRuntimeCommandGatewayError.staleAuthority
        ) {
            _ = try await fixture.container.core.evaluateRuntimeExpression(
                "1",
                in: bound.token
            )
        }

        await fixture.wire.respond(
            to: "Runtime.evaluate",
            with: try rawRuntimeEvaluationResult(
                Runtime.EvaluationResult(
                    object: Runtime.RemoteObject(
                        id: nil,
                        kind: .string,
                        value: .string("alive")
                    )
                )
            )
        )
        let result = try await fixture.container.core
            .evaluateRuntimeExpression("'alive'", in: unbound.token)
        #expect(result.object.payload.value == .string("alive"))

        await fixture.wire.respond(to: "Runtime.releaseObjectGroup")
        try await fixture.container.core.closeRuntimeObjectGraph(unbound.token)
    }
}

@Test
func runtimeClearInvalidatesEveryIndependentGroupAndLateRepliesCannotMaterialize()
    async throws
{
    try await withRuntimeGatewayFixture(domains: [.runtime]) { fixture in
        let group = try await fixture.container.core.createRuntimeObjectGroup(
            named: "runtime-clear"
        )
        let gate = await fixture.wire.deferReply(
            to: "Runtime.evaluate",
            with: try rawRuntimeEvaluationResult(
                Runtime.EvaluationResult(
                    object: Runtime.RemoteObject(
                        id: Runtime.RemoteObject.ID("late-object"),
                        kind: .object
                    )
                )
            )
        )
        let core = fixture.container.core
        let evaluation = Task.detached {
            try await core.evaluateRuntimeExpression("({})", in: group.token)
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "Runtime.evaluate",
            count: 1
        )

        try await fixture.wire.emitRaw(
            .executionContextsCleared,
            target: WebInspectorTarget.ID("page-main")
        )
        await #expect(
            throws: WebInspectorRuntimeCommandGatewayError.staleAuthority
        ) {
            _ = try await evaluation.value
        }
        gate.open()
        await requireRuntimeGatewayOperationCount(
            0,
            in: core
        )
        await #expect(
            throws: WebInspectorRuntimeCommandGatewayError.staleAuthority
        ) {
            _ = try await core.evaluateRuntimeExpression("1", in: group.token)
        }
        let metrics = await core.runtimeCommandGatewayMetrics
        #expect(metrics.invalidatedGraphCount == 1)
    }
}

@Test
func navigationInvalidatesIndependentGroupsBeforeLateRepliesMaterialize()
    async throws
{
    try await withRuntimeGatewayFixture(domains: [.runtime]) { fixture in
        let group = try await fixture.container.core.createRuntimeObjectGroup(
            named: "navigation"
        )
        let gate = await fixture.wire.deferReply(
            to: "Runtime.evaluate",
            with: try rawRuntimeEvaluationResult(
                Runtime.EvaluationResult(
                    object: Runtime.RemoteObject(
                        id: Runtime.RemoteObject.ID("old-document-object"),
                        kind: .object
                    )
                )
            )
        )
        let core = fixture.container.core
        let evaluation = Task.detached {
            try await core.evaluateRuntimeExpression("window", in: group.token)
        }
        _ = await fixture.wire.observations.waitForCommands(
            method: "Runtime.evaluate",
            count: 1
        )

        try await fixture.wire.emitRaw(
            .frameNavigated(
                WebInspectorPageFrameLifecycle(
                    id: FrameID("main-frame"),
                    parentID: nil,
                    loaderID: "replacement-loader",
                    name: nil,
                    url: "https://example.test/replacement",
                    securityOrigin: "https://example.test",
                    mimeType: "text/html"
                )
            ),
            target: WebInspectorTarget.ID("page-main")
        )
        await #expect(
            throws: WebInspectorRuntimeCommandGatewayError.staleAuthority
        ) {
            _ = try await evaluation.value
        }
        gate.open()
        await requireRuntimeGatewayOperationCount(0, in: core)
        #expect(
            fixture.wire.observations.commands.contains {
                $0.method == "Runtime.releaseObjectGroup"
            } == false
        )
    }
}

@Test
func physicalTargetLossInvalidatesItsBoundGroup() async throws {
    try await withRuntimeGatewayFixture(domains: [.runtime]) { fixture in
        try await fixture.runtime.peer.createTarget(
            .init(
                id: "frame-runtime-agent",
                type: "frame",
                frameID: "child-frame",
                parentFrameID: "main-frame"
            )
        )
        try await requireRuntimeGatewayTarget(
            WebInspectorTarget.ID("frame-runtime-agent"),
            in: fixture.container.core
        )
        let contextID = try await emitCanonicalRuntimeContext(
            rawID: "frame-context",
            targetID: "frame-runtime-agent",
            wire: fixture.wire,
            core: fixture.container.core
        )
        let group = try await fixture.container.core.createRuntimeObjectGroup(
            named: "frame",
            boundTo: contextID
        )

        try await fixture.runtime.peer.destroyTarget(
            id: "frame-runtime-agent"
        )
        await #expect(
            throws: WebInspectorRuntimeCommandGatewayError.staleAuthority
        ) {
            _ = try await fixture.container.core.evaluateRuntimeExpression(
                "self",
                in: group.token
            )
        }
    }
}

@Test
func detachDrainsRuntimeOperationsDiscardsTombstonesAndNeverReusesTokens()
    async throws
{
    let first = try await RuntimeGatewayFixture.start(domains: [.runtime])
    let oldGroup = try await first.container.core.createRuntimeObjectGroup(
        named: "old-attachment"
    )
    let gate = await first.wire.deferReply(
        to: "Runtime.evaluate",
        with: try rawRuntimeEvaluationResult(
            Runtime.EvaluationResult(
                object: Runtime.RemoteObject(
                    id: Runtime.RemoteObject.ID("old-object"),
                    kind: .object
                )
            )
        )
    )
    let core = first.container.core
    let evaluation = Task.detached {
        try await core.evaluateRuntimeExpression("window", in: oldGroup.token)
    }
    _ = await first.wire.observations.waitForCommands(
        method: "Runtime.evaluate",
        count: 1
    )
    await first.wire.respond(to: "Runtime.disable")
    await first.wire.respond(to: "Page.disable")
    let detach = Task { await first.container.detach() }
    await #expect(
        throws: WebInspectorRuntimeCommandGatewayError.staleAuthority
    ) {
        _ = try await evaluation.value
    }
    await detach.value
    gate.open()
    #expect(first.container.state == .detached)
    let detachedMetrics = await core.runtimeCommandGatewayMetrics
    #expect(detachedMetrics.graphCount == 0)
    #expect(detachedMetrics.operationCount == 0)
    await first.runtime.close()
    await first.wire.stop()

    let replacementRuntime = try await WebInspectorProxyTestRuntime.start()
    let replacementWire = WebInspectorRawWireDriver(
        peer: replacementRuntime.peer
    )
    await replacementWire.start()
    await replacementWire.respond(to: "Page.enable")
    await replacementWire.respond(to: "Runtime.enable")
    try await first.container.attach(owning: replacementRuntime.proxy)
    let replacementGroup = try await core.createRuntimeObjectGroup(
        named: "replacement-attachment"
    )
    #expect(replacementGroup.token != oldGroup.token)
    await #expect(
        throws: WebInspectorRuntimeCommandGatewayError.graphNotFound
    ) {
        _ = try await core.evaluateRuntimeExpression(
            "window",
            in: oldGroup.token
        )
    }

    await replacementWire.respond(to: "Runtime.releaseObjectGroup")
    try await core.closeRuntimeObjectGraph(replacementGroup.token)
    await replacementWire.respond(to: "Runtime.disable")
    await replacementWire.respond(to: "Page.disable")
    await first.container.close()
    await replacementRuntime.close()
    await replacementWire.stop()
}

private func emitCanonicalConsoleMessage(
    text: String,
    rawObjectID: String,
    targetID: String = "page-main",
    wire: WebInspectorRawWireDriver,
    core: WebInspectorModelContainerCore
) async throws -> CanonicalConsoleMessageIDStorage {
    try await wire.emitRaw(
        .messageAdded(
            Console.Message(
                source: Console.Source(rawValue: "console-api"),
                level: Console.Level(rawValue: "log"),
                type: Console.Kind(rawValue: "log"),
                text: text,
                repeatCount: 1,
                parameters: [
                    Runtime.RemoteObject(
                        id: Runtime.RemoteObject.ID(rawObjectID),
                        kind: .object,
                        description: text
                    )
                ]
            )
        ),
        target: WebInspectorTarget.ID(targetID)
    )
    for _ in 0..<10_000 {
        let message = await core.canonicalSnapshotForTesting()
            .consoleRuntime?.consoleMessages.lazy
            .map(\.record)
            .first { $0.text == text }
        if let message {
            return message.id
        }
        await Task.yield()
    }
    throw RuntimeGatewayTestError.timedOut
}

private func emitCanonicalRuntimeContext(
    rawID: String,
    targetID: String = "page-main",
    wire: WebInspectorRawWireDriver,
    core: WebInspectorModelContainerCore
) async throws -> CanonicalRuntimeContextIDStorage {
    try await wire.emitRaw(
        .executionContextCreated(
            Runtime.ExecutionContext(
                id: Runtime.ExecutionContext.ID(rawID),
                name: "context-\(rawID)",
                frameID: FrameID("main-frame"),
                kind: .normal
            )
        ),
        target: WebInspectorTarget.ID(targetID)
    )
    for _ in 0..<10_000 {
        let context = await core.canonicalSnapshotForTesting()
            .consoleRuntime?.runtimeContexts.lazy
            .map(\.record)
            .first { $0.id.rawContextID.unscopedRawValue == rawID }
        if let context {
            return context.id
        }
        await Task.yield()
    }
    throw RuntimeGatewayTestError.timedOut
}

private func requireRuntimeGatewayTarget(
    _ targetID: WebInspectorTarget.ID,
    in core: WebInspectorModelContainerCore
) async throws {
    for _ in 0..<10_000 {
        if await core.canonicalSnapshotForTesting().binding?
            .targets.contains(where: { $0.target.id == targetID }) == true
        {
            return
        }
        await Task.yield()
    }
    throw RuntimeGatewayTestError.timedOut
}

private func requireRuntimeGatewayOperationCount(
    _ expectedCount: Int,
    in core: WebInspectorModelContainerCore
) async {
    for _ in 0..<10_000 {
        if await core.runtimeCommandGatewayMetrics.operationCount
            == expectedCount
        {
            return
        }
        await Task.yield()
    }
    Issue.record("Runtime gateway operation count did not quiesce.")
}

private func requireRuntimeGatewayOpenGraphCount(
    _ expectedCount: Int,
    in core: WebInspectorModelContainerCore
) async {
    for _ in 0..<10_000 {
        if await core.runtimeCommandGatewayMetrics.openGraphCount
            == expectedCount
        {
            return
        }
        await Task.yield()
    }
    Issue.record("Runtime gateway graph lifecycle did not advance.")
}

private struct RuntimeObjectCommandParameters: Decodable {
    let objectId: String
}

private struct RuntimeGroupCommandParameters: Decodable {
    let objectGroup: String
}
