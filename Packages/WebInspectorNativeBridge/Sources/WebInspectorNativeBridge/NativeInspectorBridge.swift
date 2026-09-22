import Foundation
import WebKit
import WebInspectorNativeBridgeObjC

package typealias NativeInspectorBridgeError = WebInspectorNativeBridgeObjC.WebInspectorNativeBridgeError

public enum NativeInspectorSymbolResolutionError: Error, Equatable, Sendable {
    case missingSymbols([String])
}

public struct NativeInspectorResolvedSymbols: Equatable, Sendable {
    var connectFrontendAddress: UInt64
    var disconnectFrontendAddress: UInt64
    var stringFromUTF8Address: UInt64
    var stringImplToNSStringAddress: UInt64
    var derefStringImplAddress: UInt64
    var dispatchMessageFromRemoteAddress: UInt64
    var debuggableVTableAddress: UInt64

    init(
        connectFrontendAddress: UInt64,
        disconnectFrontendAddress: UInt64,
        stringFromUTF8Address: UInt64,
        stringImplToNSStringAddress: UInt64,
        derefStringImplAddress: UInt64,
        dispatchMessageFromRemoteAddress: UInt64,
        debuggableVTableAddress: UInt64
    ) {
        self.connectFrontendAddress = connectFrontendAddress
        self.disconnectFrontendAddress = disconnectFrontendAddress
        self.stringFromUTF8Address = stringFromUTF8Address
        self.stringImplToNSStringAddress = stringImplToNSStringAddress
        self.derefStringImplAddress = derefStringImplAddress
        self.dispatchMessageFromRemoteAddress = dispatchMessageFromRemoteAddress
        self.debuggableVTableAddress = debuggableVTableAddress
    }

    var objcSymbols: WebInspectorNativeResolvedSymbols {
        WebInspectorNativeResolvedSymbols(
            connectFrontendAddress: connectFrontendAddress,
            disconnectFrontendAddress: disconnectFrontendAddress,
            stringFromUTF8Address: stringFromUTF8Address,
            stringImplToNSStringAddress: stringImplToNSStringAddress,
            derefStringImplAddress: derefStringImplAddress,
            dispatchMessageFromRemoteAddress: dispatchMessageFromRemoteAddress,
            debuggableVTableAddress: debuggableVTableAddress
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
            derefStringImplAddress: resolution.derefStringImplAddress,
            dispatchMessageFromRemoteAddress: resolution.dispatchMessageFromRemoteAddress,
            debuggableVTableAddress: resolution.debuggableVTableAddress
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
    public var webContentProcessTerminationHandler: (() -> Void)? {
        didSet {
            objcBridge.webContentProcessTerminationHandler = webContentProcessTerminationHandler
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
