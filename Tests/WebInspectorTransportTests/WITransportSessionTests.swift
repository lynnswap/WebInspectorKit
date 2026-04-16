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
            _ = try await Self.domGetDocument(using: session, depth: 1)
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
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .consoleDomain]
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
        #expect(session.supportSnapshot.capabilities.contains(.consoleDomain))
        #expect(session.supportSnapshot.failureReason == nil)
    }

    @Test
    func attachCompletesBeforePageTargetBecomesAvailable() async throws {
        let backend = FakeSessionBackend(attachHandler: { _ in })
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        #expect(session.state == .attached)
        #expect(session.currentPageTargetIdentifier() == nil)
    }

    @Test
    func inspectabilityRemainsEnabledUntilLastSessionDetaches() async throws {
        guard #available(iOS 16.4, macOS 13.3, *) else {
            return
        }

        let firstBackend = FakeSessionBackend()
        let secondBackend = FakeSessionBackend()
        let firstSession = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in firstBackend }
        )
        let secondSession = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in secondBackend }
        )
        let webView = makeIsolatedTestWebView()
        webView.isInspectable = false

        try await firstSession.attach(to: webView)
        #expect(webView.isInspectable)

        try await secondSession.attach(to: webView)
        #expect(webView.isInspectable)

        firstSession.detach()
        #expect(webView.isInspectable)

        secondSession.detach()
    }

    @Test
    func waitForPageTargetReturnsTargetThatSurvivesTransientChurn() async throws {
        let backend = FakeSessionBackend(attachHandler: { messageSink in
            Task { @MainActor in
                messageSink.didReceiveRootMessage(
                    #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#
                )
                messageSink.didReceiveRootMessage(
                    #"{"method":"Target.targetDestroyed","params":{"targetId":"page-A"}}"#
                )
            }
            Task { @MainActor in
                await Task.yield()
                messageSink.didReceiveRootMessage(
                    #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-B","type":"page","isProvisional":false}}}"#
                )
            }
        })
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let targetIdentifier = try await session.waitForPageTarget()

        #expect(session.state == .attached)
        #expect(targetIdentifier == "page-B")
        #expect(session.currentPageTargetIdentifier() == "page-B")
    }

    @Test
    func pageCommandWaitsForInitialPageTargetWhenNeeded() async throws {
        let backend = FakeSessionBackend(attachHandler: { messageSink in
            Task { @MainActor in
                await Task.yield()
                messageSink.didReceiveRootMessage(
                    #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-late","type":"page","isProvisional":false}}}"#
                )
            }
        })
        backend.onSendPageMessage = { message, targetIdentifier, outerIdentifier in
            let identifier = try Self.identifier(from: message)
            #expect(identifier == outerIdentifier)
            #expect(targetIdentifier == "page-late")
            backend.emitPageMessage(
                Self.jsonString([
                    "id": identifier,
                    "result": [
                        "frameTree": [
                            "frame": [
                                "id": "frame-late",
                                "loaderId": "loader-late",
                                "url": "https://example.com/late",
                                "securityOrigin": "https://example.com",
                                "mimeType": "text/html",
                            ],
                            "resources": [],
                        ],
                    ],
                ]),
                targetIdentifier: targetIdentifier
            )
        }

        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let response = try await Self.pageGetResourceTree(using: session)

        #expect(response.frameTree.frame.id == "frame-late")
        #expect(session.currentPageTargetIdentifier() == "page-late")
    }

    @Test
    func waitForPageTargetTimesOutWithoutTargets() async throws {
        let clock = TestClock()
        let backend = FakeSessionBackend(attachHandler: { _ in })
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(5)),
            backendFactory: { _ in backend },
            clock: clock
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let waitTask = Task { @MainActor in
            try await session.waitForPageTarget(timeout: .seconds(2))
        }
        await clock.sleep(untilSuspendedBy: 1)
        clock.advance(by: .seconds(2))

        do {
            _ = try await waitTask.value
            Issue.record("Expected waitForPageTarget() to time out without page targets")
        } catch let error as WITransportError {
            guard case .requestTimedOut(scope: .root, method: "Target.targetCreated") = error else {
                Issue.record("Expected a root target timeout, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected WITransportError.requestTimedOut, got \(error)")
        }
    }

    @Test
    func compatibilityResponseAllowsDOMEnableWithoutSendingPageMessage() async throws {
        let backend = FakeSessionBackend(
            supportSnapshot: .supported(
                backendKind: .iOSNativeInspector,
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain]
            ),
            compatibilityResponseProvider: { scope, method in
                guard scope == .page, method == WITransportMethod.DOM.enable else {
                    return nil
                }
                return Data("{}".utf8)
            }
        )
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)
        try await Self.domEnable(using: session)

        #expect(backend.sentPageMessageCount == 0)
    }

    @Test
    func concurrentRootCommandsAreCorrelated() async throws {
        let backend = FakeSessionBackend()
        backend.onSendRootMessage = { message in
            let identifier = try Self.identifier(from: message)
            let method = try Self.method(from: message)
            backend.emitRootMessage(
                Self.jsonString([
                    "id": identifier,
                    "result": ["method": method],
                ])
            )
        }
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        async let firstData: Void = Self.targetEnable(using: session)
        async let secondData = Self.browserGetVersion(using: session)

        try await firstData
        let second = try await secondData

        #expect(second.method == WITransportMethod.Browser.getVersion)
    }

    @Test
    func pageCommandsFollowCommittedTargetWithoutOldIdentifier() async throws {
        let backend = FakeSessionBackend()
        let recorder = PageDispatchRecorder()
        backend.onSendPageMessage = { message, targetIdentifier, outerIdentifier in
            await recorder.record(targetIdentifier: targetIdentifier)
            let identifier = try Self.identifier(from: message)
            #expect(identifier == outerIdentifier)
            backend.emitRootMessage(
                Self.jsonString([
                    "id": outerIdentifier,
                    "result": [:],
                ])
            )
            backend.emitPageMessage(
                Self.jsonString([
                    "id": identifier,
                    "result": [
                        "frameTree": [
                            "frame": [
                                "id": "frame-\(targetIdentifier)",
                                "loaderId": "loader-\(targetIdentifier)",
                                "url": "https://example.com/\(targetIdentifier)",
                                "securityOrigin": "https://example.com",
                                "mimeType": "text/html",
                            ],
                            "resources": [],
                        ],
                    ],
                ]),
                targetIdentifier: targetIdentifier
            )
        }
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"newTargetId":"page-C"}}"#
        )
        await backend.waitForPendingMessages()

        _ = try await Self.pageGetResourceTree(using: session)

        #expect(await recorder.snapshot() == ["page-C"])
    }

    @Test
    func pageGetResourceTreeDecodesFrameTreePayload() async throws {
        let backend = FakeSessionBackend(
            compatibilityResponseProvider: { scope, method in
                guard scope == .page, method == WITransportMethod.Page.getResourceTree else {
                    return nil
                }
                return Data(
                    #"""
                    {
                      "frameTree": {
                        "frame": {
                          "id": "frame-main",
                          "loaderId": "loader-main",
                          "url": "https://example.com/",
                          "securityOrigin": "https://example.com",
                          "mimeType": "text/html"
                        },
                        "resources": [
                          {
                            "url": "https://example.com/app.js",
                            "type": "Script",
                            "mimeType": "text/javascript"
                          }
                        ]
                      }
                    }
                    """#.utf8
                )
            }
        )
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)
        let response = try await Self.pageGetResourceTree(using: session)

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
                guard scope == .page, method == WITransportMethod.Page.getResourceTree else {
                    return nil
                }
                return Data(
                    #"""
                    {
                      "frameTree": {
                        "frame": {
                          "id": "frame-main",
                          "loaderId": "loader-main",
                          "url": "https://example.com/",
                          "securityOrigin": "https://example.com",
                          "mimeType": "text/html"
                        },
                        "resources": [
                          {
                            "url": "https://example.com/unknown.bin",
                            "type": "Preload",
                            "mimeType": "application/octet-stream"
                          }
                        ]
                      }
                    }
                    """#.utf8
                )
            }
        )
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)
        let response = try await Self.pageGetResourceTree(using: session)

        #expect(response.frameTree.resources.count == 1)
        #expect(response.frameTree.resources.first?.type == .other)
        #expect(response.frameTree.resources.first?.mimeType == "application/octet-stream")
    }

    @Test
    func inboundQueuePreservesRootThenPageArrivalOrder() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(
                responseTimeout: .seconds(1),
                dropEventsWithoutSubscribers: false
            ),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-B"}}"#
        )
        backend.emitPageMessage(
            #"{"method":"Network.responseReceived","params":{"requestId":"request-1","timestamp":1.0,"type":"Fetch","response":{"url":"https://example.com/data.json","status":200,"statusText":"OK","headers":{},"mimeType":"application/json"}}}"#,
            targetIdentifier: "page-B"
        )
        await backend.waitForPendingMessages()

        let events = await Self.nextEvents(from: session, count: 3)
        #expect(events.map(\.method) == [
            "Target.targetCreated",
            "Target.didCommitProvisionalTarget",
            "Network.responseReceived",
        ])
        #expect(events.map(\.targetIdentifier) == ["page-A", "page-B", "page-B"])
    }

    @Test
    func pageEventBufferKeepsNewestEnvelopesForLateConsumersWhenConfigured() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(
                responseTimeout: .seconds(1),
                eventBufferLimit: 2,
                dropEventsWithoutSubscribers: false
            ),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-B"}}"#
        )
        backend.emitPageMessage(
            #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-1"}}"#,
            targetIdentifier: "page-B"
        )
        backend.emitPageMessage(
            #"{"method":"Network.loadingFinished","params":{"requestId":"request-1"}}"#,
            targetIdentifier: "page-B"
        )
        await backend.waitForPendingMessages()

        let events = await Self.nextEvents(from: session, count: 2)
        #expect(events.map(\.method) == [
            "Network.requestWillBeSent",
            "Network.loadingFinished",
        ])
        #expect(events.map(\.targetIdentifier) == ["page-B", "page-B"])
    }

    @Test
    func pageEventStreamReplaysAttachTimeEventsBeforeFirstConsumerWhenDroppingLateEvents() async throws {
        let backend = FakeSessionBackend(attachHandler: { messageSink in
            messageSink.didReceiveRootMessage(
                #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#
            )
            messageSink.didReceiveRootMessage(
                #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-B"}}"#
            )
            await messageSink.waitForPendingMessagesForTesting()
        })
        let session = WITransportSession(
            configuration: .init(
                responseTimeout: .seconds(1),
                eventBufferLimit: 2,
                dropEventsWithoutSubscribers: true
            ),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let events = await Self.nextEvents(from: session, count: 2)
        #expect(events.map(\.method) == [
            "Target.targetCreated",
            "Target.didCommitProvisionalTarget",
        ])
        #expect(events.map(\.targetIdentifier) == ["page-A", "page-B"])
    }

    @Test
    func waitForPendingMessagesBlocksUntilQueuedInboundMessagesDrain() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-B"}}"#
        )
        await backend.waitForPendingMessages()

        let pageTargets = session.pageTargetIdentifiers()
        #expect(pageTargets.first == "page-B")
    }

    @Test
    func pageEventStreamReturnsLifecycleAndNetworkEventsInOrder() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(
                responseTimeout: .seconds(1),
                dropEventsWithoutSubscribers: false
            ),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-B"}}"#
        )
        backend.emitPageMessage(
            #"{"method":"Network.responseReceived","params":{"requestId":"request-1","timestamp":1.0,"type":"Fetch","response":{"url":"https://example.com/data.json","status":200,"statusText":"OK","headers":{},"mimeType":"application/json"}}}"#,
            targetIdentifier: "page-B"
        )
        backend.emitRootMessage(
            #"{"method":"Target.targetDestroyed","params":{"targetId":"page-B"}}"#
        )
        await backend.waitForPendingMessages()

        let events = await Self.nextEvents(from: session, count: 4)
        #expect(events.map(\.method) == [
            "Target.targetCreated",
            "Target.didCommitProvisionalTarget",
            "Network.responseReceived",
            "Target.targetDestroyed",
        ])
        #expect(events.map(\.targetIdentifier) == ["page-A", "page-B", "page-B", "page-B"])
    }

    @Test
    func pageEventBufferKeepsNewestEnvelopesForSlowConsumersAfterSubscriptionStarts() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(
                responseTimeout: .seconds(1),
                eventBufferLimit: 2,
                dropEventsWithoutSubscribers: true
            ),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()

        let attachEvent = await iterator.next()
        #expect(attachEvent?.method == "Target.targetCreated")
        #expect(attachEvent?.targetIdentifier == "page-A")

        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-B"}}"#
        )
        await backend.waitForPendingMessages()

        let firstEvent = await iterator.next()
        #expect(firstEvent?.method == "Target.didCommitProvisionalTarget")
        #expect(firstEvent?.targetIdentifier == "page-B")

        backend.emitPageMessage(
            #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-1"}}"#,
            targetIdentifier: "page-B"
        )
        backend.emitPageMessage(
            #"{"method":"Network.responseReceived","params":{"requestId":"request-1"}}"#,
            targetIdentifier: "page-B"
        )
        backend.emitRootMessage(
            #"{"method":"Target.targetDestroyed","params":{"targetId":"page-B"}}"#
        )
        await backend.waitForPendingMessages()

        let secondEvent = await iterator.next()
        let thirdEvent = await iterator.next()

        #expect([secondEvent?.method, thirdEvent?.method] == [
            "Network.responseReceived",
            "Target.targetDestroyed",
        ])
        #expect([secondEvent?.targetIdentifier, thirdEvent?.targetIdentifier] == ["page-B", "page-B"])
    }

    @Test
    func waitForPendingMessagesCompletesForOffMainEnqueue() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        await backend.emitRootMessageFromBackground(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-B"}}"#
        )
        await backend.waitForPendingMessages()

        #expect(session.currentPageTargetIdentifier() == "page-B")
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

private struct RootMethodEchoResponse: Codable, Sendable {
    let method: String
}

@MainActor
private final class FakeSessionBackend: WITransportPlatformBackend {
    var supportSnapshot: WITransportSupportSnapshot

    private var messageSink: (any WITransportBackendMessageSink)?
    private let supportSnapshotAfterAttach: WITransportSupportSnapshot?
    private let compatibilityResponseProvider: ((WITransportTargetScope, String) -> Data?)?
    var onSendRootMessage: ((String) throws -> Void)?
    var onSendPageMessage: ((String, String, Int) async throws -> Void)?
    private(set) var sentPageMessageCount = 0
    private let attachHandler: ((any WITransportBackendMessageSink) async -> Void)?

    init(
        supportSnapshot: WITransportSupportSnapshot? = nil,
        supportSnapshotAfterAttach: WITransportSupportSnapshot? = nil,
        compatibilityResponseProvider: ((WITransportTargetScope, String) -> Data?)? = nil,
        attachHandler: ((any WITransportBackendMessageSink) async -> Void)? = nil
    ) {
        self.supportSnapshot = supportSnapshot ?? .supported(
            backendKind: Self.defaultSupportedBackendKind,
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain]
        )
        self.supportSnapshotAfterAttach = supportSnapshotAfterAttach
        self.compatibilityResponseProvider = compatibilityResponseProvider
        self.attachHandler = attachHandler
    }

    func attach(to webView: WKWebView, messageSink: any WITransportBackendMessageSink) async throws {
        _ = webView
        self.messageSink = messageSink
        if let supportSnapshotAfterAttach {
            supportSnapshot = supportSnapshotAfterAttach
        }
        if let attachHandler {
            await attachHandler(messageSink)
        } else {
            messageSink.didReceiveRootMessage(
                #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#
            )
            await messageSink.waitForPendingMessagesForTesting()
        }
    }

    func detach() {
        messageSink = nil
    }

    func sendRootMessage(_ message: String) throws {
        try onSendRootMessage?(message)
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        sentPageMessageCount += 1
        if let onSendPageMessage {
            Task {
                try await onSendPageMessage(message, targetIdentifier, outerIdentifier)
            }
        }
    }

    func compatibilityResponse(scope: WITransportTargetScope, method: String) -> Data? {
        compatibilityResponseProvider?(scope, method)
    }

    func emitFatalFailure(_ message: String) {
        messageSink?.didReceiveFatalFailure(message)
    }

    func emitRootMessage(_ message: String) {
        messageSink?.didReceiveRootMessage(message)
    }

    func emitRootMessageFromBackground(_ message: String) async {
        guard let messageSink else {
            return
        }

        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                messageSink.didReceiveRootMessage(message)
                continuation.resume()
            }
        }
    }

    func emitPageMessage(_ message: String, targetIdentifier: String) {
        messageSink?.didReceivePageMessage(message, targetIdentifier: targetIdentifier)
    }

    func waitForPendingMessages() async {
        await messageSink?.waitForPendingMessagesForTesting()
    }

    private static var defaultSupportedBackendKind: WITransportBackendKind {
#if os(macOS)
        .macOSNativeInspector
#else
        .iOSNativeInspector
#endif
    }
}

private extension WITransportSessionTests {
    static func nextEvents(
        from session: WITransportSession,
        count: Int
    ) async -> [WITransportEventEnvelope] {
        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()
        var events: [WITransportEventEnvelope] = []
        events.reserveCapacity(count)
        for _ in 0..<count {
            guard let event = await iterator.next() else {
                break
            }
            events.append(event)
        }
        return events
    }

    static func codec() -> WITransportCodec {
        WITransportCodec.shared
    }

    static func targetEnable(using session: WITransportSession) async throws {
        let parametersData = try await codec().encode(
            TargetSetPauseOnStartParameters(pauseOnStart: false)
        )
        _ = try await session.sendRootData(
            method: WITransportMethod.Target.setPauseOnStart,
            parametersData: parametersData
        )
    }

    static func browserGetVersion(using session: WITransportSession) async throws -> BrowserGetVersionResponse {
        try await codec().decode(
            BrowserGetVersionResponse.self,
            from: try await session.sendRootData(method: WITransportMethod.Browser.getVersion)
        )
    }

    static func pageGetResourceTree(
        using session: WITransportSession,
        targetIdentifier: String? = nil
    ) async throws -> PageGetResourceTreeResponse {
        try await codec().decode(
            PageGetResourceTreeResponse.self,
            from: try await session.sendPageData(
                method: WITransportMethod.Page.getResourceTree,
                targetIdentifier: targetIdentifier
            )
        )
    }

    static func domEnable(
        using session: WITransportSession,
        targetIdentifier: String? = nil
    ) async throws {
        _ = try await session.sendPageData(
            method: WITransportMethod.DOM.enable,
            targetIdentifier: targetIdentifier
        )
    }

    static func domGetDocument(
        using session: WITransportSession,
        depth: Int? = nil,
        pierce: Bool? = nil,
        targetIdentifier: String? = nil
    ) async throws -> DOMGetDocumentResponse {
        let parametersData = try await codec().encode(
            DOMGetDocumentParameters(depth: depth, pierce: pierce)
        )
        return try await codec().decode(
            DOMGetDocumentResponse.self,
            from: try await session.sendPageData(
                method: WITransportMethod.DOM.getDocument,
                targetIdentifier: targetIdentifier,
                parametersData: parametersData
            )
        )
    }

    actor PageDispatchRecorder {
        private(set) var targetIdentifiers: [String] = []

        func record(targetIdentifier: String) {
            targetIdentifiers.append(targetIdentifier)
        }

        func snapshot() -> [String] {
            targetIdentifiers
        }
    }

    static func identifier(from message: String) throws -> Int {
        guard
            let object = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
            let identifier = object["id"] as? Int
        else {
            throw TestError.invalidMessage
        }
        return identifier
    }

    static func method(from message: String) throws -> String {
        guard
            let object = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any],
            let method = object["method"] as? String
        else {
            throw TestError.invalidMessage
        }
        return method
    }

    static func jsonString(_ object: [String: Any]) -> String {
        String(decoding: jsonData(object), as: UTF8.self)
    }

    static func jsonData(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    enum TestError: Error {
        case invalidMessage
    }
}

private struct TargetSetPauseOnStartParameters: Encodable, Sendable {
    let pauseOnStart: Bool
}

private struct BrowserGetVersionResponse: Decodable, Sendable {
    let method: String
}

private struct PageGetResourceTreeResponse: Decodable, Sendable {
    let frameTree: WITransportFrameResourceTree
}

private struct DOMGetDocumentParameters: Encodable, Sendable {
    let depth: Int?
    let pierce: Bool?
}

private struct DOMGetDocumentResponse: Decodable, Sendable {
    let root: WITransportDOMNode
}
