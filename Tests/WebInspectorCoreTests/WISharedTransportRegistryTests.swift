import Foundation
import Testing
import WebKit
import WebInspectorTestSupport
@testable import WebInspectorCore
@testable import WebInspectorCore
@testable import WebInspectorCore
@testable import WebInspectorTransport

@MainActor
@Suite(.serialized, .webKitIsolated)
struct WISharedTransportRegistryTests {
    @Test
    func sameWebViewSharesSingleTransportAttachmentAcrossLeases() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let firstLease = registry.acquireLease(for: webView)
        let secondLease = registry.acquireLease(for: webView)

        try await firstLease.ensureAttached()
        try await secondLease.ensureAttached()

        #expect(backend.attachCallCount == 1)

        firstLease.release()
        secondLease.release()
    }

    @Test
    func networkIngressFansOutSingleEventToMultipleConsumersWithoutDuplication() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let firstLease = registry.acquireLease(for: webView)
        let secondLease = registry.acquireLease(for: webView)
        let firstID = UUID()
        let secondID = UUID()

        var firstEvents: [String] = []
        var secondEvents: [String] = []

        firstLease.addNetworkConsumer(firstID) { event in
            firstEvents.append(event.method)
            Task {
                await sharedTransportStateChanges.push(())
            }
        }
        secondLease.addNetworkConsumer(secondID) { event in
            secondEvents.append(event.method)
            Task {
                await sharedTransportStateChanges.push(())
            }
        }

        try await firstLease.ensureNetworkEventIngress()
        try await secondLease.ensureNetworkEventIngress()

        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-1",
                "timestamp": 1.0,
                "metrics": [:],
            ]
        )

        let delivered = await waitForCondition {
            firstEvents == ["Network.loadingFinished"] && secondEvents == ["Network.loadingFinished"]
        }

        #expect(delivered)
        #expect(firstEvents == ["Network.loadingFinished"])
        #expect(secondEvents == ["Network.loadingFinished"])
        #expect(backend.attachCallCount == 1)

        firstLease.removeNetworkConsumer(firstID)
        secondLease.removeNetworkConsumer(secondID)
        firstLease.release()
        secondLease.release()
    }

    @Test
    func networkIngressIncludesWebSocketTransportEvents() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let lease = registry.acquireLease(for: webView)
        let consumerID = UUID()
        var methods: [String] = []

        lease.addNetworkConsumer(consumerID) { event in
            methods.append(event.method)
            Task {
                await sharedTransportStateChanges.push(())
            }
        }

        try await lease.ensureNetworkEventIngress()
        backend.emitPageEvent(
            method: "Network.webSocketCreated",
            params: [
                "requestId": "socket-1",
                "url": "wss://example.com/socket",
            ]
        )

        #expect(await waitForCondition {
            methods == ["Network.webSocketCreated"]
        })

        lease.removeNetworkConsumer(consumerID)
        lease.release()
    }

    @Test
    func networkTransportDriverFetchesDeferredRequestBodiesFromTransport() async {
        let backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                if method == "Network.getRequestPostData" {
                    return ["postData": "name=value"]
                }
                return nil
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let session = WINetworkRuntime(
            configuration: .init(),
            backend: driver
        )
        let webView = makeIsolatedTestWebView()

        session.attach(pageWebView: webView)

        #expect(await waitForCondition {
            backend.sentPageMethods.contains("Network.enable")
        })

        let body = await session.fetchBody(ref: "request-1", handle: nil as AnyObject?, role: .request)

        #expect(body?.role == .request)
        #expect(body?.full == "name=value")
        #expect(backend.sentPageMethods.contains("Network.getRequestPostData"))

        session.detach()
    }

    @Test
    func networkTransportDriverCreatesDeferredRequestBodyPlaceholderWhenInlinePostDataIsMissing() async {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(await waitForCondition {
            backend.sentPageMethods.contains("Network.enable")
        })

        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-1",
                "timestamp": 1.0,
                "type": "Fetch",
                "request": [
                    "url": "https://example.com/form",
                    "method": "POST",
                    "headers": [:],
                ],
            ]
        )

        let placeholderCreated = await waitForCondition {
            guard let entry = driver.store.entries.first else {
                return false
            }
            return entry.requestBody?.reference == "request-1"
                && entry.requestBody?.fetchState == .inline
                && entry.requestBody?.role == .request
                && entry.requestBody?.full == nil
        }

        #expect(placeholderCreated)

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func registryDetachesTransportOnlyAfterLastLeaseIsReleased() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let firstLease = registry.acquireLease(for: webView)
        let secondLease = registry.acquireLease(for: webView)

        try await firstLease.ensureAttached()
        try await secondLease.ensureAttached()

        firstLease.release()
        #expect(backend.detachCallCount == 0)

        secondLease.release()
        #expect(backend.detachCallCount == 1)
    }

    @Test
    func networkIngressRestartsAfterTransportFailureWhileConsumersRemain() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let lease = registry.acquireLease(for: webView)
        let ingressReadyEvents = AsyncValueQueue<Void>()
        lease.onNetworkIngressReadyForTesting = {
            Task {
                await ingressReadyEvents.push(())
            }
        }
        let consumerID = UUID()
        var events: [String] = []

        lease.addNetworkConsumer(consumerID) { event in
            events.append(event.method)
            Task {
                await sharedTransportStateChanges.push(())
            }
        }

        try await lease.ensureNetworkEventIngress()
        _ = await ingressReadyEvents.next()
        #expect(backend.sentPageMethods.filter { $0 == "Network.enable" }.count == 1)
        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-1",
                "timestamp": 1.0,
                "metrics": [:],
            ]
        )

        #expect(await waitForCondition {
            events == ["Network.loadingFinished"]
        })

        backend.emitFatalFailure("backend died")
        #expect(await waitForCondition {
            backend.detachCallCount == 1
        })

        #expect(await waitForCondition {
            backend.attachCallCount == 2
        })
        #expect(await waitForCondition {
            backend.sentPageMethods.filter { $0 == "Network.enable" }.count == 2
        })
        _ = await ingressReadyEvents.next()

        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-2",
                "timestamp": 2.0,
                "metrics": [:],
            ]
        )

        #expect(await waitForCondition {
            events == ["Network.loadingFinished", "Network.loadingFinished"]
        })

        lease.removeNetworkConsumer(consumerID)
        lease.release()
    }

    @Test
    func domIngressRestartsAfterTransportFailureWhileConsumersRemain() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let lease = registry.acquireLease(for: webView)
        let ingressReadyEvents = AsyncValueQueue<Void>()
        lease.onDOMIngressReadyForTesting = {
            Task {
                await ingressReadyEvents.push(())
            }
        }
        let consumerID = UUID()
        var events: [String] = []

        lease.addDOMConsumer(consumerID) { event in
            events.append(event.method)
            Task {
                await sharedTransportStateChanges.push(())
            }
        }

        try await lease.ensureDOMEventIngress()
        _ = await ingressReadyEvents.next()
        #expect(backend.sentPageMethods.filter { $0 == "DOM.enable" }.count == 1)
        #expect(backend.sentPageMethods.filter { $0 == "CSS.enable" }.isEmpty)
        backend.emitPageEvent(
            method: "DOM.documentUpdated",
            params: [
                "reason": "initial",
            ]
        )

        #expect(await waitForCondition {
            events == ["DOM.documentUpdated"]
        })

        backend.emitFatalFailure("backend died")
        #expect(await waitForCondition {
            backend.detachCallCount == 1
        })

        #expect(await waitForCondition {
            backend.attachCallCount == 2
        })
        #expect(await waitForCondition {
            backend.sentPageMethods.filter { $0 == "DOM.enable" }.count == 2
        })
        _ = await ingressReadyEvents.next()
        #expect(backend.sentPageMethods.filter { $0 == "CSS.enable" }.isEmpty)

        backend.emitPageEvent(
            method: "DOM.documentUpdated",
            params: [
                "reason": "reload",
            ]
        )

        #expect(await waitForCondition {
            events == ["DOM.documentUpdated", "DOM.documentUpdated"]
        })

        lease.removeDOMConsumer(consumerID)
        lease.release()
    }

    @Test
    func networkIngressReenablesAfterCommittedProvisionalTarget() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let lease = registry.acquireLease(for: webView)
        let consumerID = UUID()
        lease.addNetworkConsumer(consumerID) { _ in }

        try await lease.ensureNetworkEventIngress()
        #expect(backend.sentPageTargets.filter { $0.method == "Network.enable" }.map(\.targetIdentifier) == ["page-A"])

        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-A",
                "newTargetId": "page-B",
            ]
        )

        #expect(await waitForCondition {
            backend.sentPageTargets.filter { $0.method == "Network.enable" }.map(\.targetIdentifier) == ["page-A", "page-B"]
        })

        lease.removeNetworkConsumer(consumerID)
        lease.release()
    }

    @Test
    func domIngressIncludesChildNodeCountUpdatedEvents() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let lease = registry.acquireLease(for: webView)
        let consumerID = UUID()
        var events: [String] = []

        lease.addDOMConsumer(consumerID) { event in
            events.append(event.method)
            Task {
                await sharedTransportStateChanges.push(())
            }
        }

        try await lease.ensureDOMEventIngress()
        backend.emitPageEvent(
            method: "DOM.childNodeCountUpdated",
            params: [
                "nodeId": 42,
                "childNodeCount": 3,
            ]
        )

        #expect(await waitForCondition {
            events == ["DOM.childNodeCountUpdated"]
        })

        lease.removeDOMConsumer(consumerID)
        lease.release()
    }

    @Test
    func domIngressIgnoresMissingDOMEnableWhenBackendReportsProtocolGap() async throws {
        let backend = FakeRegistryBackend(
            pageMethodErrors: [
                "DOM.enable": "'DOM.enable' was not found",
            ]
        )
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let lease = registry.acquireLease(for: webView)
        let consumerID = UUID()
        var events: [String] = []

        lease.addDOMConsumer(consumerID) { event in
            events.append(event.method)
            Task {
                await sharedTransportStateChanges.push(())
            }
        }

        try await lease.ensureDOMEventIngress()
        #expect(backend.sentPageMethods.filter { $0 == "DOM.enable" }.count == 1)
        #expect(backend.sentPageMethods.filter { $0 == "CSS.enable" }.isEmpty)

        backend.emitPageEvent(
            method: "DOM.documentUpdated",
            params: [
                "reason": "initial",
            ]
        )

        #expect(await waitForCondition {
            events == ["DOM.documentUpdated"]
        })

        lease.removeDOMConsumer(consumerID)
        lease.release()
    }

    @Test
    func networkTransportDriverDeinitReleasesSharedLease() async {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()
        weak var driver: NetworkTransportDriver?

        do {
            let retainedDriver = NetworkTransportDriver(registry: registry)
            driver = retainedDriver
            retainedDriver.attachPageWebView(webView)
            #expect(await waitForCondition {
                backend.attachCallCount == 1
            })
        }

        #expect(await waitForCondition {
            driver == nil
        })
        #expect(await waitForCondition {
            backend.detachCallCount == 1
        })
    }

    @Test
    func cssDomainReadyNoopsWithoutSendingCSSEnable() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let lease = registry.acquireLease(for: webView)
        let consumerID = UUID()

        lease.addDOMConsumer(consumerID) { _ in }

        try await lease.ensureDOMEventIngress()
        #expect(backend.sentPageMethods.filter { $0 == "DOM.enable" }.count == 1)
        #expect(backend.sentPageMethods.filter { $0 == "CSS.enable" }.isEmpty)

        try await lease.ensureCSSDomainReady()
        #expect(backend.sentPageMethods.filter { $0 == "DOM.enable" }.count == 1)
        #expect(backend.sentPageMethods.filter { $0 == "CSS.enable" }.isEmpty)

        try await lease.ensureCSSDomainReady()
        #expect(backend.sentPageMethods.filter { $0 == "CSS.enable" }.isEmpty)

        lease.removeDOMConsumer(consumerID)
        lease.release()
    }

    @Test
    func domTransportDriverDeinitReleasesSharedLease() async {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()
        weak var driver: DOMTransportDriver?

        do {
            let graphStore = DOMGraphStore()
            let retainedDriver = DOMTransportDriver(
                configuration: .init(),
                graphStore: graphStore,
                registry: registry
            )
            driver = retainedDriver
            retainedDriver.attachPageWebView(webView)
            #expect(await waitForCondition {
                backend.attachCallCount == 1
            })
        }

        #expect(await waitForCondition {
            driver == nil
        })
        #expect(await waitForCondition {
            backend.detachCallCount == 1
        })
    }

    @Test
    func selectionModeRequestsDeeperReloadForDeepInspectedNode() async throws {
        let targetDepth = 12
        let targetNodeID = targetDepth + 1
        let backend = FakeRegistryBackend { method, payload in
            guard method == "DOM.getDocument" else {
                return nil
            }

            let params = payload["params"] as? [String: Any]
            let requestedDepth = params?["depth"] as? Int ?? 1
            return [
                "root": makeDeepDocumentPayload(
                    totalDepth: targetDepth,
                    requestedDepth: requestedDepth
                )
            ]
        }
        let registry = makeRegistry(using: backend)
        let graphStore = DOMGraphStore()
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: graphStore,
            registry: registry,
            selectionBridge: nil
        )
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        #expect(await waitForCondition {
            backend.attachCallCount == 1
        })

        try await driver.reloadDocument(preserveState: false)
        let selectionTask = Task {
            try await driver.beginSelectionMode()
        }

        #expect(await waitForCondition {
            backend.sentPageMethods.contains("DOM.setInspectModeEnabled")
        })

        backend.emitPageEvent(
            method: "DOM.inspect",
            params: ["nodeId": targetNodeID]
        )

        let result = try await selectionTask.value
        #expect(result.cancelled == false)
        #expect(result.requiredDepth == targetDepth)
        #expect(backend.documentDepthRequests.contains(8))
        #expect(backend.documentDepthRequests.contains(16))

        try await driver.reloadDocument(
            preserveState: true,
            requestedDepth: result.requiredDepth + 1
        )
        #expect(graphStore.selectedEntry?.id.nodeID == targetNodeID)
    }

#if os(iOS)
    @Test
    func selectionModeOmitsShowRulersInIOSInspectModeCommand() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: DOMGraphStore(),
            registry: registry,
            selectionBridge: nil
        )
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        #expect(await waitForCondition {
            backend.attachCallCount == 1
        })

        let selectionTask = Task {
            try await driver.beginSelectionMode()
        }

        let inspectModeRequested = await waitForCondition {
            backend.sentPagePayloads.contains { payload in
                guard let method = payload["method"] as? String else {
                    return false
                }
                return method == "DOM.setInspectModeEnabled"
            }
        }
        #expect(inspectModeRequested == true)

        let payload = backend.sentPagePayloads.last {
            guard let method = $0["method"] as? String else {
                return false
            }
            return method == "DOM.setInspectModeEnabled"
        }
        let params = payload?["params"] as? [String: Any]
        #expect(params?["showRulers"] == nil)

        await driver.cancelSelectionMode()
        let result = try await selectionTask.value
        #expect(result.cancelled == true)
    }
#endif

    @Test
    func documentUpdateCancelsPendingSelectionMode() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: DOMGraphStore(),
            registry: registry,
            selectionBridge: nil
        )
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        #expect(await waitForCondition {
            backend.attachCallCount == 1
        })

        let selectionTask = Task {
            try await driver.beginSelectionMode()
        }

        #expect(await waitForCondition {
            backend.sentPageMethods.contains("DOM.setInspectModeEnabled")
        })

        backend.emitPageEvent(method: "DOM.documentUpdated", params: [:])
        let result = try await selectionTask.value

        #expect(result.cancelled == true)
        #expect(await waitForCondition {
            backend.sentPagePayloads.contains { payload in
            guard let method = payload["method"] as? String,
                  method == "DOM.setInspectModeEnabled",
                  let params = payload["params"] as? [String: Any],
                  let enabled = params["enabled"] as? Bool else {
                return false
            }
            return enabled == false
            }
        })
    }

    @Test
    func documentUpdateFailsPendingChildNodeFetch() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let driver = DOMTransportDriver(
            configuration: .init(),
            graphStore: DOMGraphStore(),
            registry: registry
        )
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        #expect(await waitForCondition {
            backend.attachCallCount == 1
        })

        let requestTask = Task {
            try await driver.requestChildNodes(parentNodeId: 42)
        }

        #expect(await waitForCondition {
            backend.sentPagePayloads.contains { payload in
                guard let method = payload["method"] as? String,
                      method == "DOM.requestChildNodes",
                      let params = payload["params"] as? [String: Any],
                      let nodeId = params["nodeId"] as? Int else {
                    return false
                }
                return nodeId == 42
            }
        })

        backend.emitPageEvent(method: "DOM.documentUpdated", params: [:])

        do {
            _ = try await requestTask.value
            Issue.record("Expected pending child-node fetch to cancel on document update")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    @Test
    func networkTransportDriverAppliesWebSocketEventsToStore() async {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()
        #expect(await waitForCondition {
            backend.attachCallCount == 1
                && backend.sentPageMethods.contains("Network.enable")
        })

        backend.emitPageEvent(
            method: "Network.webSocketCreated",
            params: [
                "requestId": "socket-1",
                "url": "wss://example.com/socket",
            ]
        )
        #expect(await waitForCondition {
            driver.store.entries.count == 1
                && driver.store.entries.first?.requestType == "websocket"
        })
        backend.emitPageEvent(
            method: "Network.webSocketWillSendHandshakeRequest",
            params: [
                "requestId": "socket-1",
                "timestamp": 1.0,
                "walltime": 2.0,
                "request": [
                    "headers": [
                        "sec-websocket-protocol": "chat",
                    ],
                ],
            ]
        )
        #expect(await waitForCondition {
            driver.store.entries.first?.requestHeaders["sec-websocket-protocol"] == "chat"
        })
        backend.emitPageEvent(
            method: "Network.webSocketFrameSent",
            params: [
                "requestId": "socket-1",
                "timestamp": 2.0,
                "response": [
                    "opcode": 1,
                    "mask": false,
                    "payloadData": "hello",
                    "payloadLength": 5,
                ],
            ]
        )
        #expect(await waitForCondition {
            driver.store.entries.first?.webSocket?.frames.count == 1
                && driver.store.entries.first?.webSocket?.frames.first?.direction == .outgoing
                && driver.store.entries.first?.webSocket?.frames.first?.payload == "hello"
        })
        backend.emitPageEvent(
            method: "Network.webSocketClosed",
            params: [
                "requestId": "socket-1",
                "timestamp": 3.0,
            ]
        )

        #expect(await waitForCondition {
            guard let entry = driver.store.entries.first else {
                return false
            }
            return driver.store.entries.count == 1
                && entry.requestHeaders["sec-websocket-protocol"] == "chat"
                && entry.webSocket?.frames.count == 1
                && entry.webSocket?.frames.first?.direction == .outgoing
                && entry.webSocket?.frames.first?.payload == "hello"
                && entry.phase == .completed
        })

        let entry = driver.store.entries.first
        #expect(entry?.requestType == "websocket")
        #expect(entry?.requestHeaders["sec-websocket-protocol"] == "chat")
        #expect(entry?.webSocket?.frames.count == 1)
        #expect(entry?.webSocket?.frames.first?.direction == .outgoing)
        #expect(entry?.webSocket?.frames.first?.payload == "hello")
        #expect(entry?.phase == .completed)
    }
}

private let sharedTransportStateChanges = AsyncValueQueue<Void>()

@MainActor
private extension WISharedTransportRegistryTests {
    func makeRegistry(using backend: FakeRegistryBackend) -> WISharedTransportRegistry {
        WISharedTransportRegistry { _ in
            WITransportSession(
                configuration: .init(responseTimeout: .seconds(1)),
                backendFactory: { _ in backend }
            )
        }
    }

    func waitForCondition(
        maxTurns: Int = 8_192,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        if await condition() {
            return true
        }

        for _ in 0..<maxTurns {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
            if await condition() {
                return true
            }
        }
        return await condition()
    }
}

@MainActor
private final class FakeRegistryBackend: WITransportPlatformBackend {
    struct SentPageTarget: Equatable {
        let method: String
        let targetIdentifier: String
    }

    var supportSnapshot = WITransportSupportSnapshot.supported(
        backendKind: .macOSNativeInspector,
        capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain]
    )

    private(set) var attachCallCount = 0
    private(set) var detachCallCount = 0
    private(set) var sentPageMethods: [String] = []
    private(set) var sentPageTargets: [SentPageTarget] = []
    private(set) var sentPagePayloads: [[String: Any]] = []
    private(set) var documentDepthRequests: [Int] = []
    private var messageHandlers: WITransportBackendMessageHandlers?
    private var ownsWebKitTestIsolation = false
    private let pageMethodErrors: [String: String]
    private let pageResultProvider: ((String, [String: Any]) -> [String: Any]?)?

    init(
        pageMethodErrors: [String: String] = [:],
        pageResultProvider: ((String, [String: Any]) -> [String: Any]?)? = nil
    ) {
        self.pageMethodErrors = pageMethodErrors
        self.pageResultProvider = pageResultProvider
    }

    deinit {
        guard ownsWebKitTestIsolation else {
            return
        }
        ownsWebKitTestIsolation = false
        Task { @MainActor in
            await releaseWebKitTestIsolation()
        }
    }

    func attach(to webView: WKWebView, messageHandlers: WITransportBackendMessageHandlers) async throws {
        _ = webView
        if isWebKitTestIsolationActive {
            ownsWebKitTestIsolation = false
        } else {
            await acquireWebKitTestIsolation()
            ownsWebKitTestIsolation = true
        }
        attachCallCount += 1
        self.messageHandlers = messageHandlers
        messageHandlers.handleRootMessage(
            #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#
        )
        messageHandlers.waitForPendingMessagesForTesting?()
        Task {
            await sharedTransportStateChanges.push(())
        }
    }

    func detach() {
        detachCallCount += 1
        messageHandlers = nil
        if ownsWebKitTestIsolation {
            ownsWebKitTestIsolation = false
            Task { @MainActor in
                await releaseWebKitTestIsolation()
            }
        }
        Task {
            await sharedTransportStateChanges.push(())
        }
    }

    func sendRootMessage(_ message: String) throws {
        _ = message
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        let payload = try decodeMessagePayload(message)
        sentPagePayloads.append(payload)
        if let method = payload["method"] as? String {
            sentPageMethods.append(method)
            sentPageTargets.append(SentPageTarget(method: method, targetIdentifier: targetIdentifier))
            if method == "DOM.getDocument" {
                let params = payload["params"] as? [String: Any]
                if let requestedDepth = params?["depth"] as? Int {
                    documentDepthRequests.append(requestedDepth)
                }
            }
            if let identifier = payload["id"] as? Int, let errorMessage = pageMethodErrors[method] {
                messageHandlers?.handlePageMessage(
                    #"{"id":\#(identifier),"error":{"message":"\#(errorMessage)"}}"#,
                    targetIdentifier
                )
                return
            }
            if let identifier = payload["id"] as? Int,
               let result = pageResultProvider?(method, payload),
               JSONSerialization.isValidJSONObject(result),
               let data = try? JSONSerialization.data(withJSONObject: result),
               let resultString = String(data: data, encoding: .utf8) {
                messageHandlers?.handlePageMessage(
                    #"{"id":\#(identifier),"result":\#(resultString)}"#,
                    targetIdentifier
                )
                return
            }
        }
        if let identifier = payload["id"] as? Int {
            messageHandlers?.handlePageMessage(
                #"{"id":\#(identifier),"result":{}}"#,
                targetIdentifier
            )
        }
        _ = outerIdentifier
        Task {
            await sharedTransportStateChanges.push(())
        }
    }

    func compatibilityResponse(scope: WITransportTargetScope, method: String) -> Data? {
        _ = scope
        _ = method
        return nil
    }

    func emitPageEvent(method: String, params: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params),
              let paramsString = String(data: data, encoding: .utf8)
        else {
            Issue.record("Failed to encode fake page event params for \(method)")
            return
        }

        messageHandlers?.handlePageMessage(
            #"{"method":"\#(method)","params":\#(paramsString)}"#,
            "page-A"
        )
        Task {
            await sharedTransportStateChanges.push(())
        }
    }

    func emitRootEvent(method: String, params: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params),
              let paramsString = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to encode fake root event params for \(method)")
            return
        }

        messageHandlers?.handleRootMessage(
            #"{"method":"\#(method)","params":\#(paramsString)}"#
        )
        Task {
            await sharedTransportStateChanges.push(())
        }
    }

    func emitFatalFailure(_ message: String) {
        messageHandlers?.handleFatalFailure(message)
        Task {
            await sharedTransportStateChanges.push(())
        }
    }

    private func decodeMessagePayload(_ message: String) throws -> [String: Any] {
        let data = Data(message.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }
}

private func makeDeepDocumentPayload(
    totalDepth: Int,
    requestedDepth: Int,
    currentDepth: Int = 0,
    nodeID: Int = 1
) -> [String: Any] {
    let hasChild = currentDepth < totalDepth
    let childCount = hasChild ? 1 : 0

    var node: [String: Any] = [
        "nodeId": nodeID,
        "nodeType": currentDepth == 0 ? 9 : 1,
        "nodeName": currentDepth == 0 ? "#document" : "DIV",
        "localName": currentDepth == 0 ? "" : "div",
        "nodeValue": "",
        "childNodeCount": childCount,
    ]

    if hasChild, currentDepth < requestedDepth {
        node["children"] = [
            makeDeepDocumentPayload(
                totalDepth: totalDepth,
                requestedDepth: requestedDepth,
                currentDepth: currentDepth + 1,
                nodeID: nodeID + 1
            )
        ]
    }

    return node
}
