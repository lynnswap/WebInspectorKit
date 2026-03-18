#if os(iOS) || os(macOS)
import Testing
@testable import WebInspectorTransport

struct WITransportBridgeControllerDiscoveryTests {
    @Test
    func cachedOffsetResolvesImmediately() {
        let result = WITransportBridgeControllerDiscovery.runScenario(
            pageAllocationSize: 0x1000,
            cachedOffset: 0x580,
            primaryControllerOffset: 0x580
        )

        #expect(result.found)
        #expect(result.resolvedOffset == 0x580)
        #expect(result.attemptedOffsetCount == 1)
        #expect(result.validCandidateCount == 1)
        #expect(result.usedFallbackRange == false)
    }

    @Test
    func fullScanFindsUniqueControllerWhenKnownOffsetsMiss() {
        let result = WITransportBridgeControllerDiscovery.runScenario(
            pageAllocationSize: 0x1000,
            primaryControllerOffset: 0x540
        )

        #expect(result.found)
        #expect(result.resolvedOffset == 0x540)
        #expect(result.validCandidateCount == 1)
        #expect(result.attemptedOffsetCount > 9)
        #expect(result.scannedByteCount == 0x1000)
    }

    @Test
    func multipleCandidatesFailResolution() {
        let result = WITransportBridgeControllerDiscovery.runScenario(
            pageAllocationSize: 0x1000,
            primaryControllerOffset: 0x540,
            secondaryControllerOffset: 0x5A0
        )

        #expect(result.found == false)
        #expect(result.resolvedOffset == nil)
        #expect(result.validCandidateCount == 2)
    }

    @Test
    func zeroAllocationSizeUsesFallbackRange() {
        let result = WITransportBridgeControllerDiscovery.runScenario(
            pageAllocationSize: 0,
            primaryControllerOffset: 0x540
        )

        #expect(result.found)
        #expect(result.resolvedOffset == 0x540)
        #expect(result.usedFallbackRange)
        #expect(result.scannedByteCount == 0x1000)
    }
}
#endif
