import Foundation
import Testing
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport

typealias DataKitRawWireGate = WebInspectorTestGate
typealias DataKitRawWireDriver = WebInspectorRawWireDriver
typealias DOMNodeWire = WebInspectorDOMNodeWire

struct DataKitTestRuntime: Sendable {
    let runtime: WebInspectorProxyTestRuntime
    let wire: DataKitRawWireDriver

    var proxy: WebInspectorProxy { runtime.proxy }
    var peer: WebInspectorTestPeer { runtime.peer }
    var page: WebInspectorPage { runtime.page }

    fileprivate static func start(
        configuration: WebInspectorProxy.Configuration = .init(),
        initialTarget: WebInspectorTestPeer.Target = .initialPage
    ) async throws -> Self {
        let runtime = try await WebInspectorProxyTestRuntime.start(
            configuration: configuration,
            initialTarget: initialTarget
        )
        let wire = DataKitRawWireDriver(peer: runtime.peer)
        await wire.start()
        return Self(runtime: runtime, wire: wire)
    }

    fileprivate func close() async {
        // Core owns connection termination; the wire driver only joins its
        // consumer and reply tasks after the peer mailbox becomes terminal.
        await runtime.close()
        await wire.stop()
    }
}

@MainActor
func withDataKitTestRuntime<Result>(
    configuration: WebInspectorProxy.Configuration = .init(),
    initialTarget: WebInspectorTestPeer.Target = .initialPage,
    _ operation: @MainActor (DataKitTestRuntime) async throws -> Result
) async throws -> Result {
    let testRuntime = try await DataKitTestRuntime.start(
        configuration: configuration,
        initialTarget: initialTarget
    )

    do {
        let result = try await operation(testRuntime)
        await testRuntime.close()
        return result
    } catch {
        await testRuntime.close()
        throw error
    }
}

func testJSONObject(_ json: String) throws -> WebInspectorTestJSONObject {
    try webInspectorTestJSONObject(json)
}

func testJSONObject<Value: Encodable>(_ value: Value) throws -> WebInspectorTestJSONObject {
    try webInspectorTestJSONObject(value)
}

func emptyDocumentResult(
    nodeID: String = "document",
    frameID: String = "main-frame",
    childNodeCount: Int = 0
) throws -> WebInspectorTestJSONObject {
    try testJSONObject(
        """
        {
          "root": {
            "nodeId": "\(nodeID)",
            "nodeType": 9,
            "nodeName": "#document",
            "localName": "",
            "nodeValue": "",
            "frameId": "\(frameID)",
            "childNodeCount": \(childNodeCount)
          }
        }
        """
    )
}

func domDocumentResult(_ document: DOM.Node) throws -> WebInspectorTestJSONObject {
    try webInspectorDOMDocumentResult(document)
}
