import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@MainActor
@Test
func consoleRuntimeBootstrapAppliesNavigationPrefixInFIFOOrder() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.consoleRuntime])
    )
    let contexts = WebInspectorFetchedResultsController<RuntimeContext>(
        modelContext: container.mainContext
    )

    do {
        try await withDataKitTestRuntime { runtime in
            await enqueueConsoleRuntimeCapabilityReplies(runtime)
            let resourceTreeReply = await runtime.wire.deferReply(
                to: "Page.getResourceTree",
                with: try consoleRuntimeLifecycleResourceTreeResult(
                    mainLoaderID: "loader-new"
                )
            )
            let attachment = Task {
                try await container.attach(owning: runtime.proxy)
            }
            _ = await runtime.wire.observations.waitForCommands(
                method: "Page.getResourceTree",
                count: 1
            )

            try await emitRuntimeContext(
                id: "context-old",
                name: "old",
                frameID: "main-frame",
                through: runtime.wire
            )
            try await emitFrameNavigation(
                frameID: "main-frame",
                loaderID: "loader-new",
                through: runtime.wire
            )
            try await emitRuntimeContext(
                id: "context-new",
                name: "new",
                frameID: "main-frame",
                through: runtime.wire
            )
            resourceTreeReply.open()
            try await attachment.value

            try await contexts.performFetch()
            #expect(contexts.fetchedObjects?.map(\.name) == ["new"])

            await contexts.close()
            await enqueueConsoleRuntimeDisableReplies(runtime)
            await container.close()
        }
    } catch {
        await contexts.close()
        await container.close()
        throw error
    }
}

@MainActor
@Test
func consoleRuntimeInvalidatesHandlesBeforeAwaitingNavigationRelease() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.consoleRuntime])
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareConsoleRuntimeLifecycleAttachment(
                container,
                runtime: runtime
            )
            let scope = await container.runtime.makeObjectScope()
            await runtime.wire.respond(
                to: "Runtime.evaluate",
                with: try rawRuntimeEvaluationResult(
                    Runtime.EvaluationResult(
                        object: Runtime.RemoteObject(
                            id: Runtime.RemoteObject.ID("root-object"),
                            kind: .object,
                            description: "root"
                        )
                    )
                )
            )
            let root = try await scope.evaluate("({ value: {} })").object

            let propertiesReply = await runtime.wire.deferReply(
                to: "Runtime.getProperties",
                with: try rawRuntimePropertiesResult([
                    Runtime.PropertyDescriptor(
                        name: "value",
                        value: Runtime.RemoteObject(
                            id: Runtime.RemoteObject.ID("child-object"),
                            kind: .object,
                            description: "child"
                        ),
                        enumerable: true,
                        isOwn: true
                    )
                ])
            )
            let firstProperties = Task {
                try await scope.properties(of: root)
            }
            _ = await runtime.wire.observations.waitForCommands(
                method: "Runtime.getProperties",
                count: 1
            )

            let navigationRelease = await runtime.wire.deferReply(
                to: "Runtime.releaseObject"
            )
            await runtime.wire.respond(to: "Runtime.releaseObject")
            try await emitFrameNavigation(
                frameID: "main-frame",
                loaderID: "loader-next",
                through: runtime.wire
            )
            _ = await runtime.wire.observations.waitForCommands(
                method: "Runtime.releaseObject",
                count: 1
            )

            await #expect(throws: WebInspectorCommandError.staleIdentifier) {
                _ = try await scope.properties(of: root)
            }
            #expect(
                runtime.wire.observations.commandMethods.filter {
                    $0 == "Runtime.getProperties"
                }.count == 1
            )

            navigationRelease.open()
            propertiesReply.open()
            await #expect(throws: WebInspectorCommandError.staleIdentifier) {
                _ = try await firstProperties.value
            }
            _ = await runtime.wire.observations.waitForCompletedCommands(
                method: "Runtime.releaseObject",
                count: 2
            )

            await scope.close()
            await enqueueConsoleRuntimeDisableReplies(runtime)
            await container.close()
        }
    } catch {
        await container.close()
        throw error
    }
}

@MainActor
@Test
func childFrameNavigationPreservesMainFrameContextAndHandle() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.consoleRuntime])
    )
    let contexts = WebInspectorFetchedResultsController<RuntimeContext>(
        modelContext: container.mainContext
    )

    do {
        try await withDataKitTestRuntime { runtime in
            try await prepareConsoleRuntimeLifecycleAttachment(
                container,
                runtime: runtime,
                includesChildFrame: true
            )
            try await contexts.performFetch()
            try await emitRuntimeContext(
                id: "main-context",
                name: "main",
                frameID: "main-frame",
                through: runtime.wire
            )
            try await emitRuntimeContext(
                id: "child-context",
                name: "child",
                frameID: "child-frame",
                through: runtime.wire
            )
            #expect(
                await waitForRuntimeContextNames(
                    ["main", "child"],
                    in: contexts
                )
            )
            let fetched = try #require(contexts.fetchedObjects)
            let mainContext = try #require(
                fetched.first(where: { $0.name == "main" })
            )
            let childContext = try #require(
                fetched.first(where: { $0.name == "child" })
            )

            let scope = await container.runtime.makeObjectScope()
            await runtime.wire.respond(
                to: "Runtime.evaluate",
                with: try rawRuntimeEvaluationResult(
                    Runtime.EvaluationResult(
                        object: Runtime.RemoteObject(
                            id: Runtime.RemoteObject.ID("main-object"),
                            kind: .object,
                            description: "main"
                        )
                    )
                )
            )
            let mainObject = try await scope.evaluate(
                "({ main: true })",
                in: mainContext.id
            ).object
            await runtime.wire.respond(
                to: "Runtime.evaluate",
                with: try rawRuntimeEvaluationResult(
                    Runtime.EvaluationResult(
                        object: Runtime.RemoteObject(
                            id: Runtime.RemoteObject.ID("child-object"),
                            kind: .object,
                            description: "child"
                        )
                    )
                )
            )
            let childObject = try await scope.evaluate(
                "({ child: true })",
                in: childContext.id
            ).object

            await runtime.wire.respond(to: "Runtime.releaseObject")
            try await emitFrameNavigation(
                frameID: "child-frame",
                parentFrameID: "main-frame",
                loaderID: "child-loader-next",
                through: runtime.wire
            )
            _ = await runtime.wire.observations.waitForCompletedCommands(
                method: "Runtime.releaseObject",
                count: 1
            )
            #expect(
                await waitForRuntimeContextNames(["main"], in: contexts)
            )

            await #expect(throws: WebInspectorCommandError.staleIdentifier) {
                _ = try await scope.properties(of: childObject)
            }
            await runtime.wire.respond(
                to: "Runtime.getProperties",
                with: try rawRuntimePropertiesResult([
                    Runtime.PropertyDescriptor(
                        name: "main",
                        value: Runtime.RemoteObject(
                            id: nil,
                            kind: .boolean,
                            description: "true",
                            value: .bool(true)
                        ),
                        enumerable: true,
                        isOwn: true
                    )
                ])
            )
            let mainProperties = try await scope.properties(of: mainObject)
            #expect(mainProperties.map(\.name) == ["main"])

            await runtime.wire.respond(to: "Runtime.releaseObject")
            await scope.close()
            await contexts.close()
            await enqueueConsoleRuntimeDisableReplies(runtime)
            await container.close()
        }
    } catch {
        await contexts.close()
        await container.close()
        throw error
    }
}

@MainActor
private func prepareConsoleRuntimeLifecycleAttachment(
    _ container: WebInspectorModelContainer,
    runtime: DataKitTestRuntime,
    includesChildFrame: Bool = false
) async throws {
    await enqueueConsoleRuntimeCapabilityReplies(runtime)
    await runtime.wire.respond(
        to: "Page.getResourceTree",
        with: try consoleRuntimeLifecycleResourceTreeResult(
            mainLoaderID: "loader-initial",
            includesChildFrame: includesChildFrame
        )
    )
    try await container.attach(owning: runtime.proxy)
    #expect(await waitForConsoleRuntimeReady(in: container))
}

private func enqueueConsoleRuntimeCapabilityReplies(
    _ runtime: DataKitTestRuntime
) async {
    await runtime.wire.respond(to: "Page.enable")
    await runtime.wire.respond(to: "Console.enable")
    await runtime.wire.respond(to: "Runtime.enable")
}

private func enqueueConsoleRuntimeDisableReplies(
    _ runtime: DataKitTestRuntime
) async {
    await runtime.wire.respond(to: "Runtime.disable")
    await runtime.wire.respond(to: "Console.disable")
    await runtime.wire.respond(to: "Page.disable")
}

private func consoleRuntimeLifecycleResourceTreeResult(
    mainLoaderID: String,
    includesChildFrame: Bool = false
) throws -> WebInspectorTestJSONObject {
    let childFrame =
        includesChildFrame
        ? #"""
        ,"childFrames":[{
          "frame":{
            "id":"child-frame",
            "parentId":"main-frame",
            "loaderId":"child-loader-initial",
            "name":"",
            "url":"https://child.example.test/",
            "mimeType":"text/html"
          },
          "resources":[]
        }]
        """#
        : ""
    return try testJSONObject(
        #"""
        {
          "frameTree":{
            "frame":{
              "id":"main-frame",
              "loaderId":"\#(mainLoaderID)",
              "name":"",
              "url":"https://example.test/",
              "mimeType":"text/html"
            },
            "resources":[]\#(childFrame)
          }
        }
        """#
    )
}

private func emitRuntimeContext(
    id: String,
    name: String,
    frameID: String,
    through wire: DataKitRawWireDriver
) async throws {
    try await wire.emitTargetEvent(
        targetID: "page-main",
        method: "Runtime.executionContextCreated",
        parameters: try testJSONObject(
            #"""
            {
              "context":{
                "id":"\#(id)",
                "name":"\#(name)",
                "frameId":"\#(frameID)",
                "type":"normal"
              }
            }
            """#
        )
    )
}

private func emitFrameNavigation(
    frameID: String,
    parentFrameID: String? = nil,
    loaderID: String,
    through wire: DataKitRawWireDriver
) async throws {
    let parent = parentFrameID.map { #", "parentId":"\#($0)""# } ?? ""
    try await wire.emitTargetEvent(
        targetID: "page-main",
        method: "Page.frameNavigated",
        parameters: try testJSONObject(
            #"""
            {
              "frame":{
                "id":"\#(frameID)"\#(parent),
                "loaderId":"\#(loaderID)",
                "name":"",
                "url":"https://example.test/",
                "mimeType":"text/html"
              }
            }
            """#
        )
    )
}

@MainActor
private func waitForRuntimeContextNames(
    _ expected: Set<String>,
    in results: WebInspectorFetchedResultsController<RuntimeContext>
) async -> Bool {
    for _ in 0..<1_000 {
        if Set((results.fetchedObjects ?? []).map(\.name)) == expected {
            return true
        }
        await Task.yield()
    }
    return false
}

@MainActor
private func waitForConsoleRuntimeReady(
    in container: WebInspectorModelContainer
) async -> Bool {
    for _ in 0..<1_000 {
        if case .ready = container.runtime.state {
            return true
        }
        await Task.yield()
    }
    return false
}
