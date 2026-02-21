import Foundation
import Testing
@testable import WebInspectorKit
@testable import WebInspectorKitCore

@MainActor
struct DOMProtocolRouterTests {
    @Test
    func decodeFailureReturnsErrorResponseObjectWithRequestIdentifier() async throws {
        let session = DOMSession(configuration: .init())
        let router = DOMProtocolRouter(session: session)

        let outcome = await router.route(
            payload: ["id": 42],
            configuration: .init()
        )

        let response = try #require(outcome.responseObject)
        #expect(response["id"] as? Int == 42)
        let error = response["error"] as? [String: String]
        #expect(error?["message"] == "DOM protocol payload decode failed")
        #expect(outcome.recoverableError == "DOM protocol payload decode failed")
    }

    @Test
    func unsupportedMethodKeepsProtocolErrorShapeInObjectResponse() async throws {
        let session = DOMSession(configuration: .init())
        let router = DOMProtocolRouter(session: session)

        let outcome = await router.route(
            payload: [
                "id": 7,
                "method": "DOM.unsupportedMethod",
                "params": [:],
            ],
            configuration: .init()
        )

        let response = try #require(outcome.responseObject)
        #expect(response["id"] as? Int == 7)
        #expect(response["result"] == nil)

        let error = response["error"] as? [String: String]
        #expect(error?["message"] == "Unsupported method: DOM.unsupportedMethod")
        #expect(outcome.recoverableError == "Unsupported DOM protocol method: DOM.unsupportedMethod")
    }

    @Test
    func decodeFailureDoesNotCoerceBooleanIdentifier() async throws {
        let session = DOMSession(configuration: .init())
        let router = DOMProtocolRouter(session: session)

        let outcome = await router.route(
            payload: ["id": true],
            configuration: .init()
        )

        let response = try #require(outcome.responseObject)
        #expect(response["id"] as? Int == 0)
        let error = response["error"] as? [String: String]
        #expect(error?["message"] == "DOM protocol payload decode failed")
    }

    @Test
    func fallbackJSONResponseUsesFallbackForSerializedEnvelopeResult() throws {
        let session = DOMSession(configuration: .init())
        let router = DOMProtocolRouter(session: session)
        let envelope: [String: Any] = [
            "type": "serialized-node-envelope",
            "node": NSObject(),
            "fallback": [
                "root": [
                    "nodeId": 99,
                    "children": [],
                ],
                "selectedNodeId": 99,
                "selectedNodePath": [0, 1],
            ],
        ]
        let objectResponse: [String: Any] = [
            "id": 7,
            "result": envelope,
        ]

        let responseJSON = try #require(
            router.testFallbackJSONResponse(forObjectResponse: objectResponse)
        )
        let responseData = try #require(responseJSON.data(using: .utf8))
        let response = try #require(
            try JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )

        #expect(response["id"] as? Int == 7)
        let result = try #require(response["result"] as? [String: Any])
        #expect(result["selectedNodeId"] as? Int == 99)
        #expect(result["selectedNodePath"] as? [Int] == [0, 1])
        let root = try #require(result["root"] as? [String: Any])
        #expect(root["nodeId"] as? Int == 99)
    }
}
