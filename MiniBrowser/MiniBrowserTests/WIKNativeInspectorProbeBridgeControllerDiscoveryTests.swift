#if os(iOS) && DEBUG
import XCTest
@testable import MiniBrowser

final class WIKNativeInspectorProbeBridgeControllerDiscoveryTests: XCTestCase {
    func testCachedOffsetResolvesImmediately() {
        let result = WIKNativeInspectorControllerDiscovery.runScenario(
            pageAllocationSize: 0x1000,
            cachedOffset: 0x580,
            primaryControllerOffset: 0x580
        )

        XCTAssertTrue(result.found)
        XCTAssertEqual(result.resolvedOffset, 0x580)
        XCTAssertEqual(result.attemptedOffsetCount, 1)
        XCTAssertEqual(result.validCandidateCount, 1)
        XCTAssertFalse(result.usedFallbackRange)
    }

    func testFullScanFindsUniqueControllerWhenKnownOffsetsMiss() {
        let result = WIKNativeInspectorControllerDiscovery.runScenario(
            pageAllocationSize: 0x1000,
            primaryControllerOffset: 0x540
        )

        XCTAssertTrue(result.found)
        XCTAssertEqual(result.resolvedOffset, 0x540)
        XCTAssertEqual(result.validCandidateCount, 1)
        XCTAssertGreaterThan(result.attemptedOffsetCount, 9)
        XCTAssertEqual(result.scannedByteCount, 0x1000)
    }

    func testMultipleCandidatesFailResolution() {
        let result = WIKNativeInspectorControllerDiscovery.runScenario(
            pageAllocationSize: 0x1000,
            primaryControllerOffset: 0x540,
            secondaryControllerOffset: 0x5A0
        )

        XCTAssertFalse(result.found)
        XCTAssertNil(result.resolvedOffset)
        XCTAssertEqual(result.validCandidateCount, 2)
    }

    func testZeroAllocationSizeUsesFallbackRange() {
        let result = WIKNativeInspectorControllerDiscovery.runScenario(
            pageAllocationSize: 0,
            primaryControllerOffset: 0x540
        )

        XCTAssertTrue(result.found)
        XCTAssertEqual(result.resolvedOffset, 0x540)
        XCTAssertTrue(result.usedFallbackRange)
        XCTAssertEqual(result.scannedByteCount, 0x1000)
    }
}
#endif
