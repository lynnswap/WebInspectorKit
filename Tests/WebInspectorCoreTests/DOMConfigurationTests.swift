import Testing
@testable import WebInspectorCore

struct DOMConfigurationTests {
    @Test
    func publicDepthSettingsMapToInternalFetchPolicy() {
        var configuration = DOMConfiguration(
            autoUpdateDebounce: 0.25,
            snapshotDepth: 5,
            subtreeDepth: 3
        )

        #expect(configuration.autoUpdateDebounce == 0.25)
        #expect(configuration.snapshotDepth == 5)
        #expect(configuration.subtreeDepth == 3)
        #expect(configuration.rootBootstrapDepth == 5)
        #expect(configuration.expandedSubtreeFetchDepth == 3)

        configuration.snapshotDepth = 7
        configuration.subtreeDepth = 4

        #expect(configuration.snapshotDepth == 7)
        #expect(configuration.subtreeDepth == 4)
        #expect(configuration.rootBootstrapDepth == 7)
        #expect(configuration.expandedSubtreeFetchDepth == 4)
        #expect(configuration.selectionRecoveryDepth >= configuration.snapshotDepth)
        #expect(configuration.fullReloadDepth >= configuration.selectionRecoveryDepth)

        configuration.snapshotDepth = 20
        #expect(configuration.selectionRecoveryDepth == 20)
        #expect(configuration.fullReloadDepth == 20)

        configuration.snapshotDepth = 4
        #expect(configuration.selectionRecoveryDepth == 6)
        #expect(configuration.fullReloadDepth == 8)
    }
}
