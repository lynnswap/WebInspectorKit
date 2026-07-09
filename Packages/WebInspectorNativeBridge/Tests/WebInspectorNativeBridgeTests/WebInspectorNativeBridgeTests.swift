#if os(iOS) || os(macOS)
import Testing
import WebKit
@testable import WebInspectorNativeBridge

struct WebInspectorNativeBridgeTests {
    @Test
    func cachedOffsetResolvesImmediately() {
        let result = NativeInspectorBridgeTesting.runControllerDiscoveryScenario(
            pageAllocationSize: 0x1000,
            cachedOffset: 0x580,
            primaryControllerOffset: 0x580,
            secondaryControllerOffset: -1
        )

        #expect(result.found)
        #expect(result.resolvedOffset == 0x580)
        #expect(result.attemptedOffsetCount == 1)
        #expect(result.validCandidateCount == 1)
        #expect(result.usedFallbackRange == false)
    }

    @Test
    func fullScanFindsUniqueControllerWhenKnownOffsetsMiss() {
        let result = NativeInspectorBridgeTesting.runControllerDiscoveryScenario(
            pageAllocationSize: 0x1000,
            cachedOffset: -1,
            primaryControllerOffset: 0x540,
            secondaryControllerOffset: -1
        )

        #expect(result.found)
        #expect(result.resolvedOffset == 0x540)
        #expect(result.validCandidateCount == 1)
        #expect(result.attemptedOffsetCount > 9)
        #expect(result.scannedByteCount == 0x1000)
    }

    @Test
    func multipleCandidatesFailResolution() {
        let result = NativeInspectorBridgeTesting.runControllerDiscoveryScenario(
            pageAllocationSize: 0x1000,
            cachedOffset: -1,
            primaryControllerOffset: 0x540,
            secondaryControllerOffset: 0x5A0
        )

        #expect(result.found == false)
        #expect(result.resolvedOffset == -1)
        #expect(result.validCandidateCount == 2)
    }

    @Test
    func invalidControllerShapeCandidatesDoNotBlockResolution() {
        let result = NativeInspectorBridgeTesting.runControllerDiscoveryScenarioWithInvalidCandidates(
            pageAllocationSize: 0x1000,
            cachedOffset: -1,
            primaryControllerOffset: 0x540,
            invalidControllerOffset: 0x580,
            secondaryInvalidControllerOffset: 0x5A0
        )

        #expect(result.found)
        #expect(result.resolvedOffset == 0x540)
        #expect(result.validCandidateCount == 1)
    }

    @Test
    func invalidCachedOffsetFallsBackToValidController() {
        let result = NativeInspectorBridgeTesting.runControllerDiscoveryScenarioWithInvalidCandidates(
            pageAllocationSize: 0x1000,
            cachedOffset: 0x580,
            primaryControllerOffset: 0x540,
            invalidControllerOffset: 0x580,
            secondaryInvalidControllerOffset: -1
        )

        #expect(result.found)
        #expect(result.resolvedOffset == 0x540)
        #expect(result.validCandidateCount == 1)
    }

    @Test
    func zeroAllocationSizeUsesFallbackRange() {
        let result = NativeInspectorBridgeTesting.runControllerDiscoveryScenario(
            pageAllocationSize: 0,
            cachedOffset: -1,
            primaryControllerOffset: 0x540,
            secondaryControllerOffset: -1
        )

        #expect(result.found)
        #expect(result.resolvedOffset == 0x540)
        #expect(result.usedFallbackRange)
        #expect(result.scannedByteCount == 0x1000)
    }

    @MainActor
    @Test
    func rawFrontendMessageIsDeliveredOnceWithoutTargetDemux() {
        let bridge = NativeInspectorBridge(webView: WKWebView(frame: .zero))
        var deliveredMessages: [String] = []
        bridge.messageHandler = { message in
            deliveredMessages.append(message)
        }

        let rawMessage = #"{"method":"Target.dispatchMessageFromTarget","params":{"targetId":"frame-A","message":"{\"method\":\"DOM.documentUpdated\",\"params\":{}}"}}"#
        bridge.handleFrontendMessageForTesting(rawMessage)

        #expect(deliveredMessages == [rawMessage])
    }
}
#endif
