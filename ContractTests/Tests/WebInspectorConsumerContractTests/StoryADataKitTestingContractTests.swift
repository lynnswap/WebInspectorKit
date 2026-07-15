import Testing
import WebInspectorDataKit
import WebInspectorDataKitTesting

@MainActor
@Test
func readyDataKitScenarioIsUsableFromAConsumerPackage() async throws {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(enabledFeatures: [.dom, .network]),
            document: .init(children: [
                .element(id: "contract-button", name: "button")
            ]),
            networkReplay: [
                .init(
                    id: "contract-request",
                    url: "https://example.test/contract",
                    body: .init(data: "contract body")
                )
            ]
        )
    )
    let context = runtime.container.mainContext

    let entries = WebInspectorFetchedResultsController<NetworkEntry>(
        modelContext: context
    )
    try await entries.performFetch()
    let entry = try #require(entries.fetchedObjects?.first)
    let request = try #require(context.model(for: entry.primaryRequestID))
    #expect(request.url == "https://example.test/contract")

    let body = try await runtime.container.network.responseBody(for: request.id)
    #expect(body.data == "contract body")
    #expect(body.base64Encoded == false)

    let nodes = WebInspectorFetchedResultsController<DOMNode>(
        modelContext: context
    )
    try await nodes.performFetch()
    #expect(nodes.fetchedObjects?.contains { $0.localName == "button" } == true)

    await nodes.close()
    await entries.close()
    await runtime.close()
    #expect(runtime.container.state == .closed)
    #expect(await runtime.lifecycleState == .closed)
}

@MainActor
@Test
func dataKitScenarioReportsAttachmentFailure() async {
    do {
        _ = try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(enabledFeatures: [.network]),
                attachFailure: .init(
                    domain: .network,
                    message: "contract attachment failure"
                )
            )
        )
        Issue.record("An injected Network bootstrap failure started a runtime.")
    } catch let WebInspectorDataKitTestRuntime.RuntimeError.connectionFailed(failure) {
        guard case let .native(description) = failure else {
            Issue.record("Expected a native feature failure, got \(failure).")
            return
        }
        #expect(description.message.contains("contract attachment failure"))
    } catch {
        Issue.record("Expected RuntimeError.connectionFailed, got \(error).")
    }
}
