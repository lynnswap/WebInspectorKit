#if os(iOS) || os(macOS)
import Testing
import WebKit
import WebInspectorNativeBridge

struct WebInspectorNativeBridgeTests {
    @Test
    func cachedOffsetResolvesImmediately() {
        let result = WebInspectorNativeRunControllerDiscoveryScenarioForTesting(
            0x1000,
            0x580,
            0x580,
            -1
        )

        #expect(result.found.boolValue)
        #expect(result.resolvedOffset == 0x580)
        #expect(result.attemptedOffsetCount == 1)
        #expect(result.validCandidateCount == 1)
        #expect(result.usedFallbackRange.boolValue == false)
    }

    @Test
    func fullScanFindsUniqueControllerWhenKnownOffsetsMiss() {
        let result = WebInspectorNativeRunControllerDiscoveryScenarioForTesting(
            0x1000,
            -1,
            0x540,
            -1
        )

        #expect(result.found.boolValue)
        #expect(result.resolvedOffset == 0x540)
        #expect(result.validCandidateCount == 1)
        #expect(result.attemptedOffsetCount > 9)
        #expect(result.scannedByteCount == 0x1000)
    }

    @Test
    func multipleCandidatesFailResolution() {
        let result = WebInspectorNativeRunControllerDiscoveryScenarioForTesting(
            0x1000,
            -1,
            0x540,
            0x5A0
        )

        #expect(result.found.boolValue == false)
        #expect(result.resolvedOffset == -1)
        #expect(result.validCandidateCount == 2)
    }

    @Test
    func zeroAllocationSizeUsesFallbackRange() {
        let result = WebInspectorNativeRunControllerDiscoveryScenarioForTesting(
            0,
            -1,
            0x540,
            -1
        )

        #expect(result.found.boolValue)
        #expect(result.resolvedOffset == 0x540)
        #expect(result.usedFallbackRange.boolValue)
        #expect(result.scannedByteCount == 0x1000)
    }

    @MainActor
    @Test
    func rawFrontendMessageIsDeliveredOnceWithoutTargetDemux() {
        let bridge = WebInspectorNativeBridge(webView: WKWebView(frame: .zero))
        var deliveredMessages: [String] = []
        bridge.messageHandler = { message in
            deliveredMessages.append(message)
        }

        let rawMessage = #"{"method":"Target.dispatchMessageFromTarget","params":{"targetId":"frame-A","message":"{\"method\":\"DOM.documentUpdated\",\"params\":{}}"}}"#
        _ = unsafe bridge.perform(NSSelectorFromString("handleFrontendMessageString:"), with: rawMessage)

        #expect(deliveredMessages == [rawMessage])
    }
}
#endif
