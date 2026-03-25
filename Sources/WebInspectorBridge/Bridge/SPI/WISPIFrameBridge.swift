import Foundation
import WebKit
import WebInspectorBridgeObjCShim

@MainActor
package enum WISPIFrameBridge {
    package static func frameInfos(for webView: WKWebView) async -> [WKFrameInfo]? {
        await withCheckedContinuation { continuation in
            WIKRuntimeBridge.frameInfos(for: webView) { frameInfos in
                continuation.resume(returning: frameInfos)
            }
        }
    }

    package static func frameID(for frameInfo: WKFrameInfo) -> UInt64? {
        WIKRuntimeBridge.frameID(for: frameInfo)?.uint64Value
    }
}
