import Testing
@testable import WebInspectorDataKit
import WebInspectorProxyKit
import WebInspectorProxyKitTesting

@MainActor
@Test
func runtimeObjectScopeOwnsEvaluationPropertiesAndClose() async throws {
    let container = WebInspectorModelContainer(
        configuration: .init(enabledFeatures: [.consoleRuntime])
    )

    try await withDataKitTestRuntime { runtime in
        await runtime.wire.respond(to: "Page.enable")
        await runtime.wire.respond(to: "Console.enable")
        await runtime.wire.respond(to: "Runtime.enable")
        await runtime.wire.respond(
            to: "Page.getResourceTree",
            with: try consoleRuntimeResourceTreeResult()
        )
        try await container.attach(owning: runtime.proxy)
        #expect(await waitForRuntimeReady(in: container))

        do {
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
            let scope = await container.runtime.makeObjectScope()
            let evaluation = try await scope.evaluate("({ value: 1 })")
            #expect(!evaluation.isException)
            #expect(evaluation.object.description == "root")
            #expect(evaluation.object.canRequestProperties)

            await runtime.wire.respond(
                to: "Runtime.getProperties",
                with: try rawRuntimePropertiesResult([
                    Runtime.PropertyDescriptor(
                        name: "value",
                        value: Runtime.RemoteObject(
                            id: nil,
                            kind: .number,
                            description: "1",
                            value: .number(1)
                        ),
                        enumerable: true,
                        isOwn: true
                    )
                ])
            )
            let properties = try await scope.properties(of: evaluation.object)
            #expect(properties.map(\.name) == ["value"])
            #expect(properties.first?.value == "1")

            await runtime.wire.respond(to: "Runtime.releaseObject")
            await scope.close()
            await #expect(throws: WebInspectorCommandError.staleIdentifier) {
                _ = try await scope.evaluate("2")
            }

            let methods = runtime.wire.observations.commands.map(\.method)
            #expect(methods.contains("Runtime.evaluate"))
            #expect(methods.contains("Runtime.getProperties"))
            #expect(methods.contains("Runtime.releaseObject"))

            await closeRuntimeFeatureAttachment(container, runtime: runtime)
        } catch {
            await closeRuntimeFeatureAttachment(container, runtime: runtime)
            throw error
        }
    }
}

@MainActor
private func waitForRuntimeReady(
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

private func consoleRuntimeResourceTreeResult() throws
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

@MainActor
private func closeRuntimeFeatureAttachment(
    _ container: WebInspectorModelContainer,
    runtime: DataKitTestRuntime
) async {
    await runtime.wire.respond(to: "Runtime.disable")
    await runtime.wire.respond(to: "Console.disable")
    await runtime.wire.respond(to: "Page.disable")
    await container.close()
}
