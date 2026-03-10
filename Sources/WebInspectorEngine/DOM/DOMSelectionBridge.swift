import Foundation
import WebInspectorBridge
import WebInspectorScripts
import WebKit

@MainActor
protocol DOMSelectionBridging: AnyObject {
    func installIfNeeded(on webView: WKWebView) async throws
    func beginSelection(on webView: WKWebView) async throws -> DOMSelectionModeResult
    func cancelSelection(on webView: WKWebView) async
    func resolveSelectedNodeID(on webView: WKWebView, maxDepth: Int) async throws -> Int?
}

@MainActor
final class DOMSelectionBridge: DOMSelectionBridging {
    private let runtime: WISPIRuntime
    private let controllerStateRegistry: WIUserContentControllerStateRegistry
    private let bridgeWorld: WKContentWorld

    init(
        runtime: WISPIRuntime = .shared,
        controllerStateRegistry: WIUserContentControllerStateRegistry = .shared
    ) {
        self.runtime = runtime
        self.controllerStateRegistry = controllerStateRegistry
        bridgeWorld = WISPIContentWorldProvider.bridgeWorld(runtime: runtime)
    }

    func installIfNeeded(on webView: WKWebView) async throws {
        let controller = webView.configuration.userContentController
        let scriptSource = try WebInspectorScripts.domAgent()

        if controllerStateRegistry.domBridgeScriptInstalled(on: controller) == false {
            controller.addUserScript(
                WKUserScript(
                    source: scriptSource,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true,
                    in: bridgeWorld
                )
            )
            controllerStateRegistry.setDOMBridgeScriptInstalled(true, on: controller)
        }

        _ = try await webView.evaluateJavaScript(
            scriptSource,
            in: nil,
            contentWorld: bridgeWorld
        )
    }

    func beginSelection(on webView: WKWebView) async throws -> DOMSelectionModeResult {
        let rawResult = try await webView.callAsyncJavaScript(
            "return window.webInspectorDOM.startSelection()",
            arguments: [:],
            in: nil,
            contentWorld: bridgeWorld
        )
        let data = try serializePayload(rawResult)
        return try JSONDecoder().decode(DOMSelectionModeResult.self, from: data)
    }

    func cancelSelection(on webView: WKWebView) async {
        try? await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM.cancelSelection()",
            contentWorld: bridgeWorld
        )
    }

    func resolveSelectedNodeID(on webView: WKWebView, maxDepth: Int) async throws -> Int? {
        let rawResult = try await webView.callAsyncJavaScript(
            """
            const maxSnapshotDepth = Math.max(1, maxDepth);
            if (!window.webInspectorDOM || typeof window.webInspectorDOM.captureSnapshotEnvelope !== "function") {
                return null;
            }
            const snapshot = window.webInspectorDOM.captureSnapshotEnvelope(maxSnapshotDepth);
            return typeof snapshot?.selectedNodeId === "number" ? snapshot.selectedNodeId : null;
            """,
            arguments: ["maxDepth": max(1, maxDepth)],
            in: nil,
            contentWorld: bridgeWorld
        )

        if let value = rawResult as? Int {
            return value
        }
        if let value = rawResult as? NSNumber {
            return value.intValue
        }
        return nil
    }
}

private extension DOMSelectionBridge {
    func serializePayload(_ payload: Any?) throws -> Data {
        guard let payload else {
            throw WebInspectorCoreError.scriptUnavailable
        }

        if let string = payload as? String {
            return Data(string.utf8)
        }
        if let dictionary = payload as? NSDictionary {
            guard JSONSerialization.isValidJSONObject(dictionary) else {
                throw WebInspectorCoreError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: dictionary)
        }
        if let array = payload as? NSArray {
            guard JSONSerialization.isValidJSONObject(array) else {
                throw WebInspectorCoreError.serializationFailed
            }
            return try JSONSerialization.data(withJSONObject: array)
        }

        throw WebInspectorCoreError.serializationFailed
    }
}
