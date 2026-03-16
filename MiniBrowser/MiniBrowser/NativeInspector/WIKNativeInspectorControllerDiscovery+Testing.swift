#if DEBUG
import Foundation

struct WIKNativeInspectorControllerDiscoveryResult: Sendable {
    let found: Bool
    let usedFallbackRange: Bool
    let resolvedOffset: Int?
    let attemptedOffsetCount: Int
    let validCandidateCount: Int
    let scannedByteCount: Int
}

enum WIKNativeInspectorControllerDiscovery {
    private static func makeResult(
        _ rawResult: WIKNativeInspectorControllerDiscoveryTestResult
    ) -> WIKNativeInspectorControllerDiscoveryResult {
        WIKNativeInspectorControllerDiscoveryResult(
            found: rawResult.found.boolValue,
            usedFallbackRange: rawResult.usedFallbackRange.boolValue,
            resolvedOffset: rawResult.resolvedOffset >= 0 ? Int(rawResult.resolvedOffset) : nil,
            attemptedOffsetCount: Int(rawResult.attemptedOffsetCount),
            validCandidateCount: Int(rawResult.validCandidateCount),
            scannedByteCount: Int(rawResult.scannedByteCount)
        )
    }

    static func runScenario(
        pageAllocationSize: Int,
        cachedOffset: Int? = nil,
        primaryControllerOffset: Int,
        secondaryControllerOffset: Int = -1
    ) -> WIKNativeInspectorControllerDiscoveryResult {
        let rawResult = WIKNativeInspectorRunControllerDiscoveryScenarioForTesting(
            numericCast(pageAllocationSize),
            numericCast(cachedOffset ?? -1),
            numericCast(primaryControllerOffset),
            numericCast(secondaryControllerOffset)
        )
        return makeResult(rawResult)
    }
}
#endif
