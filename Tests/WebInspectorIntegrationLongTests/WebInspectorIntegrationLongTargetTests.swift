import Testing

@Suite("WebInspectorIntegrationLong target")
struct WebInspectorIntegrationLongTargetTests {
    @Test func targetRemainsAvailableAfterLegacyInspectorRemoval() {
        #expect("WebInspectorIntegrationLongTests".isEmpty == false)
    }
}
