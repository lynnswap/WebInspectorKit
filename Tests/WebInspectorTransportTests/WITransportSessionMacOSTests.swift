#if os(macOS)
import AppKit
import Foundation
import WebKit
import XCTest
@testable import WebInspectorTransport

@MainActor
final class WITransportSessionMacOSTests: XCTestCase {
    func testSessionAttachesToHostedWKWebViewAndReadsDOM() async throws {
        let hostedWebView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = makeHostWindow(with: hostedWebView)
        hostedWebView.isInspectable = true
        try await loadHTML("<html><body><p id='greeting'>Hello transport</p></body></html>", in: hostedWebView)
        let baselineVisibleWindowIdentifiers = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))

        let session = WITransportSession(
            configuration: .init(
                responseTimeout: .seconds(15),
                eventBufferLimit: 64,
                dropEventsWithoutSubscribers: true
            )
        )
        var didCleanup = false

        try await session.attach(to: hostedWebView)
        defer {
            if !didCleanup {
                session.detach()
                window.orderOut(nil)
                window.close()
            }
        }

        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(
            Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)),
            baselineVisibleWindowIdentifiers
        )
        XCTAssertTrue(session.supportSnapshot.isSupported)
        if session.supportSnapshot.backendKind == .macOSRemoteInspector {
            XCTAssertTrue(session.supportSnapshot.capabilities.contains(.remoteFrontendHosting))
        } else {
            XCTAssertEqual(session.supportSnapshot.backendKind, .macOSNativeInspector)
            XCTAssertFalse(session.supportSnapshot.capabilities.contains(.remoteFrontendHosting))
        }

        _ = try await session.page.send(WITransportCommands.DOM.Enable())
        let document = try await session.page.send(WITransportCommands.DOM.GetDocument(depth: 4))
        let outerHTMLNodeID = document.root.children?.first?.nodeId ?? document.root.nodeId
        let outerHTML = try await session.page.send(
            WITransportCommands.DOM.GetOuterHTML(nodeId: outerHTMLNodeID)
        )

        XCTAssertEqual(document.root.nodeName, "#document")
        XCTAssertTrue(outerHTML.outerHTML.contains("Hello transport"))

        session.detach()
        window.orderOut(nil)
        window.close()
        try await settleUI()
        didCleanup = true
    }
}

@MainActor
private extension WITransportSessionMacOSTests {
    func loadHTML(_ html: String, in webView: WKWebView) async throws {
        let delegate = NavigationDelegate()
        webView.navigationDelegate = delegate
        let timeoutError = WITransportError.attachFailed(
            "Timed out while waiting for WKWebView navigation to finish in macOS transport tests."
        )
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            delegate.resumeIfNeeded(throwing: timeoutError)
        }
        defer {
            timeoutTask.cancel()
        }

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

    func settleUI() async throws {
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
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
