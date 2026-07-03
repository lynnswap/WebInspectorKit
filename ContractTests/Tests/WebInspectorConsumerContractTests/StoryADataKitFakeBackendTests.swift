import Testing
import WebViewDataKit
import WebViewProxyKit
import WebViewProxyKitTesting

@MainActor
@Test
func fakeBackendDrivesDataKitDOMNetworkAndRuntimeContracts() async throws {
    let runtime = try await WebViewProxyTestRuntime.start()
    let document = WebViewProxyTestFixtures.domDocument(
        id: "contract-document",
        documentURL: "https://example.com/",
        childNodeCount: 1
    )
    let (target, container, context) = try await ContractTestSupport.startDataKitContext(
        runtime: runtime,
        document: document
    )

    await runtime.backend.emit(
        .setChildNodes(parent: WebViewProxyTestFixtures.domNodeID("contract-document"), nodes: [
            WebViewProxyTestFixtures.domNode(
                id: "contract-element",
                nodeType: 1,
                nodeName: "MAIN",
                localName: "main",
                attributes: ["data-contract": "dom"]
            ),
        ]),
        target: target
    )

    try await ContractTestSupport.waitUntil {
        guard let root = context.rootNode,
              case let .loaded(children) = root.children else {
            return false
        }
        return children.first?.attributes["data-contract"] == "dom"
    }
    let root = try #require(context.rootNode)
    guard case let .loaded(children) = root.children else {
        Issue.record("Expected the seeded document to load children.")
        return
    }
    let child = try #require(children.first)
    #expect(context.node(for: child.id) === child)

    let request = WebViewProxyTestFixtures.networkRequest(
        id: "contract-request",
        url: "https://example.com/data.json",
        headers: ["Accept": "application/json"]
    )
    await ContractTestSupport.emitFinishedRequest(request, target: target, backend: runtime.backend)

    let requests: WebViewFetchedResults<NetworkRequest> = context.fetchedResults(for: .allRequests)
    try await ContractTestSupport.waitUntil {
        requests.items.first?.state == .finished
    }
    let requestModel = try #require(requests.items.first)
    #expect(requestModel.url == "https://example.com/data.json")
    #expect(requestModel.method == "GET")
    #expect(requestModel.status == 200)
    #expect(requestModel.responseHeaders["Content-Type"] == "application/json")
    #expect(requestModel.decodedDataLength == 7)
    #expect(requestModel.encodedDataLength == 4)
    #expect(context.registeredRequest(for: requestModel.id) === requestModel)

    await runtime.backend.enqueue(
        Network.Body(data: "{\"ok\":true}", base64Encoded: false),
        for: "Network",
        method: "getResponseBody"
    )
    await requestModel.fetchResponseBody()
    #expect(requestModel.responseBody.phase == .loaded)
    #expect(requestModel.responseBody.text == "{\"ok\":true}")
    #expect(requestModel.responseBody.isBase64Encoded == false)

    await runtime.backend.enqueue(
        Runtime.EvaluationResult(
            object: WebViewProxyTestFixtures.runtimeRemoteObject(
                id: "contract-evaluation",
                kind: .string,
                description: "contract",
                value: .string("contract")
            )
        ),
        for: "Runtime",
        method: "evaluate"
    )

    let evaluation = try await context.evaluate("document.title")
    #expect(evaluation.isException == false)
    #expect(evaluation.object.kind == .string)
    #expect(evaluation.object.value == .string("contract"))
    #expect(evaluation.object.description == "contract")
    #expect(evaluation.object.canRequestProperties)

    await ContractTestSupport.enqueueDataKitShutdownReplies(on: runtime.backend)
    await container.close()
}
