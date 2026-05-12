import Foundation
import Testing
import WebInspectorTestSupport
import WebKit
@testable import WebInspectorTransport

@MainActor
@Suite(.serialized, .webKitIsolated)
struct WITransportSessionTests {
    @Test
    func macOSDefaultBackendFactoryIsUnsupported() {
        #if os(macOS)
        let backend = WITransportPlatformBackendFactory.makeDefaultBackend(configuration: .init())
        #expect(backend.supportSnapshot.isSupported == false)
        #expect(backend.supportSnapshot.failureReason == "WebInspectorTransport currently supports iOS only.")
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
                capabilities: [.rootMessaging],
                failureReason: "preflight snapshot"
            ),
            supportSnapshotAfterAttach: .supported(
                capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain]
            )
        )
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        #expect(session.supportSnapshot.capabilities.contains(.domDomain))
        #expect(session.supportSnapshot.capabilities.contains(.networkDomain))
        #expect(session.supportSnapshot.failureReason == nil)
    }

    @Test
    func attachCompletesBeforePageTargetBecomesAvailable() async throws {
        let backend = FakeSessionBackend(attachHandler: { _ in })
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        #expect(session.state == .attached)
        #expect(session.currentPageTargetIdentifier() == nil)
    }

    @Test
    func waitForPageTargetReturnsTargetThatSurvivesTransientChurn() async throws {
        let backend = FakeSessionBackend(attachHandler: { messageSink in
            messageSink.didReceiveRootMessage(
                #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#
            )
            messageSink.didReceiveRootMessage(
                #"{"method":"Target.targetDestroyed","params":{"targetId":"page-A"}}"#
            )
            await messageSink.waitForPendingMessages()

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
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
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
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
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
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
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
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
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
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        async let firstData: Void = Self.targetEnable(using: session)
        async let secondData = Self.browserGetVersion(using: session)

        try await firstData
        let second = try await secondData

        #expect(second.method == WITransportMethod.Browser.getVersion)
    }

    @Test
    func ambiguousCommitWithoutKnownLineageDoesNotReplaceCurrentPageTarget() async throws {
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
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"newTargetId":"page-C"}}"#
        )
        await backend.waitForPendingMessages()

        _ = try await Self.pageGetResourceTree(using: session)

        #expect(await recorder.snapshot() == ["page-A"])
        #expect(session.currentPageTargetIdentifier() == "page-A")
    }

    @Test
    func nonProvisionalPageTargetCreationDoesNotReplaceCurrentPageTargetWithoutCommit() async throws {
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
                    "result": [:],
                ]),
                targetIdentifier: targetIdentifier
            )
        }
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        backend.emitRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-subframe","type":"page","isProvisional":false}}}"#
        )
        await backend.waitForPendingMessages()
        _ = try await session.sendPageData(method: WITransportMethod.DOM.enable)

        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"newTargetId":"page-subframe"}}"#
        )
        await backend.waitForPendingMessages()
        _ = try await session.sendPageData(method: WITransportMethod.DOM.enable)

        #expect(await recorder.snapshot() == ["page-A", "page-A"])
        #expect(session.currentPageTargetIdentifier() == "page-A")
    }

    @Test
    func nonDerivedPageCommitDoesNotReplaceAuthoritativeWebViewPageTarget() async throws {
        let backend = FakeSessionBackend()
        let recorder = PageDispatchRecorder()
        backend.onSendPageMessage = { message, targetIdentifier, outerIdentifier in
            await recorder.record(targetIdentifier: targetIdentifier)
            let identifier = try Self.identifier(from: message)
            #expect(identifier == outerIdentifier)
            backend.emitPageMessage(
                Self.jsonString([
                    "id": identifier,
                    "result": [:],
                ]),
                targetIdentifier: targetIdentifier
            )
        }
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in "page-A" }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)
        #expect(session.currentPageTargetIdentifier() == "page-A")

        backend.emitRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-subframe","type":"page","frameId":"frame-subframe","parentFrameId":"main-frame","isProvisional":true}}}"#
        )
        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-subframe"}}"#
        )
        await backend.waitForPendingMessages()

        _ = try await session.sendPageData(method: WITransportMethod.DOM.enable)

        #expect(await recorder.snapshot() == ["page-A"])
        #expect(session.currentPageTargetIdentifier() == "page-A")
        #expect(session.currentCommittedPageTargetIdentifier() == "page-A")
    }

    @Test
    func provisionalFramePageTargetWithoutParentFrameIDDoesNotReplaceCurrentPageTarget() async throws {
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
                    "result": [:],
                ]),
                targetIdentifier: targetIdentifier
            )
        }
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)
        #expect(session.currentPageTargetIdentifier() == "page-A")

        backend.emitRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-ad","type":"page","frameId":"frame-ad","isProvisional":true}}}"#
        )
        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"newTargetId":"page-ad"}}"#
        )
        await backend.waitForPendingMessages()

        _ = try await session.sendPageData(method: WITransportMethod.DOM.enable)

        #expect(await recorder.snapshot() == ["page-A"])
        #expect(session.currentPageTargetIdentifier() == "page-A")
        #expect(session.currentCommittedPageTargetIdentifier() == nil)
        #expect(session.targetKind(for: "page-ad") == .frame)
        #expect(session.frameTargetIdentifiers() == ["page-ad"])
        #expect(session.targetIdentifier(forFrameID: "frame-ad") == "page-ad")
    }

    @Test
    func authoritativeProvisionalPageTargetWithoutOldIdentifierBecomesCurrentPageTarget() async throws {
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
        var authoritativePageTargetIdentifier = "page-A"
        session.derivedPageTargetIdentifierProviderForTesting = { _ in authoritativePageTargetIdentifier }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)
        authoritativePageTargetIdentifier = "page-C"

        backend.emitRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-C","type":"page","frameId":"main-frame","isProvisional":true}}}"#
        )
        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"newTargetId":"page-C"}}"#
        )
        await backend.waitForPendingMessages()

        _ = try await Self.pageGetResourceTree(using: session)

        #expect(await recorder.snapshot() == ["page-C"])
        #expect(session.currentPageTargetIdentifier() == "page-C")
    }

    @Test
    func rootInspectorInspectWithoutExplicitTargetIdentifierDoesNotCoerceCurrentPageTarget() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()
        let attachEvent = await iterator.next()
        #expect(attachEvent?.method == "Target.targetCreated")
        #expect(attachEvent?.targetIdentifier == "page-A")

        backend.emitRootMessage(
            #"{"method":"Inspector.inspect","params":{"object":{"type":"object","subtype":"node","objectId":"node-object-6"},"hints":{}}}"#
        )
        await backend.waitForPendingMessages()

        let inspectEvent = await iterator.next()
        #expect(inspectEvent?.method == "Inspector.inspect")
        #expect(inspectEvent?.targetIdentifier == nil)
    }

    @Test
    func frameTargetLifecycleIsTrackedWithoutReplacingCurrentPageTarget() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()
        let attachEvent = await iterator.next()
        #expect(attachEvent?.method == "Target.targetCreated")
        #expect(attachEvent?.targetIdentifier == "page-A")

        backend.emitRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","isProvisional":false}}}"#
        )
        await backend.waitForPendingMessages()

        let frameEvent = await iterator.next()
        #expect(frameEvent?.method == "Target.targetCreated")
        #expect(frameEvent?.targetIdentifier == "frame-A")
        #expect(session.targetKind(for: "frame-A") == .frame)
        #expect(session.frameTargetIdentifiers() == ["frame-A"])
        #expect(session.currentPageTargetIdentifier() == "page-A")
        #expect(session.pageTargetIdentifiers() == ["page-A"])
    }

    @Test
    func destroyedFrameTargetKeepsKindLongEnoughForRuntimeRouting() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        backend.emitRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","isProvisional":false}}}"#
        )
        await backend.waitForPendingMessages()
        _ = await iterator.next()

        backend.emitRootMessage(
            #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-A"}}"#
        )
        await backend.waitForPendingMessages()

        let destroyedEvent = await iterator.next()
        #expect(destroyedEvent?.method == "Target.targetDestroyed")
        #expect(destroyedEvent?.targetIdentifier == "frame-A")
        #expect(session.targetKind(for: "frame-A") == .frame)
        #expect(session.frameTargetIdentifiers().isEmpty)
        #expect(session.currentPageTargetIdentifier() == "page-A")
    }

    @Test
    func runtimeExecutionContextCreatedRoutesContextToFrameTarget() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        backend.emitRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","isProvisional":false}}}"#
        )
        await backend.waitForPendingMessages()
        _ = await iterator.next()

        backend.emitPageMessage(
            #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":4,"frameId":"frame-child"}}}"#,
            targetIdentifier: "frame-A"
        )
        await backend.waitForPendingMessages()

        let contextEvent = await iterator.next()
        #expect(contextEvent?.method == WITransportMethod.Runtime.executionContextCreated)
        #expect(contextEvent?.targetIdentifier == "frame-A")
        #expect(session.targetIdentifier(forExecutionContext: 4) == "frame-A")
        #expect(session.targetIdentifier(forFrameID: "frame-child") == "frame-A")
    }

    @Test
    func rootRuntimeExecutionContextCreatedUsesFrameIDToRouteFrameTarget() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        backend.emitRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#
        )
        await backend.waitForPendingMessages()
        _ = await iterator.next()

        backend.emitRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-21474836526-1001","type":"frame","isProvisional":false}}}"#
        )
        await backend.waitForPendingMessages()
        _ = await iterator.next()
        #expect(session.targetIdentifier(forFrameID: "frame-21474836526") == "frame-21474836526-1001")

        backend.emitRootMessage(
            #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":4,"frameId":"frame-21474836526"}}}"#
        )
        await backend.waitForPendingMessages()

        let contextEvent = await iterator.next()
        #expect(contextEvent?.method == WITransportMethod.Runtime.executionContextCreated)
        #expect(contextEvent?.targetIdentifier == "frame-21474836526-1001")
        #expect(session.targetIdentifier(forExecutionContext: 4) == "frame-21474836526-1001")
        #expect(session.targetIdentifier(forFrameID: "frame-21474836526") == "frame-21474836526-1001")
    }

    @Test
    func destroyedFrameTargetDropsExecutionContextRoute() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        backend.emitRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-A","type":"frame","isProvisional":false}}}"#
        )
        await backend.waitForPendingMessages()
        _ = await iterator.next()

        backend.emitPageMessage(
            #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":4,"frameId":"frame-child"}}}"#,
            targetIdentifier: "frame-A"
        )
        await backend.waitForPendingMessages()
        _ = await iterator.next()
        #expect(session.targetIdentifier(forExecutionContext: 4) == "frame-A")

        backend.emitRootMessage(
            #"{"method":"Target.targetDestroyed","params":{"targetId":"frame-A"}}"#
        )
        await backend.waitForPendingMessages()

        _ = await iterator.next()
        #expect(session.targetIdentifier(forExecutionContext: 4) == nil)
        #expect(session.targetIdentifier(forFrameID: "frame-child") == nil)
    }

    @Test
    func committedFrameTargetMovesExecutionContextRoute() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()

        backend.emitRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"frame-provisional","type":"frame","isProvisional":true}}}"#
        )
        await backend.waitForPendingMessages()
        _ = await iterator.next()

        backend.emitPageMessage(
            #"{"method":"Runtime.executionContextCreated","params":{"context":{"id":4,"frameId":"frame-child"}}}"#,
            targetIdentifier: "frame-provisional"
        )
        await backend.waitForPendingMessages()
        _ = await iterator.next()
        #expect(session.targetIdentifier(forExecutionContext: 4) == "frame-provisional")

        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"frame-provisional","newTargetId":"frame-A"}}"#
        )
        await backend.waitForPendingMessages()

        _ = await iterator.next()
        #expect(session.targetIdentifier(forExecutionContext: 4) == "frame-A")
        #expect(session.targetIdentifier(forFrameID: "frame-child") == "frame-A")
        #expect(session.frameTargetIdentifiers() == ["frame-A"])
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
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
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
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
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
            await messageSink.waitForPendingMessages()
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
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
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
    func pageEventStreamKeepsAllEnvelopesAfterSubscriptionStarts() async throws {
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
        let fourthEvent = await iterator.next()

        #expect([secondEvent?.method, thirdEvent?.method, fourthEvent?.method] == [
            "Network.requestWillBeSent",
            "Network.responseReceived",
            "Target.targetDestroyed",
        ])
        #expect(
            [secondEvent?.targetIdentifier, thirdEvent?.targetIdentifier, fourthEvent?.targetIdentifier]
                == ["page-B", "page-B", "page-B"]
        )
    }

    @Test
    func rootDOMEventsAreForwardedIntoPageEventStream() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)
        let eventsTask = Task {
            await Self.nextEvents(from: session, count: 2, timeout: .seconds(1))
        }
        defer { eventsTask.cancel() }

        backend.emitRootMessage(
            #"{"method":"DOM.setChildNodes","params":{"parentId":3,"nodes":[{"nodeId":6,"nodeType":1,"nodeName":"A","localName":"a","childNodeCount":0,"children":[]}]}}"#
        )
        await backend.waitForPendingMessages()

        let events = try #require(await eventsTask.value)
        #expect(events.count == 2)
        let attachEvent = events[0]
        #expect(attachEvent.method == "Target.targetCreated")
        #expect(attachEvent.targetIdentifier == "page-A")

        let domEvent = events[1]
        #expect(domEvent.method == "DOM.setChildNodes")
        #expect(domEvent.targetIdentifier == "page-A")
        let paramsObject = try #require(try? JSONSerialization.jsonObject(with: domEvent.paramsData) as? [String: Any])
        #expect(paramsObject["parentId"] as? Int == 3)
    }

    @Test
    func waitForPostActivePageEventsToDrainIgnoresLaterTraffic() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()

        let attachEvent = await iterator.next()
        #expect(attachEvent?.method == "Target.targetCreated")
        session.beginPageEventDelivery()
        session.finishPageEventDelivery()

        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-B"}}"#
        )
        await backend.waitForPendingMessages()

        let drainTask = Task { @MainActor in
            await session.waitForPostActivePageEventsToDrain()
        }
        defer { drainTask.cancel() }
        await Task.yield()

        backend.emitPageMessage(
            #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-1"}}"#,
            targetIdentifier: "page-B"
        )
        await backend.waitForPendingMessages()

        let committedTargetEvent = await iterator.next()
        #expect(committedTargetEvent?.method == "Target.didCommitProvisionalTarget")
        session.beginPageEventDelivery()
        session.finishPageEventDelivery()

        let drainedAfterCommittedTarget = await Self.task(
            drainTask,
            completesWithinNanoseconds: 200_000_000
        )

        #expect(drainedAfterCommittedTarget)

        let laterTrafficEvent = await iterator.next()
        #expect(laterTrafficEvent?.method == "Network.requestWillBeSent")
        session.beginPageEventDelivery()
        session.finishPageEventDelivery()
    }

    @Test
    func waitForPostActivePageEventsToDrainWaitsForQueuedActiveEvent() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(
                responseTimeout: .seconds(1),
                eventBufferLimit: 1
            ),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()

        let attachEvent = await iterator.next()
        #expect(attachEvent?.method == "Target.targetCreated")
        session.beginPageEventDelivery()
        session.finishPageEventDelivery()

        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-B"}}"#
        )
        await backend.waitForPendingMessages()

        let drainTask = Task { @MainActor in
            await session.waitForPostActivePageEventsToDrain()
        }
        defer { drainTask.cancel() }
        await Task.yield()

        backend.emitPageMessage(
            #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-1"}}"#,
            targetIdentifier: "page-B"
        )
        await backend.waitForPendingMessages()

        let drainedBeforeDeliveringQueuedEvent = await Self.task(
            drainTask,
            completesWithinNanoseconds: 200_000_000
        )

        #expect(drainedBeforeDeliveringQueuedEvent == false)

        let committedTargetEvent = await iterator.next()
        #expect(committedTargetEvent?.method == "Target.didCommitProvisionalTarget")
        session.beginPageEventDelivery()
        session.finishPageEventDelivery()

        let drainedAfterDeliveringQueuedEvent = await Self.task(
            drainTask,
            completesWithinNanoseconds: 200_000_000
        )

        #expect(drainedAfterDeliveringQueuedEvent)
    }

    @Test
    func waitForPostActivePageEventsToDrainCompletesAfterPreConsumerBufferOverflow() async throws {
        let backend = FakeSessionBackend(attachHandler: { messageSink in
            messageSink.didReceiveRootMessage(
                #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#
            )
            messageSink.didReceiveRootMessage(
                #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-B"}}"#
            )
            await messageSink.waitForPendingMessages()
        })
        let session = WITransportSession(
            configuration: .init(
                responseTimeout: .seconds(1),
                eventBufferLimit: 1,
                dropEventsWithoutSubscribers: true
            ),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()

        let bufferedEvent = await iterator.next()
        #expect(bufferedEvent?.method == "Target.didCommitProvisionalTarget")
        session.beginPageEventDelivery()
        session.finishPageEventDelivery()

        let drainTask = Task { @MainActor in
            await session.waitForPostActivePageEventsToDrain()
        }
        defer { drainTask.cancel() }
        let drainedAfterOverflow = await Self.task(
            drainTask,
            completesWithinNanoseconds: 200_000_000
        )

        #expect(drainedAfterOverflow)
    }

    @Test
    func waitForPostActivePageEventsToDrainDoesNotCompleteWhileOlderActiveEventIsStillRunning() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(
                responseTimeout: .seconds(1),
                eventBufferLimit: 1
            ),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let stream = session.pageEvents()
        var iterator = stream.makeAsyncIterator()

        let attachEvent = await iterator.next()
        #expect(attachEvent?.method == "Target.targetCreated")
        session.beginPageEventDelivery()

        backend.emitRootMessage(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-B"}}"#
        )
        await backend.waitForPendingMessages()

        let drainTask = Task { @MainActor in
            await session.waitForPostActivePageEventsToDrain()
        }
        defer { drainTask.cancel() }
        await Task.yield()

        backend.emitPageMessage(
            #"{"method":"Network.requestWillBeSent","params":{"requestId":"request-1"}}"#,
            targetIdentifier: "page-B"
        )
        await backend.waitForPendingMessages()

        let drainedWhileFirstEventWasStillActive = await Self.task(
            drainTask,
            completesWithinNanoseconds: 200_000_000
        )

        #expect(drainedWhileFirstEventWasStillActive == false)

        session.finishPageEventDelivery()

        let drainedAfterFinishingActiveEvent = await Self.task(
            drainTask,
            completesWithinNanoseconds: 200_000_000
        )

        #expect(drainedAfterFinishingActiveEvent == false)

        let committedTargetEvent = await iterator.next()
        #expect(committedTargetEvent?.method == "Target.didCommitProvisionalTarget")
        session.beginPageEventDelivery()
        session.finishPageEventDelivery()

        let drainedAfterDeliveringQueuedEvent = await Self.task(
            drainTask,
            completesWithinNanoseconds: 200_000_000
        )

        #expect(drainedAfterDeliveringQueuedEvent)
    }

    @Test
    func waitForPendingMessagesCompletesForOffMainEnqueue() async throws {
        let backend = FakeSessionBackend()
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        await backend.emitRootMessageFromBackground(
            #"{"method":"Target.didCommitProvisionalTarget","params":{"oldTargetId":"page-A","newTargetId":"page-B"}}"#
        )
        await backend.waitForPendingMessages()

        #expect(session.currentPageTargetIdentifier() == "page-B")
    }

    @Test
    func pageCommandsKeepObservedTargetWhenDerivedSeedIsNoLongerAllowed() async throws {
        let backend = FakeSessionBackend(attachHandler: { messageSink in
            messageSink.didReceiveRootMessage(
                #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-observed","type":"page","isProvisional":false}}}"#
            )
            await messageSink.waitForPendingMessages()
        })
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in "page-derived" }
        let webView = makeIsolatedTestWebView()

        backend.onSendPageMessage = { message, targetIdentifier, outerIdentifier in
            let identifier = try Self.identifier(from: message)
            #expect(identifier == outerIdentifier)
            #expect(targetIdentifier == "page-observed")
            backend.emitPageMessage(
                Self.jsonString([
                    "id": identifier,
                    "result": [:],
                ]),
                targetIdentifier: targetIdentifier
            )
        }

        try await session.attach(to: webView)
        _ = try await session.sendPageData(method: WITransportMethod.DOM.enable)

        #expect(session.currentPageTargetIdentifier() == "page-observed")
        #expect(session.pageTargetIdentifiers() == ["page-observed"])
    }

    @Test
    func provisionalTargetCreationDoesNotDiscardDerivedCommittedSeedBeforeCommit() async throws {
        let backend = FakeSessionBackend(attachHandler: { _ in })
        let session = WITransportSession(
            configuration: .init(responseTimeout: .seconds(1)),
            backendFactory: { _ in backend }
        )
        session.derivedPageTargetIdentifierProviderForTesting = { _ in "page-derived" }
        let webView = makeIsolatedTestWebView()

        backend.onSendPageMessage = { message, targetIdentifier, outerIdentifier in
            let identifier = try Self.identifier(from: message)
            #expect(identifier == outerIdentifier)
            #expect(targetIdentifier == "page-derived")
            backend.emitPageMessage(
                Self.jsonString([
                    "id": identifier,
                    "result": [:],
                ]),
                targetIdentifier: targetIdentifier
            )
        }

        try await session.attach(to: webView)
        #expect(session.currentPageTargetIdentifier() == "page-derived")

        backend.emitRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-provisional","type":"page","isProvisional":true}}}"#
        )
        await backend.waitForPendingMessages()

        _ = try await session.sendPageData(method: WITransportMethod.DOM.enable)

        #expect(session.currentPageTargetIdentifier() == "page-derived")
        #expect(session.pageTargetIdentifiers() == ["page-derived", "page-provisional"])
    }

    @Test
    func supportedSnapshotFactoryPreservesCapabilitiesAndFailureReason() {
        let snapshot = WITransportSupportSnapshot.supported(
            capabilities: [.rootMessaging, .domDomain],
            failureReason: "preflight snapshot"
        )

        #expect(snapshot.availability == .supported)
        #expect(snapshot.capabilities == [.rootMessaging, .domDomain])
        #expect(snapshot.failureReason == "preflight snapshot")
    }

    @Test
    func unsupportedSnapshotFactoryClearsCapabilities() {
        let snapshot = WITransportSupportSnapshot.unsupported(reason: "backend unavailable")

        #expect(snapshot.availability == .unsupported)
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
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain]
        )
        self.supportSnapshotAfterAttach = supportSnapshotAfterAttach
        self.compatibilityResponseProvider = compatibilityResponseProvider
        self.attachHandler = attachHandler
    }

    func attach(to webView: WKWebView, messageSink: any WITransportBackendMessageSink) async throws {
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
            await messageSink.waitForPendingMessages()
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
        await messageSink?.waitForPendingMessages()
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

    static func nextEvents(
        from session: WITransportSession,
        count: Int,
        timeout: Duration
    ) async -> [WITransportEventEnvelope]? {
        let task = Task { await nextEvents(from: session, count: count) }
        let timeoutTask = Task {
            do {
                try await ContinuousClock().sleep(for: timeout)
            } catch {
                return
            }
            task.cancel()
        }
        let events = await task.value
        timeoutTask.cancel()
        return events.count == count ? events : nil
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

    static func task(
        _ task: Task<Void, Never>,
        completesWithinNanoseconds timeoutNanoseconds: UInt64
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let box = BoolContinuationBox()
            Task {
                await task.value
                box.resume(true, continuation: continuation)
            }
            Task {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                box.resume(false, continuation: continuation)
            }
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

private final class BoolContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(_ value: Bool, continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        lock.unlock()

        continuation.resume(returning: value)
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
