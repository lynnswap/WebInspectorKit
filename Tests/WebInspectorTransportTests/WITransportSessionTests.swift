import Foundation
import Testing
import WebInspectorTestSupport
import WebKit
@testable import WebInspectorTransport

@MainActor
@Suite(.serialized, .webKitIsolated)
struct WITransportSessionTests {
    @Test
    func macOSDefaultBackendFactoryUsesNativeInspectorBackend() {
        #if os(macOS)
        let backend = WITransportPlatformBackendFactory.makeDefaultBackend(configuration: .init())
        #expect(backend is WITransportMacNativeInspectorPlatformBackend)
        #endif
    }

    @Test
    func fatalBackendFailureDetachesSessionAndClosesTransport() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let detached = AsyncGate()
        session.onStateTransitionForTesting = { state in
            guard state == .detached else {
                return
            }
            Task {
                await detached.open()
            }
        }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)
        #expect(session.state == .attached)

        backend.emitFatalFailure("backend died")
        await detached.wait()

        #expect(session.state == .detached)

        do {
            _ = try await session.page.send(WITransportCommands.DOM.GetDocument(depth: 1))
            Issue.record("Expected transport to reject commands after a fatal backend failure")
        } catch let error as WITransportError {
            guard case .notAttached = error else {
                Issue.record("Expected WITransportError.notAttached, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected WITransportError.notAttached, got \(error)")
        }
    }

    @Test
    func attachRefreshesSupportSnapshotFromResolvedBackendMode() async throws {
        let backend = FakeSessionBackend(
            supportSnapshot: .supported(
                backendKind: .macOSNativeInspector,
                capabilities: [.rootMessaging],
                failureReason: "preflight snapshot"
            ),
            supportSnapshotAfterAttach: .supported(
                backendKind: .macOSNativeInspector,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain]
            )
        )
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        #expect(session.supportSnapshot.backendKind == .macOSNativeInspector)
        #expect(session.supportSnapshot.capabilities.contains(.domDomain))
        #expect(session.supportSnapshot.capabilities.contains(.networkDomain))
        #expect(session.supportSnapshot.failureReason == nil)
    }

    @Test
    func compatibilityResponseAllowsDOMEnableWithoutSendingPageMessage() async throws {
        let backend = FakeSessionBackend(
            supportSnapshot: .supported(
                backendKind: .iOSNativeInspector,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain]
            ),
            compatibilityResponseProvider: { scope, method in
                guard scope == .page, method == WITransportCommands.DOM.Enable.method else {
                    return nil
                }
                return .object([:])
            }
        )
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)
        _ = try await session.page.send(WITransportCommands.DOM.Enable())

        #expect(backend.sentPageMessageCount == 0)
    }

    @Test
    func compatibilityResponseAllowsCSSEnableWithoutSendingPageMessage() async throws {
        let backend = FakeSessionBackend(
            supportSnapshot: .supported(
                backendKind: .iOSNativeInspector,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain]
            ),
            compatibilityResponseProvider: { scope, method in
                guard scope == .page, method == TestCSSEnable.method else {
                    return nil
                }
                return .object([:])
            }
        )
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)
        _ = try await session.page.send(TestCSSEnable())

        #expect(backend.sentPageMessageCount == 0)
    }

    @Test
    func pageGetResourceTreeDecodesFrameTreePayload() async throws {
        let backend = FakeSessionBackend(
            compatibilityResponseProvider: { scope, method in
                guard scope == .page, method == WITransportCommands.Page.GetResourceTree.method else {
                    return nil
                }
                return .object([
                    "frameTree": [
                        "frame": [
                            "id": "frame-main",
                            "loaderId": "loader-main",
                            "url": "https://example.com/",
                            "securityOrigin": "https://example.com",
                            "mimeType": "text/html",
                        ],
                        "resources": [
                            [
                                "url": "https://example.com/app.js",
                                "type": "Script",
                                "mimeType": "text/javascript",
                            ],
                        ],
                    ],
                ])
            }
        )
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)
        let response = try await session.page.send(WITransportCommands.Page.GetResourceTree())

        #expect(response.frameTree.frame.id == "frame-main")
        #expect(response.frameTree.frame.url == "https://example.com/")
        #expect(response.frameTree.resources.count == 1)
        #expect(response.frameTree.resources.first?.type == .script)
        #expect(response.frameTree.resources.first?.mimeType == "text/javascript")
        #expect(backend.sentPageMessageCount == 0)
    }

    @Test
    func pageGetResourceTreeFallsBackUnknownResourceTypesToOther() async throws {
        let backend = FakeSessionBackend(
            compatibilityResponseProvider: { scope, method in
                guard scope == .page, method == WITransportCommands.Page.GetResourceTree.method else {
                    return nil
                }
                return .object([
                    "frameTree": [
                        "frame": [
                            "id": "frame-main",
                            "loaderId": "loader-main",
                            "url": "https://example.com/",
                            "securityOrigin": "https://example.com",
                            "mimeType": "text/html",
                        ],
                        "resources": [
                            [
                                "url": "https://example.com/unknown.bin",
                                "type": "Preload",
                                "mimeType": "application/octet-stream",
                            ],
                        ],
                    ],
                ])
            }
        )
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)
        let response = try await session.page.send(WITransportCommands.Page.GetResourceTree())

        #expect(response.frameTree.resources.count == 1)
        #expect(response.frameTree.resources.first?.type == .other)
        #expect(response.frameTree.resources.first?.mimeType == "application/octet-stream")
    }

    @Test
    func supportedSnapshotFactoryPreservesBackendCapabilitiesAndFailureReason() {
        let snapshot = WITransportSupportSnapshot.supported(
            backendKind: .iOSNativeInspector,
            capabilities: [.rootMessaging, .domDomain],
            failureReason: "preflight snapshot"
        )

        #expect(snapshot.availability == .supported)
        #expect(snapshot.backendKind == .iOSNativeInspector)
        #expect(snapshot.capabilities == [.rootMessaging, .domDomain])
        #expect(snapshot.failureReason == "preflight snapshot")
    }

    @Test
    func unsupportedSnapshotFactoryClearsCapabilitiesAndUsesUnsupportedBackendKind() {
        let snapshot = WITransportSupportSnapshot.unsupported(reason: "backend unavailable")

        #expect(snapshot.availability == .unsupported)
        #expect(snapshot.backendKind == .unsupported)
        #expect(snapshot.capabilities.isEmpty)
        #expect(snapshot.failureReason == "backend unavailable")
    }
}

private struct TestCSSEnable: WITransportPageCommand, Sendable {
    typealias Response = WIEmptyTransportResponse
    let parameters = WIEmptyTransportParameters()

    static let method = "CSS.enable"
}

@MainActor
private final class FakeSessionBackend: WITransportPlatformBackend {
    var supportSnapshot: WITransportSupportSnapshot

    private var messageHandlers: WITransportBackendMessageHandlers?
    private let supportSnapshotAfterAttach: WITransportSupportSnapshot?
    private let compatibilityResponseProvider: ((WITransportTargetScope, String) -> WITransportPayload?)?
    private(set) var sentPageMessageCount = 0

    init(
        supportSnapshot: WITransportSupportSnapshot? = nil,
        supportSnapshotAfterAttach: WITransportSupportSnapshot? = nil,
        compatibilityResponseProvider: ((WITransportTargetScope, String) -> WITransportPayload?)? = nil
    ) {
        self.supportSnapshot = supportSnapshot ?? .supported(
            backendKind: Self.defaultSupportedBackendKind,
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain]
        )
        self.supportSnapshotAfterAttach = supportSnapshotAfterAttach
        self.compatibilityResponseProvider = compatibilityResponseProvider
    }

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) async throws {
        _ = webView
        self.messageHandlers = messageHandlers
        if let supportSnapshotAfterAttach {
            supportSnapshot = supportSnapshotAfterAttach
        }
        messageHandlers.handleRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#,
            [
                "method": "Target.targetCreated",
                "params": [
                    "targetInfo": [
                        "targetId": "page-A",
                        "type": "page",
                        "isProvisional": false,
                    ],
                ],
            ]
        )
        messageHandlers.waitForPendingMessagesForTesting?()
    }

    func detach() {
        messageHandlers = nil
    }

    func sendRootMessage(_ message: String) throws {
        _ = message
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        _ = message
        _ = targetIdentifier
        _ = outerIdentifier
        sentPageMessageCount += 1
    }

    func compatibilityResponse(scope: WITransportTargetScope, method: String) -> WITransportPayload? {
        compatibilityResponseProvider?(scope, method)
    }

    func emitFatalFailure(_ message: String) {
        messageHandlers?.handleFatalFailure(message)
    }

    private static var defaultSupportedBackendKind: WITransportBackendKind {
#if os(macOS)
        .macOSNativeInspector
#else
        .iOSNativeInspector
#endif
    }
}
