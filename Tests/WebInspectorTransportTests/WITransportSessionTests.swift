import Foundation
import Testing
import WebKit
@testable import WebInspectorTransport

@MainActor
struct WITransportSessionTests {
    @Test
    func macOSDefaultBackendSelectorFallsBackToNativeWhenRemoteHostIsUnavailable() {
        let remoteBackend = FakeSessionBackend(
            supportSnapshot: WITransportSupportSnapshot(
                availability: .unsupported,
                backendKind: .macOSRemoteInspector,
                capabilities: [],
                failureReason: "remote host unavailable"
            )
        )
        let nativeBackend = FakeSessionBackend(
            supportSnapshot: WITransportSupportSnapshot(
                availability: .supported,
                backendKind: .macOSNativeInspector,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain],
                failureReason: nil
            )
        )

        let selectedBackend = WITransportMacDefaultBackendSelector.selectDefaultBackend(
            remoteBackend: remoteBackend,
            nativeBackend: nativeBackend
        )

        #expect(selectedBackend as AnyObject === nativeBackend)
    }

    @Test
    func macOSDefaultBackendSelectorPrefersRemoteHostWhenSupported() {
        let remoteBackend = FakeSessionBackend(
            supportSnapshot: WITransportSupportSnapshot(
                availability: .supported,
                backendKind: .macOSRemoteInspector,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .remoteFrontendHosting],
                failureReason: nil
            )
        )
        let nativeBackend = FakeSessionBackend(
            supportSnapshot: WITransportSupportSnapshot(
                availability: .supported,
                backendKind: .macOSNativeInspector,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain],
                failureReason: nil
            )
        )

        let selectedBackend = WITransportMacDefaultBackendSelector.selectDefaultBackend(
            remoteBackend: remoteBackend,
            nativeBackend: nativeBackend
        )

        #expect(selectedBackend as AnyObject === remoteBackend)
    }

    @Test
    func fatalBackendFailureDetachesSessionAndClosesTransport() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = WKWebView(frame: .zero)

        try await session.attach(to: webView)
        #expect(session.state == .attached)

        backend.emitFatalFailure("backend died")
        try await Task.sleep(for: .milliseconds(50))

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
            supportSnapshot: WITransportSupportSnapshot(
                availability: .supported,
                backendKind: .macOSRemoteInspector,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .remoteFrontendHosting],
                failureReason: nil
            ),
            supportSnapshotAfterAttach: WITransportSupportSnapshot(
                availability: .supported,
                backendKind: .macOSNativeInspector,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain],
                failureReason: nil
            )
        )
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = WKWebView(frame: .zero)

        try await session.attach(to: webView)

        #expect(session.supportSnapshot.backendKind == .macOSNativeInspector)
        #expect(!session.supportSnapshot.capabilities.contains(.remoteFrontendHosting))
    }
}

@MainActor
private final class FakeSessionBackend: WITransportPlatformBackend {
    var supportSnapshot: WITransportSupportSnapshot

    private var messageHandlers: WITransportBackendMessageHandlers?
    private let supportSnapshotAfterAttach: WITransportSupportSnapshot?

    init(
        supportSnapshot: WITransportSupportSnapshot = WITransportSupportSnapshot(
            availability: .supported,
            backendKind: .unsupported,
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain],
            failureReason: nil
        ),
        supportSnapshotAfterAttach: WITransportSupportSnapshot? = nil
    ) {
        self.supportSnapshot = supportSnapshot
        self.supportSnapshotAfterAttach = supportSnapshotAfterAttach
    }

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) async throws {
        _ = webView
        self.messageHandlers = messageHandlers
        if let supportSnapshotAfterAttach {
            supportSnapshot = supportSnapshotAfterAttach
        }
        messageHandlers.handleRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#
        )
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
    }

    func compatibilityResponse(scope: WITransportTargetScope, method: String) -> Data? {
        _ = scope
        _ = method
        return nil
    }

    func emitFatalFailure(_ message: String) {
        messageHandlers?.handleFatalFailure(message)
    }
}
