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
}
