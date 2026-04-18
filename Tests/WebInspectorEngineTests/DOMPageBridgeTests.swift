import Foundation
import Testing
import WebKit
import WebInspectorTestSupport
@testable import WebInspectorEngine

@MainActor
struct DOMPageBridgeTests {
    @Test
    func installOrUpdateBootstrapAppliesContextID() async throws {
        let bridge = DOMPageBridge(configuration: .init(snapshotDepth: 4, subtreeDepth: 3))
        let webView = makeIsolatedTestWebView()

        await bridge.installOrUpdateBootstrap(
            on: webView,
            contextID: 7,
            autoSnapshotEnabled: false
        )
        try await loadHTML("<html><body><div id='target'></div></body></html>", in: webView)

        let context = await bridge.readContext(on: webView)
        #expect(context?.contextID == 7)
    }

    @Test
    func setAttributeFailsWhenExpectedContextIsStale() async throws {
        let bridge = DOMPageBridge(configuration: .init(snapshotDepth: 4, subtreeDepth: 3))
        let webView = makeIsolatedTestWebView()

        await bridge.installOrUpdateBootstrap(
            on: webView,
            contextID: 3,
            autoSnapshotEnabled: false
        )
        try await loadHTML("<html><body><div id='target'></div></body></html>", in: webView)

        let targetNodeID = try #require(try await nodeID(forElementID: "target", using: bridge))
        let result = await bridge.setAttribute(
            target: .local(UInt64(targetNodeID)),
            name: "class",
            value: "after",
            expectedContextID: 999
        )

        switch result {
        case .contextInvalidated:
            break
        default:
            Issue.record("expected contextInvalidated for stale mutation")
        }
    }

    @Test
    func setAttributeAppliesWhenExpectedContextMatches() async throws {
        let bridge = DOMPageBridge(configuration: .init(snapshotDepth: 4, subtreeDepth: 3))
        let webView = makeIsolatedTestWebView()

        await bridge.installOrUpdateBootstrap(
            on: webView,
            contextID: 11,
            autoSnapshotEnabled: false
        )
        try await loadHTML("<html><body><div id='target'></div></body></html>", in: webView)

        let targetNodeID = try #require(try await nodeID(forElementID: "target", using: bridge))
        let result = await bridge.setAttribute(
            target: .local(UInt64(targetNodeID)),
            name: "class",
            value: "after",
            expectedContextID: 11
        )

        guard case .applied = result else {
            Issue.record("expected applied mutation result")
            return
        }
        let className = try await webView.callAsyncJavaScriptCompat(
            "return document.getElementById('target')?.getAttribute('class') ?? null",
            arguments: [:],
            in: nil,
            contentWorld: .page
        ) as? String
        #expect(className == "after")
    }
}

@MainActor
private extension DOMPageBridgeTests {
    func loadHTML(_ html: String, in webView: WKWebView) async throws {
        let delegate = HTMLLoadDelegate()
        webView.navigationDelegate = delegate
        let delegateObject = delegate
        defer {
            webView.navigationDelegate = nil
            _ = delegateObject
        }
        try await withCheckedThrowingContinuation { continuation in
            delegate.didFinish = {
                continuation.resume(returning: ())
            }
            delegate.didFail = { error in
                continuation.resume(throwing: error)
            }
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com"))
        }
    }

    func nodeID(forElementID elementID: String, using bridge: DOMPageBridge) async throws -> Int? {
        let payload = try await bridge.captureSnapshotEnvelope(maxDepth: 8)
        guard let root = snapshotRoot(from: payload) else {
            return nil
        }
        return findNodeID(withElementID: elementID, in: root)
    }

    func snapshotRoot(from payload: Any) -> [String: Any]? {
        if let root = payload as? [String: Any] {
            if let directRoot = root["root"] as? [String: Any] {
                return directRoot
            }
            if let fallback = root["fallback"] as? [String: Any],
               let fallbackRoot = fallback["root"] as? [String: Any] {
                return fallbackRoot
            }
            if root["nodeType"] != nil {
                return root
            }
        }
        if let dictionary = payload as? NSDictionary as? [String: Any],
           let directRoot = dictionary["root"] as? [String: Any] {
            return directRoot
        }
        if let dictionary = payload as? NSDictionary as? [String: Any],
           let fallback = dictionary["fallback"] as? [String: Any],
           let fallbackRoot = fallback["root"] as? [String: Any] {
            return fallbackRoot
        }
        return nil
    }

    func findNodeID(withElementID elementID: String, in node: [String: Any]) -> Int? {
        if let attributes = node["attributes"] as? [Any] {
            var index = 0
            while index + 1 < attributes.count {
                let name = attributes[index] as? String
                let value = attributes[index + 1] as? String
                if name == "id", value == elementID {
                    return (node["nodeId"] as? Int) ?? (node["id"] as? Int)
                }
                index += 2
            }
        }
        guard let children = node["children"] as? [[String: Any]] else {
            return nil
        }
        for child in children {
            if let match = findNodeID(withElementID: elementID, in: child) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private final class HTMLLoadDelegate: NSObject, WKNavigationDelegate {
    var didFinish: (() -> Void)?
    var didFail: ((Error) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        didFinish?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        didFail?(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        didFail?(error)
    }
}
