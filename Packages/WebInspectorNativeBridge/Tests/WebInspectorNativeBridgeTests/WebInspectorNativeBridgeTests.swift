#if os(iOS) || os(macOS)
import Testing
import WebKit
import WebInspectorNativeBridgeObjC
@testable import WebInspectorNativeBridge

struct WebInspectorNativeBridgeTests {
    @Test(arguments: [0, 0x580, 0x1300])
    func findsTargetAtAnyOffset(_ offset: Int) {
        let result = WebInspectorNativeRunTargetDiscoveryForTesting(0x1800, -1, offset, -1, false)
        #expect(result.found.boolValue)
        #expect(result.offset == offset)
    }

    @Test
    func invalidCachedOffsetFallsBackToTargetDiscovery() {
        let result = WebInspectorNativeRunTargetDiscoveryForTesting(0x1000, 0x10000, 0x580, -1, false)
        #expect(result.found.boolValue)
        #expect(result.offset == 0x580)
    }

    @Test
    func differentTargetsAreAmbiguousButAliasesAreNot() {
        let different = WebInspectorNativeRunTargetDiscoveryForTesting(0x1000, -1, 0x580, 0x600, false)
        #expect(!different.found.boolValue)
        #expect(different.matches == 2)
        let aliases = WebInspectorNativeRunTargetDiscoveryForTesting(0x1000, -1, 0x580, 0x600, true)
        #expect(aliases.found.boolValue)
        #expect(aliases.matches == 1)
    }

    @Test(arguments: [0, 7, 0x1000])
    func missingTargetsAreUnavailable(_ bytes: Int) {
        let result = WebInspectorNativeRunTargetDiscoveryForTesting(UInt(bytes), -1, -1, -1, false)
        #expect(!result.found.boolValue)
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
