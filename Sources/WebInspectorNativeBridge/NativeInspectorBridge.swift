import Foundation
import WebKit
import WebInspectorNativeBridgeObjC

package typealias NativeInspectorBridgeError = WebInspectorNativeBridgeObjC.WebInspectorNativeBridgeError

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
    package var webContentProcessTerminationHandler: (() -> Void)? {
        didSet {
            objcBridge.webContentProcessTerminationHandler = webContentProcessTerminationHandler
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

    func handleFrontendMessageForTesting(_ message: String) {
        WebInspectorNativeDeliverFrontendMessageForTesting(objcBridge, message)
    }
}
