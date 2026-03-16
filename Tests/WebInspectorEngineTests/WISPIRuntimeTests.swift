import Testing
@testable import WebInspectorEngine

@MainActor
struct WISPIRuntimeTests {
    @Test
    func modeResolutionReturnsLegacyWhenCoreCapabilitiesAreMissing() {
        let runtime = WISPIRuntime.shared
        let capabilities = WISPICapabilities(
            hasContentWorldConfiguration: false,
            hasJSHandleClass: false,
            hasSerializedNodeClass: false,
            hasJSBufferClass: false,
            hasWorldWithConfigurationSelector: false,
            hasPublicAddBufferSelector: false,
            hasPublicRemoveBufferSelector: false,
            hasPrivateAddBufferSelector: false,
            hasPrivateRemoveBufferSelector: false
        )

        #expect(runtime.mode(for: capabilities) == .legacyJSON)
    }

    @Test
    func modeResolutionReturnsPrivateCoreWhenBufferCapabilitiesAreMissing() {
        let runtime = WISPIRuntime.shared
        let capabilities = WISPICapabilities(
            hasContentWorldConfiguration: true,
            hasJSHandleClass: true,
            hasSerializedNodeClass: true,
            hasJSBufferClass: false,
            hasWorldWithConfigurationSelector: true,
            hasPublicAddBufferSelector: false,
            hasPublicRemoveBufferSelector: false,
            hasPrivateAddBufferSelector: false,
            hasPrivateRemoveBufferSelector: false
        )

        #expect(runtime.mode(for: capabilities) == .privateCore)
    }

    @Test
    func modeResolutionReturnsPrivateFullWhenAllCapabilitiesExist() {
        let runtime = WISPIRuntime.shared
        let capabilities = WISPICapabilities(
            hasContentWorldConfiguration: true,
            hasJSHandleClass: true,
            hasSerializedNodeClass: true,
            hasJSBufferClass: true,
            hasWorldWithConfigurationSelector: true,
            hasPublicAddBufferSelector: true,
            hasPublicRemoveBufferSelector: true,
            hasPrivateAddBufferSelector: false,
            hasPrivateRemoveBufferSelector: false
        )

        #expect(runtime.mode(for: capabilities) == .privateFull)
    }

    @Test
    func modeResolutionPreservesModeOrderingAcrossCapabilityCombinations() {
        let runtime = WISPIRuntime.shared
        let cases: [(WISPICapabilities, WIBridgeMode)] = [
            (
                WISPICapabilities(
                    hasContentWorldConfiguration: true,
                    hasJSHandleClass: true,
                    hasSerializedNodeClass: true,
                    hasJSBufferClass: true,
                    hasWorldWithConfigurationSelector: true,
                    hasPublicAddBufferSelector: true,
                    hasPublicRemoveBufferSelector: true,
                    hasPrivateAddBufferSelector: false,
                    hasPrivateRemoveBufferSelector: false
                ),
                .privateFull
            ),
            (
                WISPICapabilities(
                    hasContentWorldConfiguration: true,
                    hasJSHandleClass: true,
                    hasSerializedNodeClass: true,
                    hasJSBufferClass: true,
                    hasWorldWithConfigurationSelector: true,
                    hasPublicAddBufferSelector: false,
                    hasPublicRemoveBufferSelector: false,
                    hasPrivateAddBufferSelector: true,
                    hasPrivateRemoveBufferSelector: true
                ),
                .privateFull
            ),
            (
                WISPICapabilities(
                    hasContentWorldConfiguration: true,
                    hasJSHandleClass: true,
                    hasSerializedNodeClass: true,
                    hasJSBufferClass: false,
                    hasWorldWithConfigurationSelector: true,
                    hasPublicAddBufferSelector: true,
                    hasPublicRemoveBufferSelector: true,
                    hasPrivateAddBufferSelector: false,
                    hasPrivateRemoveBufferSelector: false
                ),
                .privateCore
            ),
            (
                WISPICapabilities(
                    hasContentWorldConfiguration: false,
                    hasJSHandleClass: true,
                    hasSerializedNodeClass: true,
                    hasJSBufferClass: true,
                    hasWorldWithConfigurationSelector: true,
                    hasPublicAddBufferSelector: true,
                    hasPublicRemoveBufferSelector: true,
                    hasPrivateAddBufferSelector: true,
                    hasPrivateRemoveBufferSelector: true
                ),
                .legacyJSON
            ),
        ]

        for (capabilities, expected) in cases {
            #expect(runtime.mode(for: capabilities) == expected)
        }
    }
}
