#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import WebInspectorTransport

@MainActor
struct WITransportMacRemoteInspectorPlatformBackendTests {
    @Test
    func backendMirrorsIncomingRootMessagesIntoRemoteFrontendHost() async throws {
        let endpoint = FakeMessageEndpoint()
        let host = FakeFrontendHost()
        let backend = WITransportMacRemoteInspectorPlatformBackend(
            configuration: .init(),
            transportEndpoint: endpoint,
            frontendHost: host
        )
        let webView = WKWebView(frame: .zero)
        let window = makeHostWindow(with: webView)
        defer {
            window.orderOut(nil)
            window.close()
        }

        var receivedRootMessages: [String] = []
        try await backend.attach(
            to: webView,
            messageHandlers: WITransportBackendMessageHandlers(
                handleRootMessage: { message in
                    receivedRootMessages.append(message)
                },
                handlePageMessage: { _, _ in },
                handleFatalFailure: { _ in }
            )
        )
        defer {
            backend.detach()
        }

        let rootMessage = #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#
        endpoint.emitRoot(rootMessage)

        #expect(receivedRootMessages == [rootMessage])
        #expect(host.mirroredBackendMessages == [rootMessage])
        #expect(host.attachCallCount == 1)
    }

    @Test
    func backendMirrorsBootstrapRootMessagesEmittedDuringEndpointAttach() async throws {
        let bootstrapRootMessage = #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-bootstrap","type":"page","isProvisional":false}}}"#
        let endpoint = FakeMessageEndpoint(rootMessagesToEmitDuringAttach: [bootstrapRootMessage])
        let host = FakeFrontendHost()
        let backend = WITransportMacRemoteInspectorPlatformBackend(
            configuration: .init(),
            transportEndpoint: endpoint,
            frontendHost: host
        )
        let webView = WKWebView(frame: .zero)
        let window = makeHostWindow(with: webView)
        defer {
            window.orderOut(nil)
            window.close()
        }

        var receivedRootMessages: [String] = []

        try await backend.attach(
            to: webView,
            messageHandlers: WITransportBackendMessageHandlers(
                handleRootMessage: { message in
                    receivedRootMessages.append(message)
                },
                handlePageMessage: { _, _ in },
                handleFatalFailure: { _ in }
            )
        )

        #expect(receivedRootMessages == [bootstrapRootMessage])
        #expect(host.mirroredBackendMessages == [bootstrapRootMessage])
    }

    @Test
    func backendSendsCommandsOnlyThroughNativeEndpointHotPath() async throws {
        let endpoint = FakeMessageEndpoint()
        let host = FakeFrontendHost()
        let backend = WITransportMacRemoteInspectorPlatformBackend(
            configuration: .init(),
            transportEndpoint: endpoint,
            frontendHost: host
        )
        let webView = WKWebView(frame: .zero)
        let window = makeHostWindow(with: webView)
        defer {
            window.orderOut(nil)
            window.close()
        }

        try await backend.attach(
            to: webView,
            messageHandlers: WITransportBackendMessageHandlers(
                handleRootMessage: { _ in },
                handlePageMessage: { _, _ in },
                handleFatalFailure: { _ in }
            )
        )
        defer {
            backend.detach()
        }

        try backend.sendRootMessage("root-command")
        try backend.sendPageMessage("page-command", targetIdentifier: "page-A", outerIdentifier: 42)

        #expect(endpoint.sentRootMessages == ["root-command"])
        #expect(endpoint.sentPageMessages == [.init(message: "page-command", targetIdentifier: "page-A", outerIdentifier: 42)])
        #expect(host.mirroredBackendMessages.isEmpty)
    }

    @Test
    func backendSupportSnapshotAdvertisesRemoteFrontendHosting() {
        let endpoint = FakeMessageEndpoint()
        let host = FakeFrontendHost()
        let backend = WITransportMacRemoteInspectorPlatformBackend(
            configuration: .init(),
            transportEndpoint: endpoint,
            frontendHost: host
        )

        #expect(backend.supportSnapshot.backendKind == .macOSRemoteInspector)
        #expect(backend.supportSnapshot.capabilities.contains(.remoteFrontendHosting))
        #expect(backend.supportSnapshot.capabilities.contains(.domDomain))
        #expect(backend.supportSnapshot.isSupported)
    }

    @Test
    func backendReportsFrontendHostFatalFailures() async throws {
        let endpoint = FakeMessageEndpoint()
        let host = FakeFrontendHost()
        let backend = WITransportMacRemoteInspectorPlatformBackend(
            configuration: .init(),
            transportEndpoint: endpoint,
            frontendHost: host
        )
        let webView = WKWebView(frame: .zero)
        let window = makeHostWindow(with: webView)
        defer {
            window.orderOut(nil)
            window.close()
        }
        var fatalFailures: [String] = []

        try await backend.attach(
            to: webView,
            messageHandlers: WITransportBackendMessageHandlers(
                handleRootMessage: { _ in },
                handlePageMessage: { _, _ in },
                handleFatalFailure: { message in
                    fatalFailures.append(message)
                }
            )
        )

        host.emitFatalFailure("frontend closed")

        #expect(fatalFailures == ["frontend closed"])
        #expect(endpoint.detachCallCount == 1)
    }

    @Test
    func backendRoutesFrontendHostCommandsThroughNativeEndpoint() async throws {
        let endpoint = FakeMessageEndpoint()
        let host = FakeFrontendHost()
        let backend = WITransportMacRemoteInspectorPlatformBackend(
            configuration: .init(),
            transportEndpoint: endpoint,
            frontendHost: host
        )
        let webView = WKWebView(frame: .zero)
        let window = makeHostWindow(with: webView)
        defer {
            window.orderOut(nil)
            window.close()
        }

        try await backend.attach(
            to: webView,
            messageHandlers: WITransportBackendMessageHandlers(
                handleRootMessage: { _ in },
                handlePageMessage: { _, _ in },
                handleFatalFailure: { _ in }
            )
        )

        host.emitBackendMessage(#"{"id":7,"method":"Target.sendMessageToTarget","params":{"targetId":"page-A","message":"{}"}}"#)

        #expect(endpoint.sentRootMessages == [#"{"id":7,"method":"Target.sendMessageToTarget","params":{"targetId":"page-A","message":"{}"}}"#])
    }

    @Test
    func backendBuffersFrontendCommandsUntilNativeEndpointAttaches() async throws {
        let earlyCommand = #"{"id":3,"method":"Target.sendMessageToTarget","params":{"targetId":"page-A","message":"{}"}}"#
        let endpoint = FakeMessageEndpoint()
        let host = FakeFrontendHost(backendMessagesToEmitDuringAttach: [earlyCommand])
        let backend = WITransportMacRemoteInspectorPlatformBackend(
            configuration: .init(),
            transportEndpoint: endpoint,
            frontendHost: host
        )
        let webView = WKWebView(frame: .zero)
        let window = makeHostWindow(with: webView)
        defer {
            window.orderOut(nil)
            window.close()
        }

        try await backend.attach(
            to: webView,
            messageHandlers: WITransportBackendMessageHandlers(
                handleRootMessage: { _ in },
                handlePageMessage: { _, _ in },
                handleFatalFailure: { _ in }
            )
        )

        #expect(endpoint.sentRootMessages == [earlyCommand])
    }

    @Test
    func backendFallsBackToTransportOnlyWhenWKWebViewIsOffWindow() async throws {
        let endpoint = FakeMessageEndpoint()
        let host = FakeFrontendHost()
        let backend = WITransportMacRemoteInspectorPlatformBackend(
            configuration: .init(),
            transportEndpoint: endpoint,
            frontendHost: host
        )
        let webView = WKWebView(frame: .zero)

        try await backend.attach(
            to: webView,
            messageHandlers: WITransportBackendMessageHandlers(
                handleRootMessage: { _ in },
                handlePageMessage: { _, _ in },
                handleFatalFailure: { _ in }
            )
        )

        #expect(host.attachCallCount == 0)
        #expect(backend.supportSnapshot.backendKind == .macOSNativeInspector)
        #expect(!backend.supportSnapshot.capabilities.contains(.remoteFrontendHosting))
    }

    @Test
    func backendFallsBackToTransportOnlyWhenFrontendHostAttachFails() async throws {
        let endpoint = FakeMessageEndpoint()
        let host = FakeFrontendHost(attachError: WITransportError.attachFailed("host attach failed"))
        let backend = WITransportMacRemoteInspectorPlatformBackend(
            configuration: .init(),
            transportEndpoint: endpoint,
            frontendHost: host
        )
        let webView = WKWebView(frame: .zero)
        let window = makeHostWindow(with: webView)
        defer {
            window.orderOut(nil)
            window.close()
        }

        try await backend.attach(
            to: webView,
            messageHandlers: WITransportBackendMessageHandlers(
                handleRootMessage: { _ in },
                handlePageMessage: { _, _ in },
                handleFatalFailure: { _ in }
            )
        )

        #expect(host.attachCallCount == 1)
        #expect(backend.supportSnapshot.backendKind == .macOSNativeInspector)
        #expect(!backend.supportSnapshot.capabilities.contains(.remoteFrontendHosting))
    }
}

@MainActor
private extension WITransportMacRemoteInspectorPlatformBackendTests {
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
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = containerView
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

@MainActor
private final class FakeMessageEndpoint: WITransportMessageEndpoint {
    struct SentPageMessage: Equatable {
        let message: String
        let targetIdentifier: String
        let outerIdentifier: Int
    }

    let supportSnapshot: WITransportSupportSnapshot
    private(set) var sentRootMessages: [String] = []
    private(set) var sentPageMessages: [SentPageMessage] = []
    private(set) var detachCallCount = 0
    private var messageHandlers: WITransportBackendMessageHandlers?
    private let rootMessagesToEmitDuringAttach: [String]

    init(
        supportSnapshot: WITransportSupportSnapshot = WITransportSupportSnapshot(
            availability: .supported,
            backendKind: .macOSNativeInspector,
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain],
            failureReason: nil
        ),
        rootMessagesToEmitDuringAttach: [String] = []
    ) {
        self.supportSnapshot = supportSnapshot
        self.rootMessagesToEmitDuringAttach = rootMessagesToEmitDuringAttach
    }

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) throws {
        _ = webView
        self.messageHandlers = messageHandlers
        for message in rootMessagesToEmitDuringAttach {
            messageHandlers.handleRootMessage(message)
        }
    }

    func detach() {
        detachCallCount += 1
        messageHandlers = nil
    }

    func sendRootMessage(_ message: String) throws {
        sentRootMessages.append(message)
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        sentPageMessages.append(.init(message: message, targetIdentifier: targetIdentifier, outerIdentifier: outerIdentifier))
    }

    func emitRoot(_ message: String) {
        messageHandlers?.handleRootMessage(message)
    }
}

@MainActor
private final class FakeFrontendHost: WITransportFrontendHost {
    let supportSnapshot: WITransportSupportSnapshot
    private(set) var mirroredBackendMessages: [String] = []
    private(set) var attachCallCount = 0
    private var backendMessageHandler: ((String) -> Void)?
    private var fatalFailureHandler: ((String) -> Void)?
    private let backendMessagesToEmitDuringAttach: [String]
    private let attachError: Error?

    init(
        supportSnapshot: WITransportSupportSnapshot = WITransportSupportSnapshot(
            availability: .supported,
            backendKind: .macOSRemoteInspector,
            capabilities: [.remoteFrontendHosting],
            failureReason: nil
        ),
        backendMessagesToEmitDuringAttach: [String] = [],
        attachError: Error? = nil
    ) {
        self.supportSnapshot = supportSnapshot
        self.backendMessagesToEmitDuringAttach = backendMessagesToEmitDuringAttach
        self.attachError = attachError
    }

    func attach(
        to webView: WKWebView,
        backendMessageHandler: @escaping (String) -> Void,
        fatalFailureHandler: @escaping (String) -> Void
    ) async throws {
        _ = webView
        attachCallCount += 1
        if let attachError {
            throw attachError
        }
        self.backendMessageHandler = backendMessageHandler
        self.fatalFailureHandler = fatalFailureHandler
        for message in backendMessagesToEmitDuringAttach {
            backendMessageHandler(message)
        }
    }

    func mirrorBackendMessage(_ message: String) {
        mirroredBackendMessages.append(message)
    }

    func detach() {
        backendMessageHandler = nil
        fatalFailureHandler = nil
    }

    func emitBackendMessage(_ message: String) {
        backendMessageHandler?(message)
    }

    func emitFatalFailure(_ message: String) {
        fatalFailureHandler?(message)
    }
}
#endif
