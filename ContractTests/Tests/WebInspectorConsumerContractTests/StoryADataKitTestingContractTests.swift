import Testing
import WebInspectorDataKit
import WebInspectorDataKitTesting

@MainActor
@Test
func readyDataKitScenarioIsUsableFromAConsumerPackage() async throws {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(domains: [.dom, .network]),
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
        ),
        isolation: MainActor.shared
    )

    let entries = try await WebInspectorFetchedResultsController<NetworkEntry, Never>(
        modelContext: runtime.model
    )
    let entryID = try #require(entries.snapshot.itemIDs.first)
    let entry = try #require(runtime.model.model(for: entryID))
    let request = try #require(runtime.model.model(for: entry.primaryRequestID))
    #expect(request.url == "https://example.test/contract")
    let body = try await runtime.model.responseBody(for: request)
    #expect(body.text == "contract body")
    try await runtime.model.clearNetworkRequests()
    #expect(entries.snapshot.itemIDs.isEmpty)

    let nodes = try await WebInspectorFetchedResultsController<DOMNode, Never>(
        modelContext: runtime.model
    )
    #expect(nodes.snapshot.itemIDs.contains { id in
        runtime.model.model(for: id)?.localName == "button"
    })

    try await runtime.replacePage(with: .init())
    #expect(nodes.snapshot.itemIDs.count == 1)
    let documentID = try #require(nodes.snapshot.itemIDs.first)
    #expect(runtime.model.model(for: documentID)?.nodeName == "#document")

    await nodes.close()
    await entries.close()
    await runtime.close()
    #expect(runtime.container.state == .closed)
    #expect(runtime.model.state == .closed)
}

@MainActor
@Test
func dataKitScenarioCanInjectAnAttachmentFailure() async {
    do {
        _ = try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(domains: [.network]),
                attachFailure: .init(
                    domain: .network,
                    message: "contract attachment failure"
                )
            ),
            isolation: MainActor.shared
        )
        Issue.record("Expected the scenario attachment to fail.")
    } catch let failure as WebInspectorModelContainer.Failure {
        guard case let .bootstrap(domain, message) = failure else {
            Issue.record("Expected a bootstrap failure, got \(failure).")
            return
        }
        #expect(domain == .network)
        #expect(message.contains("contract attachment failure"))
    } catch {
        Issue.record("Expected a DataKit model failure, got \(error).")
    }
}
