import Foundation
import WebInspectorProxyKitTesting

enum ContractTestSupport {
    static func jsonObject(
        _ object: [String: Any]
    ) throws -> WebInspectorTestJSONObject {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try WebInspectorTestJSONObject(data: data)
    }
}
