import Testing
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorProxyKit

@MainActor
@Test
func dataKitTestingStartsReadyWithReplayAndDrivesPickerSelection() async throws {
    let replay = WebInspectorDataKitTestRuntime.NetworkRequest(
        id: "initial-request",
        url: "https://example.test/initial",
        status: 201,
        body: Network.Body(data: "ready body")
    )
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(domains: [.dom, .network]),
            document: .init(children: [
                .element(id: "button", name: "button")
            ]),
            networkReplay: [replay]
        ),
        isolation: MainActor.shared
    )

    #expect(runtime.model.state == .attached)
    #expect(try runtime.model.rootDOMNode?.nodeName == "#document")
    let request = try #require(try runtime.model.networkRequest(
        id: NetworkRequest.ID(Network.Request.ID("initial-request"))
    ))
    #expect(request.statusCode == 201)
    #expect(request.state == .finished)

    let selected = try await runtime.selectElementWithPicker(nodeID: "button")
    #expect(selected.localName == "button")
    #expect(try runtime.model.selectedDOMNode === selected)

    let body = try await runtime.model.responseBody(for: request)
    #expect(body.text == "ready body")

    await runtime.close()
    #expect(runtime.model.state == .closed)
}

@MainActor
@Test
func dataKitTestingWaitsForReplacementBootstrapAndReplaysNewPage() async throws {
    let runtime = try await WebInspectorDataKitTestRuntime.start(
        scenario: .init(
            configuration: .init(domains: [.dom, .network]),
            document: .init(children: [
                .element(id: "old-node", name: "main")
            ])
        ),
        isolation: MainActor.shared
    )
    let precedingGeneration = runtime.model.pageGeneration

    try await runtime.replacePage(
        with: .init(children: [
            .element(id: "new-node", name: "article")
        ]),
        networkReplay: [
            .init(id: "replacement-request", url: "https://example.test/new")
        ]
    )

    #expect(runtime.model.state == .attached)
    #expect(runtime.model.pageGeneration != precedingGeneration)
    let newNode = try #require(try runtime.model.domNode(
        id: DOMNode.ID(DOM.Node.ID("new-node"))
    ))
    #expect(newNode.localName == "article")
    #expect(try runtime.model.domNode(id: DOMNode.ID(DOM.Node.ID("old-node"))) == nil)
    #expect(try runtime.model.networkRequest(
        id: NetworkRequest.ID(Network.Request.ID("replacement-request"))
    )?.state == .finished)

    await runtime.close()
}

@MainActor
@Test
func dataKitTestingInjectsAttachmentFailureWithoutLeakingRuntimeOwnership() async {
    do {
        _ = try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(domains: [.network]),
                attachFailure: .init(
                    domain: .network,
                    message: "injected Network startup failure"
                )
            ),
            isolation: MainActor.shared
        )
        Issue.record("Expected the injected DataKit attachment failure.")
    } catch let failure as WebInspectorModelContext.Failure {
        guard case let .bootstrap(domain, message) = failure else {
            Issue.record("Expected a bootstrap failure, got \(failure).")
            return
        }
        #expect(domain == .network)
        #expect(message.contains("injected Network startup failure"))
    } catch {
        Issue.record("Expected a DataKit model failure, got \(error).")
    }
}
