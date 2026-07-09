import Foundation
import WebKit
import WebInspectorNativeBridgeObjC

public enum NativeInspectorSymbolResolutionError: Error, Equatable, Sendable {
    case missingSymbols([String])
}

public struct NativeInspectorResolvedSymbols: Equatable, Sendable {
    var connectFrontendAddress: UInt64
    var disconnectFrontendAddress: UInt64
    var stringFromUTF8Address: UInt64
    var stringImplToNSStringAddress: UInt64
    var destroyStringImplAddress: UInt64
    var backendDispatcherDispatchAddress: UInt64

    init(
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

    public static func resolveCurrent() throws -> NativeInspectorResolvedSymbols {
        try makeResolvedSymbols(from: NativeInspectorSymbolResolver.resolveCurrent())
    }

    public static func resolveCurrentDetached() async throws -> NativeInspectorResolvedSymbols {
        let resolution = await NativeInspectorSymbolResolver.resolveCurrentDetached()
        return try makeResolvedSymbols(from: resolution)
    }

    private static func makeResolvedSymbols(
        from resolution: NativeInspectorSymbolResolution
    ) throws -> NativeInspectorResolvedSymbols {
        guard resolution.isSupported else {
            throw NativeInspectorSymbolResolutionError.missingSymbols(resolution.missingFunctions)
        }

        return NativeInspectorResolvedSymbols(
            connectFrontendAddress: resolution.connectFrontendAddress,
            disconnectFrontendAddress: resolution.disconnectFrontendAddress,
            stringFromUTF8Address: resolution.stringFromUTF8Address,
            stringImplToNSStringAddress: resolution.stringImplToNSStringAddress,
            destroyStringImplAddress: resolution.destroyStringImplAddress,
            backendDispatcherDispatchAddress: resolution.backendDispatcherDispatchAddress
        )
    }
}

@MainActor
public final class NativeInspectorBridge {
    public var messageHandler: ((String) -> Void)? {
        didSet {
            objcBridge.messageHandler = messageHandler.map { handler in
                { message in handler(message) }
            }
        }
    }
    public var fatalFailureHandler: ((String) -> Void)? {
        didSet {
            objcBridge.fatalFailureHandler = fatalFailureHandler.map { handler in
                { message in handler(message) }
            }
        }
    }

    private let objcBridge: WebInspectorNativeBridgeObjC.WebInspectorNativeBridge

    public init(webView: WKWebView) {
        objcBridge = WebInspectorNativeBridgeObjC.WebInspectorNativeBridge(webView: webView)
    }

    public func attach(with resolvedSymbols: NativeInspectorResolvedSymbols) throws {
        try objcBridge.attach(with: resolvedSymbols.objcSymbols)
    }

    public func sendJSONString(_ message: String) throws {
        try objcBridge.sendJSONString(message)
    }

    public func detach() {
        objcBridge.detach()
    }

    func handleFrontendMessageForTesting(_ message: String) {
        WebInspectorNativeDeliverFrontendMessageForTesting(objcBridge, message)
    }
}

struct NativeInspectorControllerDiscoveryTestResult: Equatable, Sendable {
    var found: Bool
    var usedFallbackRange: Bool
    var resolvedOffset: Int
    var attemptedOffsetCount: Int
    var validCandidateCount: Int
    var scannedByteCount: Int

    init(_ result: WebInspectorNativeControllerDiscoveryTestResult) {
        found = result.found.boolValue
        usedFallbackRange = result.usedFallbackRange.boolValue
        resolvedOffset = result.resolvedOffset
        attemptedOffsetCount = Int(result.attemptedOffsetCount)
        validCandidateCount = Int(result.validCandidateCount)
        scannedByteCount = Int(result.scannedByteCount)
    }
}

enum NativeInspectorBridgeTesting {
    static func runControllerDiscoveryScenario(
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

    static func runControllerDiscoveryScenarioWithInvalidCandidates(
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
