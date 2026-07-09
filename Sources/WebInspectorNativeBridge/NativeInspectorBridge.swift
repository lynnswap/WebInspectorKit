import Foundation
import WebKit
import WebInspectorNativeBridgeObjC

package struct NativeInspectorResolvedSymbols: Equatable, Sendable {
    package var connectFrontendAddress: UInt64
    package var disconnectFrontendAddress: UInt64
    package var stringFromUTF8Address: UInt64
    package var stringImplToNSStringAddress: UInt64
    package var destroyStringImplAddress: UInt64
    package var backendDispatcherDispatchAddress: UInt64

    package init(
        connectFrontendAddress: UInt64,
        disconnectFrontendAddress: UInt64,
        stringFromUTF8Address: UInt64,
        stringImplToNSStringAddress: UInt64,
        destroyStringImplAddress: UInt64,
        backendDispatcherDispatchAddress: UInt64
    ) {
        self.connectFrontendAddress = connectFrontendAddress
        self.disconnectFrontendAddress = disconnectFrontendAddress
        self.stringFromUTF8Address = stringFromUTF8Address
        self.stringImplToNSStringAddress = stringImplToNSStringAddress
        self.destroyStringImplAddress = destroyStringImplAddress
        self.backendDispatcherDispatchAddress = backendDispatcherDispatchAddress
    }

    var objcSymbols: WebInspectorNativeResolvedSymbols {
        WebInspectorNativeResolvedSymbols(
            connectFrontendAddress: connectFrontendAddress,
            disconnectFrontendAddress: disconnectFrontendAddress,
            stringFromUTF8Address: stringFromUTF8Address,
            stringImplToNSStringAddress: stringImplToNSStringAddress,
            destroyStringImplAddress: destroyStringImplAddress,
            backendDispatcherDispatchAddress: backendDispatcherDispatchAddress
        )
    }
}

@MainActor
package final class NativeInspectorBridge {
    package var messageHandler: ((String) -> Void)? {
        didSet {
            objcBridge.messageHandler = messageHandler.map { handler in
                { message in handler(message) }
            }
        }
    }
    package var fatalFailureHandler: ((String) -> Void)? {
        didSet {
            objcBridge.fatalFailureHandler = fatalFailureHandler.map { handler in
                { message in handler(message) }
            }
        }
    }

    private let objcBridge: WebInspectorNativeBridgeObjC.WebInspectorNativeBridge

    package init(webView: WKWebView) {
        objcBridge = WebInspectorNativeBridgeObjC.WebInspectorNativeBridge(webView: webView)
    }

    package func attach(with resolvedSymbols: NativeInspectorResolvedSymbols) throws {
        try objcBridge.attach(with: resolvedSymbols.objcSymbols)
    }

    package func sendJSONString(_ message: String) throws {
        try objcBridge.sendJSONString(message)
    }

    package func detach() {
        objcBridge.detach()
    }

    package func handleFrontendMessageForTesting(_ message: String) {
        _ = unsafe objcBridge.perform(NSSelectorFromString("handleFrontendMessageString:"), with: message)
    }
}

package struct NativeInspectorControllerDiscoveryTestResult: Equatable, Sendable {
    package var found: Bool
    package var usedFallbackRange: Bool
    package var resolvedOffset: Int
    package var attemptedOffsetCount: Int
    package var validCandidateCount: Int
    package var scannedByteCount: Int

    init(_ result: WebInspectorNativeControllerDiscoveryTestResult) {
        found = result.found.boolValue
        usedFallbackRange = result.usedFallbackRange.boolValue
        resolvedOffset = result.resolvedOffset
        attemptedOffsetCount = Int(result.attemptedOffsetCount)
        validCandidateCount = Int(result.validCandidateCount)
        scannedByteCount = Int(result.scannedByteCount)
    }
}

package enum NativeInspectorBridgeTesting {
    package static func runControllerDiscoveryScenario(
        pageAllocationSize: Int,
        cachedOffset: Int,
        primaryControllerOffset: Int,
        secondaryControllerOffset: Int
    ) -> NativeInspectorControllerDiscoveryTestResult {
        NativeInspectorControllerDiscoveryTestResult(
            WebInspectorNativeRunControllerDiscoveryScenarioForTesting(
                UInt(pageAllocationSize),
                cachedOffset,
                primaryControllerOffset,
                secondaryControllerOffset
            )
        )
    }

    package static func runControllerDiscoveryScenarioWithInvalidCandidates(
        pageAllocationSize: Int,
        cachedOffset: Int,
        primaryControllerOffset: Int,
        invalidControllerOffset: Int,
        secondaryInvalidControllerOffset: Int
    ) -> NativeInspectorControllerDiscoveryTestResult {
        NativeInspectorControllerDiscoveryTestResult(
            WebInspectorNativeRunControllerDiscoveryScenarioWithInvalidCandidatesForTesting(
                UInt(pageAllocationSize),
                cachedOffset,
                primaryControllerOffset,
                invalidControllerOffset,
                secondaryInvalidControllerOffset
            )
        )
    }
}
