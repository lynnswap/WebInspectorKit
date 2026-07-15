import Foundation
import Testing
@testable import WebInspectorProxyKit

@Test(arguments: [
    (#"null"#, #"null"#),
    (#"42"#, #"42"#),
    (#""value""#, #""value""#),
    (#"[1,null,{"nested":true}]"#, #"[1,null,{"nested":true}]"#),
    (#"{"value":false}"#, #"{"value":false}"#),
])
func parserPreservesExplicitParameterShape(input: String, expected: String) async throws {
    let parsed = try await ConnectionMessageParser.parse(
        #"{"method":"Future.changed","params":\#(input)}"#,
        policy: ConnectionMessageParsePolicy(detachedParsingThresholdBytes: 0)
    )

    #expect(parsed.method?.rawValue == "Future.changed")
    #expect(try jsonSemanticallyEqual(parsed.parameters, Data(expected.utf8)))
}

@Test
func parserNormalizesOnlyAbsentParametersAndResultToObjects() async throws {
    let parsed = try await ConnectionMessageParser.parse(#"{"id":7,"method":"Future.changed"}"#)

    #expect(try jsonSemanticallyEqual(parsed.parameters, Data("{}".utf8)))
    #expect(try jsonSemanticallyEqual(parsed.result, Data("{}".utf8)))
}

@Test
func parserRejectsUnreadableOuterEnvelope() async {
    await #expect(throws: ConnectionError.self) {
        _ = try await ConnectionMessageParser.parse(#"["not","an","envelope"]"#)
    }
}

@Test
func parserPreservesProtocolErrorCodeAndMessage() async throws {
    let parsed = try await ConnectionMessageParser.parse(
        #"{"id":7,"error":{"code":-32601,"message":"Method not found"}}"#
    )

    #expect(
        parsed.error
            == ParsedProtocolError(code: -32_601, message: "Method not found")
    )
}

@Test
func parserAcceptsExplicitNullProtocolError() async throws {
    let parsed = try await ConnectionMessageParser.parse(
        #"{"id":7,"result":{},"error":null}"#
    )

    #expect(parsed.error == nil)
}

@Test
func parserRejectsProtocolErrorWithoutMessage() async {
    await #expect(throws: ConnectionError.unreadableEnvelope) {
        _ = try await ConnectionMessageParser.parse(
            #"{"id":7,"error":{"code":-32601}}"#
        )
    }
}

@Test
func commandEncoderPreservesFragmentParameters() throws {
    let message = try ConnectionMessageParser.makeCommandString(
        id: 8,
        method: WebInspectorProtocolMethod(rawValue: "Future.command"),
        parameters: Data("null".utf8)
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(message.utf8), options: [.fragmentsAllowed]) as? [String: Any]
    )

    #expect(object["params"] is NSNull)
}

private func jsonSemanticallyEqual(_ lhs: Data, _ rhs: Data) throws -> Bool {
    let left = try JSONSerialization.jsonObject(with: lhs, options: [.fragmentsAllowed])
    let right = try JSONSerialization.jsonObject(with: rhs, options: [.fragmentsAllowed])
    return (left as AnyObject).isEqual(right)
}
