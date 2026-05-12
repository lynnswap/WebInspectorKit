#if os(macOS)
import AppKit
import Foundation
import WebKit
import XCTest
import WebInspectorTestSupport
@testable import WebInspectorTransport

@MainActor
final class WITransportSessionMacOSTests: XCTestCase {
    func testSessionReportsUnsupportedOnMacOS() async throws {
        try await withWebKitTestIsolation {
            let hostedWebView = makeIsolatedTestWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
            let window = makeHostWindow(with: hostedWebView)
            hostedWebView.isInspectable = true
            defer {
                window.orderOut(nil)
                window.close()
            }

            let session = WITransportSession(
                configuration: .init(
                    responseTimeout: .seconds(15),
                    eventBufferLimit: 64,
                    dropEventsWithoutSubscribers: true
                )
            )

            do {
                try await session.attach(to: hostedWebView)
                XCTFail("Expected macOS transport to be unsupported")
            } catch let error as WITransportError {
                guard case .unsupported(let reason) = error else {
                    XCTFail("Expected WITransportError.unsupported, got \(error)")
                    return
                }
                XCTAssertEqual(reason, "WebInspectorTransport currently supports iOS only.")
            }
            XCTAssertFalse(session.supportSnapshot.isSupported)
        }
    }
}

@MainActor
private extension WITransportSessionMacOSTests {
    func codec() -> WITransportCodec {
        WITransportCodec.shared
    }

    func domEnable(using session: WITransportSession) async throws {
        _ = try await session.sendPageData(method: WITransportMethod.DOM.enable)
    }

    func domGetDocument(
        using session: WITransportSession,
        depth: Int? = nil,
        pierce: Bool? = nil
    ) async throws -> DOMGetDocumentResponse {
        let parametersData = try await codec().encode(
            DOMGetDocumentParameters(depth: depth, pierce: pierce)
        )
        return try await codec().decode(
            DOMGetDocumentResponse.self,
            from: try await session.sendPageData(
                method: WITransportMethod.DOM.getDocument,
                parametersData: parametersData
            )
        )
    }

    func domGetOuterHTML(
        using session: WITransportSession,
        nodeID: Int? = nil
    ) async throws -> DOMGetOuterHTMLResponse {
        let parametersData = try await codec().encode(
            DOMGetOuterHTMLParameters(nodeId: nodeID)
        )
        return try await codec().decode(
            DOMGetOuterHTMLResponse.self,
            from: try await session.sendPageData(
                method: WITransportMethod.DOM.getOuterHTML,
                parametersData: parametersData
            )
        )
    }

    func loadHTML(_ html: String, in webView: WKWebView) async throws {
        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate

        try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://example.com/"))
        }
    }

    func makeHostWindow(with webView: WKWebView) -> NSWindow {
        let containerView = NSView(frame: webView.frame)
        webView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: containerView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = containerView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

}

private struct DOMGetDocumentParameters: Encodable, Sendable {
    let depth: Int?
    let pierce: Bool?
}

private struct DOMGetDocumentResponse: Decodable, Sendable {
    let root: WITransportDOMNode
}

private struct DOMGetOuterHTMLParameters: Encodable, Sendable {
    let nodeId: Int?
}

private struct DOMGetOuterHTMLResponse: Decodable, Sendable {
    let outerHTML: String
}

@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resumeIfNeeded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        resumeIfNeeded(throwing: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        resumeIfNeeded(throwing: error)
    }

    func resumeIfNeeded() {
        continuation?.resume()
        continuation = nil
    }

    func resumeIfNeeded(throwing error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
#endif
