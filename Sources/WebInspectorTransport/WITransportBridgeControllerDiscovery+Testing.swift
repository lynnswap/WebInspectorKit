#if os(iOS) || os(macOS)
import Foundation
@unsafe @preconcurrency import WebInspectorTransportObjCShim

package struct WITransportBridgeControllerDiscoveryResult: Sendable {
    package let found: Bool
    package let usedFallbackRange: Bool
    package let resolvedOffset: Int?
    package let attemptedOffsetCount: Int
    package let validCandidateCount: Int
    package let scannedByteCount: Int
}

package enum WITransportBridgeControllerDiscovery {
    private static func makeResult(
        _ rawResult: WITransportControllerDiscoveryTestResult
    ) -> WITransportBridgeControllerDiscoveryResult {
        let resolvedOffset = rawResult.resolvedOffset >= 0 ? Int(rawResult.resolvedOffset) : nil
        return WITransportBridgeControllerDiscoveryResult(
            found: rawResult.found.boolValue,
            usedFallbackRange: rawResult.usedFallbackRange.boolValue,
            resolvedOffset: resolvedOffset,
            attemptedOffsetCount: Int(rawResult.attemptedOffsetCount),
            validCandidateCount: Int(rawResult.validCandidateCount),
            scannedByteCount: Int(rawResult.scannedByteCount)
        )
    }

    package static func discover(
        page: UnsafeRawPointer,
        pageAllocationSize: Int,
        cachedOffset: Int? = nil
    ) -> WITransportBridgeControllerDiscoveryResult {
        let rawResult = unsafe WITransportFindInspectorControllerForTesting(
            page,
            UInt(max(0, pageAllocationSize)),
            cachedOffset ?? -1
        )
        return makeResult(rawResult)
    }

    package static func runScenario(
        pageAllocationSize: Int,
        cachedOffset: Int? = nil,
        primaryControllerOffset: Int,
        secondaryControllerOffset: Int? = nil
    ) -> WITransportBridgeControllerDiscoveryResult {
        let rawResult = WITransportRunControllerDiscoveryScenarioForTesting(
            UInt(max(0, pageAllocationSize)),
            cachedOffset ?? -1,
            primaryControllerOffset,
            secondaryControllerOffset ?? -1
        )
        return makeResult(rawResult)
    }
}
#endif
