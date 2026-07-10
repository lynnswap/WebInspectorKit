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

    let requests = try await runtime.model.networkRequests()
    #expect(requests.items.map(\.url) == ["https://example.test/contract"])
    let body = try await runtime.model.responseBody(for: requests.items[0])
    #expect(body.text == "contract body")
    let selected = try await runtime.selectElementWithPicker(
        nodeID: "contract-button"
    )
    #expect(selected.localName == "button")

    try await runtime.replacePage(with: .init())
    #expect(try runtime.model.rootDOMNode?.nodeName == "#document")
    let selectedDocument = try await runtime.selectElementWithPicker(
        nodeID: "document"
    )
    #expect(selectedDocument.nodeName == "#document")
    do {
        _ = try await runtime.selectElementWithPicker(nodeID: "missing")
        Issue.record("Expected a missing picker fixture failure.")
    } catch let error as WebInspectorDataKitTestRuntime.RuntimeError {
        #expect(error == .selectedNodeMissing("missing"))
    } catch {
        Issue.record("Expected a DataKit testing runtime failure, got \(error).")
    }

    await runtime.close()
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
    } catch let failure as WebInspectorModelContext.Failure {
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
