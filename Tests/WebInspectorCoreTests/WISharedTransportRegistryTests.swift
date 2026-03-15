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

        let body = await session.fetchBody(locator: .networkRequest(id: "request-1", targetIdentifier: nil), role: .request)

        #expect(body?.role == .request)
        #expect(body?.full == "name=value")
        #expect(backend.sentPageMethods.contains("Network.getRequestPostData"))

        session.detach()
    }

    @Test
    func networkTransportDriverFetchesDeferredRequestBodiesFromOwningTarget() async {
        let backend = FakeRegistryBackend(
            pageTargetedResultProvider: { method, _, targetIdentifier in
                guard method == WITransportCommands.Network.GetRequestPostData.method,
                      targetIdentifier == "page-child" else {
                    return nil
                }
                return ["postData": "targeted=value"]
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

        let body = await session.fetchBody(
            locator: .networkRequest(id: "request-1", targetIdentifier: "page-child"),
            role: .request
        )

        #expect(body?.role == .request)
        #expect(body?.full == "targeted=value")
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Network.GetRequestPostData.method
                    && $0.targetIdentifier == "page-child"
            }
        )

        session.detach()
    }

    @Test
    func networkTransportDriverFetchesDeferredResponseBodiesFromOwningTarget() async {
        let backend = FakeRegistryBackend(
            pageTargetedResultProvider: { method, _, targetIdentifier in
                guard method == WITransportCommands.Network.GetResponseBody.method,
                      targetIdentifier == "page-child" else {
                    return nil
                }
                return [
                    "body": "targeted-response",
                    "base64Encoded": false,
                ]
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

        let body = await session.fetchBody(
            locator: .networkRequest(id: "request-2", targetIdentifier: "page-child"),
            role: .response
        )

        #expect(body?.role == .response)
        #expect(body?.full == "targeted-response")
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Network.GetResponseBody.method
                    && $0.targetIdentifier == "page-child"
            }
        )

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
            return entry.requestBody?.hasDeferredContent == true
                && entry.requestBody?.fetchState == .inline
                && entry.requestBody?.role == .request
                && entry.requestBody?.full == nil
        }

        #expect(placeholderCreated)

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverBootstrapsExistingResourcesFromResourceTreeOnAttach() async {
        let backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Page.GetResourceTree.method else {
                    return nil
                }
                return makeResourceTreeResultPayload(
                    mainURL: "https://example.com/",
                    resources: [
                        makeFrameResourcePayload(
                            url: "https://example.com/app.js",
                            type: "Script",
                            mimeType: "text/javascript"
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(backend.sentPageMethods.contains(WITransportCommands.Page.GetResourceTree.method))
        #expect(await waitForCondition {
            driver.store.entries.count == 2
        })
        #expect(driver.store.entries.contains { entry in
            entry.url == "https://example.com/"
                && entry.requestType == "Document"
                && entry.method == "UNKNOWN"
                && entry.phase == .completed
        })
        #expect(driver.store.entries.contains { entry in
            entry.url == "https://example.com/app.js"
                && entry.requestType == "Script"
                && entry.method == "UNKNOWN"
                && entry.mimeType == "text/javascript"
                && entry.phase == .completed
        })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverCreatesNewEntryForLaterRequestToSameURLAfterBootstrapFinishes() async {
        let backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Page.GetResourceTree.method else {
                    return nil
                }
                return makeResourceTreeResultPayload(
                    mainURL: "https://example.com/",
                    resources: [
                        makeFrameResourcePayload(
                            url: "https://example.com/poll.json",
                            type: "Fetch",
                            mimeType: "application/json"
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-later-same-url",
                "timestamp": 10.0,
                "type": "Fetch",
                "request": [
                    "url": "https://example.com/poll.json",
                    "method": "POST",
                    "headers": [:],
                ],
            ]
        )

        #expect(await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/poll.json" }
            return matches.count == 2 && matches.contains { $0.method == "POST" }
        })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverKeepsBootstrapAndLiveRequestsWhenSameURLStartsDuringBootstrap() async {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Page.GetResourceTree.method else {
                    return nil
                }
                backend.emitPageEvent(
                    method: "Network.requestWillBeSent",
                    params: [
                        "requestId": "request-during-bootstrap",
                        "timestamp": 2.0,
                        "type": "Fetch",
                        "request": [
                            "url": "https://example.com/poll.json",
                            "method": "POST",
                            "headers": [:],
                        ],
                    ]
                )
                return makeResourceTreeResultPayload(
                    mainURL: "https://example.com/",
                    resources: [
                        makeFrameResourcePayload(
                            url: "https://example.com/poll.json",
                            type: "Fetch",
                            mimeType: "application/json"
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/poll.json" }
            return matches.count == 2
                && matches.contains { $0.method == "POST" }
                && matches.contains { $0.method == "UNKNOWN" }
        })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverReusesBootstrappedResourceWhenLiveResponseArrives() async {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Network.GetBootstrapSnapshot.method else {
                    return nil
                }
                backend.emitPageEvent(
                    method: "Network.responseReceived",
                    params: [
                        "requestId": "request-bootstrap",
                        "timestamp": 4.0,
                        "type": "Script",
                        "response": [
                            "url": "https://example.com/app.js",
                            "status": 200,
                            "statusText": "OK",
                            "headers": [:],
                            "mimeType": "text/javascript",
                        ],
                    ]
                )
                backend.emitPageEvent(
                    method: "Network.loadingFinished",
                    params: [
                        "requestId": "request-bootstrap",
                        "timestamp": 5.0,
                        "metrics": [
                            "responseBodyBytesReceived": 256,
                            "responseBodyDecodedSize": 256,
                        ],
                    ]
                )
                return makeBootstrapSnapshotResultPayload(
                    resources: [
                        makeBootstrapResourcePayload(
                            bootstrapRowID: "app-js",
                            rawRequestID: "request-bootstrap",
                            ownerSessionID: "page-A",
                            frameID: "frame-main",
                            targetIdentifier: "page-A",
                            url: "https://example.com/app.js",
                            method: "GET",
                            requestType: "Script",
                            mimeType: "text/javascript",
                            phase: "inFlight",
                            bodyFetchDescriptor: [
                                "targetIdentifier": "page-A",
                                "frameId": "frame-main",
                                "url": "https://example.com/app.js",
                            ]
                        ),
                    ],
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(await waitForCondition {
            guard let entry = driver.store.entries.first(where: { $0.url == "https://example.com/app.js" }) else {
                return false
            }
            return entry.phase == .completed
                && entry.statusCode == 200
                && entry.encodedBodyLength == 256
                && entry.responseBody?.deferredLocator != nil
        })
        #expect(driver.store.entries.filter { $0.url == "https://example.com/app.js" }.count == 1)

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverDoesNotOverwriteDocumentRowForSameURLDifferentResponseType() async {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Page.GetResourceTree.method else {
                    return nil
                }
                backend.emitPageEvent(
                    method: "Network.responseReceived",
                    params: [
                        "requestId": "request-same-url-fetch",
                        "timestamp": 4.0,
                        "type": "Fetch",
                        "response": [
                            "url": "https://example.com/",
                            "status": 200,
                            "statusText": "OK",
                            "headers": [:],
                            "mimeType": "application/json",
                        ],
                    ]
                )
                backend.emitPageEvent(
                    method: "Network.loadingFinished",
                    params: [
                        "requestId": "request-same-url-fetch",
                        "timestamp": 5.0,
                        "metrics": [
                            "responseBodyBytesReceived": 32,
                            "responseBodyDecodedSize": 32,
                        ],
                    ]
                )
                return makeResourceTreeResultPayload(
                    mainURL: "https://example.com/",
                    resources: []
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entries = driver.store.entries.filter { $0.url == "https://example.com/" }
        #expect(entries.count == 1)
        #expect(entries.first?.requestType == "Document")
        #expect(entries.first?.statusCode == nil)
        #expect(entries.first?.phase == .completed)

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverPreservesBootstrapBodyReferenceAfterLiveResponsePromotion() async throws {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, payload in
                switch method {
                case WITransportCommands.Network.GetBootstrapSnapshot.method:
                    backend.emitPageEvent(
                        method: "Network.responseReceived",
                        params: [
                            "requestId": "request-bootstrap-pending",
                            "timestamp": 4.0,
                            "type": "Script",
                            "response": [
                                "url": "https://example.com/app.js",
                                "status": 200,
                                "statusText": "OK",
                                "headers": [:],
                                "mimeType": "text/javascript",
                            ],
                        ]
                    )
                    return makeBootstrapSnapshotResultPayload(
                        resources: [
                            makeBootstrapResourcePayload(
                                bootstrapRowID: "app-js-pending",
                                rawRequestID: "request-bootstrap-pending",
                                ownerSessionID: "page-A",
                                frameID: "frame-main",
                                targetIdentifier: "page-A",
                                url: "https://example.com/app.js",
                                method: "GET",
                                requestType: "Script",
                                mimeType: "text/javascript",
                                phase: "inFlight",
                                bodyFetchDescriptor: [
                                    "targetIdentifier": "page-A",
                                    "frameId": "frame-main",
                                    "url": "https://example.com/app.js",
                                ]
                            ),
                        ],
                    )
                case WITransportCommands.Page.GetResourceContent.method:
                    let params = payload["params"] as? [String: Any]
                    let frameID = params?["frameId"] as? String
                    let url = params?["url"] as? String
                    if frameID == "frame-main", url == "https://example.com/app.js" {
                        return [
                            "content": "console.log('still fetchable');",
                            "base64Encoded": false,
                        ]
                    }
                    return nil
                default:
                    return nil
                }
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = try #require(driver.store.entries.first { $0.url == "https://example.com/app.js" })
        #expect(entry.phase == .pending)
        #expect(entry.statusCode == 200)
        let locator = try #require(entry.responseBody?.deferredLocator)

        let fetched = await driver.fetchBodyResult(locator: locator, role: .response)
        guard case .fetched(let body) = fetched else {
            Issue.record("Expected promoted bootstrap entry to keep its resource-content fallback")
            return
        }

        #expect(body.full == "console.log('still fetchable');")

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverFetchesBootstrappedResponseBodiesFromPageResourceContent() async throws {
        let backend = FakeRegistryBackend(
            pageResultProvider: { method, payload in
                switch method {
                case WITransportCommands.Page.GetResourceTree.method:
                    return makeResourceTreeResultPayload(
                        mainURL: "https://example.com/",
                        resources: [
                            makeFrameResourcePayload(
                                url: "https://example.com/app.js",
                                type: "Script",
                                mimeType: "text/javascript",
                                targetId: "page-B"
                            ),
                        ]
                    )
                case WITransportCommands.Page.GetResourceContent.method:
                    let params = payload["params"] as? [String: Any]
                    let frameID = params?["frameId"] as? String
                    let url = params?["url"] as? String
                    if frameID == "frame-main", url == "https://example.com/app.js" {
                        return [
                            "content": "console.log('bootstrapped');",
                            "base64Encoded": false,
                        ]
                    }
                    return nil
                default:
                    return nil
                }
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = try #require(driver.store.entries.first { $0.url == "https://example.com/app.js" })
        let locator = try #require(entry.responseBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .response)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected bootstrapped resource content to be fetched")
            return
        }

        #expect(body.full == "console.log('bootstrapped');")
        #expect(body.isBase64Encoded == false)
        #expect(backend.sentPageMethods.contains(WITransportCommands.Page.GetResourceContent.method))
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Page.GetResourceContent.method
                    && $0.targetIdentifier == "page-B"
            }
        )

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverUsesBodyFetchDescriptorURLForStableBootstrapBodies() async throws {
        let backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, payload in
                switch method {
                case WITransportCommands.Network.GetBootstrapSnapshot.method:
                    return makeBootstrapSnapshotResultPayload(
                        resources: [
                            makeBootstrapResourcePayload(
                                bootstrapRowID: "redirected-resource",
                                ownerSessionID: "page-B",
                                frameID: "frame-main",
                                targetIdentifier: "page-B",
                                url: "https://example.com/final.js",
                                method: "GET",
                                requestType: "Script",
                                mimeType: "text/javascript",
                                phase: "completed",
                                bodyFetchDescriptor: [
                                    "targetIdentifier": "page-B",
                                    "frameId": "frame-main",
                                    "url": "https://example.com/original.js",
                                ]
                            ),
                        ]
                    )
                case WITransportCommands.Page.GetResourceContent.method:
                    let params = payload["params"] as? [String: Any]
                    let frameID = params?["frameId"] as? String
                    let url = params?["url"] as? String
                    if frameID == "frame-main", url == "https://example.com/original.js" {
                        return [
                            "content": "console.log('descriptor-url');",
                            "base64Encoded": false,
                        ]
                    }
                    return nil
                default:
                    return nil
                }
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = try #require(driver.store.entries.first { $0.url == "https://example.com/final.js" })
        let locator = try #require(entry.responseBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .response)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected bootstrapped resource content to use bodyFetchDescriptor.url")
            return
        }

        #expect(body.full == "console.log('descriptor-url');")
        #expect(
            backend.sentPagePayloads.contains { payload in
                let params = payload["params"] as? [String: Any]
                return payload["method"] as? String == WITransportCommands.Page.GetResourceContent.method
                    && params?["url"] as? String == "https://example.com/original.js"
            }
        )

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverUsesOwnerSessionIDWhenStableBodyTargetIsOmitted() async throws {
        let backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, payload in
                switch method {
                case WITransportCommands.Network.GetBootstrapSnapshot.method:
                    return makeBootstrapSnapshotResultPayload(
                        resources: [
                            makeBootstrapResourcePayload(
                                bootstrapRowID: "owner-session-fallback",
                                ownerSessionID: "page-child",
                                frameID: "frame-child",
                                url: "https://example.com/frame.html",
                                method: "GET",
                                requestType: "Document",
                                mimeType: "text/html",
                                phase: "completed",
                                bodyFetchDescriptor: [
                                    "frameId": "frame-child",
                                    "url": "https://example.com/frame.html",
                                ]
                            ),
                        ]
                    )
                case WITransportCommands.Page.GetResourceContent.method:
                    let params = payload["params"] as? [String: Any]
                    let frameID = params?["frameId"] as? String
                    let url = params?["url"] as? String
                    if frameID == "frame-child", url == "https://example.com/frame.html" {
                        return [
                            "content": "<html>owner-session</html>",
                            "base64Encoded": false,
                        ]
                    }
                    return nil
                default:
                    return nil
                }
            },
            pageTargetedResultProvider: { method, payload, targetIdentifier in
                guard method == WITransportCommands.Page.GetResourceContent.method else {
                    return nil
                }
                let params = payload["params"] as? [String: Any]
                let frameID = params?["frameId"] as? String
                let url = params?["url"] as? String
                guard targetIdentifier == "page-child",
                      frameID == "frame-child",
                      url == "https://example.com/frame.html"
                else {
                    return nil
                }
                return [
                    "content": "<html>owner-session</html>",
                    "base64Encoded": false,
                ]
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = try #require(driver.store.entries.first { $0.url == "https://example.com/frame.html" })
        let locator = try #require(entry.responseBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .response)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected ownerSessionID to route stable bootstrap body fetches")
            return
        }

        #expect(body.full == "<html>owner-session</html>")
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Page.GetResourceContent.method
                    && $0.targetIdentifier == "page-child"
            }
        )

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverKeepsBootstrapTargetWhenPreferredTargetChangesDuringResourceTreeFetch() async throws {
        let backend = FakeRegistryBackend()
        backend.pageResultProvider = { method, payload in
            switch method {
            case WITransportCommands.Page.GetResourceTree.method:
                backend.emitRootEvent(
                    method: "Target.targetCreated",
                    params: [
                        "targetInfo": [
                            "targetId": "page-B",
                            "type": "page",
                            "isProvisional": false,
                        ],
                    ]
                )
                return makeResourceTreeResultPayload(
                    mainURL: "https://example.com/",
                    resources: [
                        makeFrameResourcePayload(
                            url: "https://example.com/app.js",
                            type: "Script",
                            mimeType: "text/javascript"
                        ),
                    ]
                )
            case WITransportCommands.Page.GetResourceContent.method:
                let params = payload["params"] as? [String: Any]
                let frameID = params?["frameId"] as? String
                let url = params?["url"] as? String
                if frameID == "frame-main", url == "https://example.com/app.js" {
                    return [
                        "content": "console.log('target-stable');",
                        "base64Encoded": false,
                    ]
                }
                return nil
            default:
                return nil
            }
        }
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = try #require(driver.store.entries.first { $0.url == "https://example.com/app.js" })
        #expect(entry.sessionID == "page-A")

        let locator = try #require(entry.responseBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .response)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected bootstrapped resource content to be fetched from the original target")
            return
        }

        #expect(body.full == "console.log('target-stable');")
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Page.GetResourceTree.method
                    && $0.targetIdentifier == "page-A"
            }
        )
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Page.GetResourceContent.method
                    && $0.targetIdentifier == "page-A"
            }
        )

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverMatchesSurvivingBootstrapCandidateAfterPruning() async {
        let backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Network.GetBootstrapSnapshot.method else {
                    return nil
                }
                return makeBootstrapSnapshotResultPayload(
                    resources: [
                        makeBootstrapResourcePayload(
                            bootstrapRowID: "app-js-pruned",
                            rawRequestID: "request-pruned-bootstrap",
                            ownerSessionID: "page-A",
                            frameID: "frame-main",
                            targetIdentifier: "page-A",
                            url: "https://example.com/app.js",
                            method: "GET",
                            requestType: "Script",
                            mimeType: "text/javascript",
                            phase: "inFlight",
                            bodyFetchDescriptor: [
                                "targetIdentifier": "page-A",
                                "frameId": "frame-main",
                                "url": "https://example.com/app.js",
                            ]
                        ),
                    ],
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        driver.store.maxEntries = 1
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(driver.store.entries.count == 1)
        #expect(driver.store.entries.first?.url == "https://example.com/app.js")

        backend.emitPageEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": "request-pruned-bootstrap",
                "timestamp": 10.0,
                "type": "Script",
                "response": [
                    "url": "https://example.com/app.js",
                    "status": 200,
                    "statusText": "OK",
                    "headers": [:],
                    "mimeType": "text/javascript",
                ],
            ]
        )
        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-pruned-bootstrap",
                "timestamp": 11.0,
                "metrics": [
                    "responseBodyBytesReceived": 128,
                    "responseBodyDecodedSize": 128,
                ],
            ]
        )

        #expect(await waitForCondition {
            guard let entry = driver.store.entries.first else {
                return false
            }
            return driver.store.entries.count == 1
                && entry.url == "https://example.com/app.js"
                && entry.phase == .completed
                && entry.statusCode == 200
                && entry.encodedBodyLength == 128
        })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverIgnoresLoadingFailedWithoutResolvedRequestMapping() async {
        let backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Page.GetResourceTree.method else {
                    return nil
                }
                return makeResourceTreeResultPayload(
                    mainURL: "https://example.com/frame-failure.html",
                    resources: [
                        makeFrameResourcePayload(
                            url: "https://example.com/app.js",
                            type: "Script",
                            mimeType: "text/javascript"
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Network.loadingFailed",
            params: [
                "requestId": "request-bootstrap-failure",
                "timestamp": 6.0,
                "errorText": "Cancelled",
                "canceled": true,
            ]
        )

        try? await Task.sleep(for: .milliseconds(50))

        let frameEntry = driver.store.entries.first { $0.url == "https://example.com/frame-failure.html" }
        let scriptEntry = driver.store.entries.first { $0.url == "https://example.com/app.js" }
        #expect(frameEntry?.phase == .completed)
        #expect(frameEntry?.statusCode == nil)
        #expect(frameEntry?.errorDescription == nil)
        #expect(scriptEntry?.phase == .completed)
        #expect(scriptEntry?.statusCode == nil)

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverIgnoresLoadingFinishedWithoutResolvedRequestMapping() async {
        let backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Page.GetResourceTree.method else {
                    return nil
                }
                return makeResourceTreeResultPayload(
                    mainURL: "https://example.com/frame-finish.html",
                    resources: [
                        makeFrameResourcePayload(
                            url: "https://example.com/app.js",
                            type: "Script",
                            mimeType: "text/javascript"
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-bootstrap-finish",
                "timestamp": 7.0,
                "metrics": [
                    "responseBodyBytesReceived": 512,
                    "responseBodyDecodedSize": 512,
                ],
            ]
        )

        try? await Task.sleep(for: .milliseconds(50))

        let frameEntry = driver.store.entries.first { $0.url == "https://example.com/frame-finish.html" }
        let scriptEntry = driver.store.entries.first { $0.url == "https://example.com/app.js" }
        #expect(frameEntry?.encodedBodyLength == nil)
        #expect(frameEntry?.responseBody?.hasDeferredContent == true)
        #expect(frameEntry?.responseBody?.fetchState == .inline)
        #expect(scriptEntry?.encodedBodyLength == nil)
        #expect(driver.store.entries.filter { $0.url == "https://example.com/frame-finish.html" }.count == 1)

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverDoesNotExposeBodyPlaceholderForFailedBootstrappedResources() async {
        let backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Page.GetResourceTree.method else {
                    return nil
                }
                return makeResourceTreeResultPayload(
                    mainURL: "https://example.com/",
                    resources: [
                        makeFrameResourcePayload(
                            url: "https://example.com/failed.js",
                            type: "Script",
                            mimeType: "text/javascript",
                            failed: true
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = driver.store.entries.first { $0.url == "https://example.com/failed.js" }
        #expect(entry?.phase == .failed)
        #expect(entry?.responseBody == nil)

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverBootstrapsFallbackChildFrameResourcesOnCurrentTarget() async {
        let backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Page.GetResourceTree.method else {
                    return nil
                }
                return makeResourceTreeResultPayload(
                    mainURL: "https://example.com/",
                    resources: [],
                    childFrames: [
                        [
                            "frame": [
                                "id": "frame-child",
                                "parentId": "frame-main",
                                "loaderId": "loader-child",
                                "url": "https://example.com/frame.html",
                                "securityOrigin": "https://example.com",
                                "mimeType": "text/html",
                            ],
                            "resources": [],
                        ],
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(driver.store.entries.contains { $0.url == "https://example.com/frame.html" })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverPropagatesFallbackChildFrameSessionFromTargetScopedResources() async throws {
        let backend = FakeRegistryBackend(
            pageResultProvider: { method, payload in
                switch method {
                case WITransportCommands.Page.GetResourceTree.method:
                    return makeResourceTreeResultPayload(
                        mainURL: "https://example.com/",
                        resources: [],
                        childFrames: [
                            [
                                "frame": [
                                    "id": "frame-child",
                                    "parentId": "frame-main",
                                    "loaderId": "loader-child",
                                    "url": "https://example.com/frame.html",
                                    "securityOrigin": "https://example.com",
                                    "mimeType": "text/html",
                                ],
                                "resources": [
                                    makeFrameResourcePayload(
                                        url: "https://example.com/frame-script.js",
                                        type: "Script",
                                        mimeType: "text/javascript",
                                        targetId: "page-child"
                                    ),
                                ],
                            ],
                        ]
                    )
                case WITransportCommands.Page.GetResourceContent.method:
                    let params = payload["params"] as? [String: Any]
                    let frameID = params?["frameId"] as? String
                    let url = params?["url"] as? String
                    guard frameID == "frame-child",
                          url == "https://example.com/frame.html" else {
                        return nil
                    }
                    return [
                        "content": "<html>child target</html>",
                        "base64Encoded": false,
                    ]
                default:
                    return nil
                }
            },
            pageTargetedResultProvider: { method, payload, targetIdentifier in
                guard method == WITransportCommands.Page.GetResourceContent.method,
                      targetIdentifier == "page-child" else {
                    return nil
                }
                let params = payload["params"] as? [String: Any]
                let frameID = params?["frameId"] as? String
                let url = params?["url"] as? String
                guard frameID == "frame-child",
                      url == "https://example.com/frame.html" else {
                    return nil
                }
                return [
                    "content": "<html>child target</html>",
                    "base64Encoded": false,
                ]
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = try #require(driver.store.entries.first { $0.url == "https://example.com/frame.html" })
        #expect(entry.sessionID == "page-child")

        let locator = try #require(entry.responseBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .response)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected fallback child frame document body to be fetched from its child target")
            return
        }

        #expect(body.full == "<html>child target</html>")
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Page.GetResourceContent.method
                    && $0.targetIdentifier == "page-child"
            }
        )

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverFetchesBootstrappedChildFrameBodyWhenSnapshotProvidesExactTarget() async throws {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Network.GetBootstrapSnapshot.method else {
                    return nil
                }
                return makeBootstrapSnapshotResultPayload(
                    resources: [
                        makeBootstrapResourcePayload(
                            bootstrapRowID: "frame-child",
                            ownerSessionID: "page-child",
                            frameID: "frame-child",
                            targetIdentifier: "page-child",
                            url: "https://example.com/frame.html",
                            method: "GET",
                            requestType: "Document",
                            mimeType: "text/html",
                            phase: "completed",
                            bodyFetchDescriptor: [
                                "targetIdentifier": "page-child",
                                "frameId": "frame-child",
                                "url": "https://example.com/frame.html",
                            ]
                        ),
                    ]
                )
            },
            pageTargetedResultProvider: { method, payload, targetIdentifier in
                guard method == WITransportCommands.Page.GetResourceContent.method else {
                    return nil
                }
                let params = payload["params"] as? [String: Any]
                let frameID = params?["frameId"] as? String
                let url = params?["url"] as? String
                guard targetIdentifier == "page-child",
                      frameID == "frame-child",
                      url == "https://example.com/frame.html"
                else {
                    return nil
                }
                return [
                    "content": "<html><body>child</body></html>",
                    "base64Encoded": false,
                ]
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = try #require(driver.store.entries.first { $0.url == "https://example.com/frame.html" })
        let locator = try #require(entry.responseBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .response)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected child frame bootstrap body to be fetched from its exact target")
            return
        }

        #expect(body.full == "<html><body>child</body></html>")
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Page.GetResourceContent.method
                    && $0.targetIdentifier == "page-child"
            }
        )

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverReusesBootstrappedChildFrameRequestWhenRequestStartReplays() async {
        let backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Network.GetBootstrapSnapshot.method else {
                    return nil
                }
                return makeBootstrapSnapshotResultPayload(
                    resources: [
                        makeBootstrapResourcePayload(
                            bootstrapRowID: "frame-child-start",
                            rawRequestID: "request-child-frame-start",
                            ownerSessionID: "page-child",
                            frameID: "frame-child",
                            targetIdentifier: "page-child",
                            url: "https://example.com/frame.html",
                            method: "UNKNOWN",
                            requestType: "Document",
                            mimeType: "text/html",
                            phase: "inFlight"
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-child-frame-start",
                "frameId": "frame-child",
                "timestamp": 8.0,
                "type": "Document",
                "request": [
                    "url": "https://example.com/frame.html",
                    "method": "GET",
                    "headers": [:],
                ],
            ],
            targetIdentifier: "page-child"
        )
        backend.emitPageEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": "request-child-frame-start",
                "frameId": "frame-child",
                "timestamp": 8.5,
                "type": "Document",
                "response": [
                    "url": "https://example.com/frame.html",
                    "status": 200,
                    "statusText": "OK",
                    "headers": [:],
                    "mimeType": "text/html",
                ],
            ],
            targetIdentifier: "page-child"
        )
        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-child-frame-start",
                "timestamp": 9.0,
                "metrics": [:],
            ],
            targetIdentifier: "page-child"
        )

        #expect(await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/frame.html" }
            guard let entry = matches.first else {
                return false
            }
            return matches.count == 1
                && entry.sessionID == "page-child"
                && entry.phase == .completed
                && entry.statusCode == 200
        })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverSeedsDeferredRequestBodiesForStableInFlightBootstrapRows() async throws {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                switch method {
                case WITransportCommands.Network.GetBootstrapSnapshot.method:
                    return makeBootstrapSnapshotResultPayload(
                        resources: [
                            makeBootstrapResourcePayload(
                                bootstrapRowID: "post-request",
                                rawRequestID: "request-post-bootstrap",
                                ownerSessionID: "page-A",
                                frameID: "frame-main",
                                targetIdentifier: "page-A",
                                url: "https://example.com/upload",
                                method: "POST",
                                requestType: "Fetch",
                                mimeType: "application/json",
                                phase: "inFlight"
                            ),
                        ]
                    )
                case WITransportCommands.Network.GetRequestPostData.method:
                    return ["postData": #"{"hello":"world"}"#]
                default:
                    return nil
                }
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = try #require(driver.store.entries.first { $0.url == "https://example.com/upload" })
        let locator = try #require(entry.requestBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .request)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected bootstrapped in-flight request body to be fetchable")
            return
        }

        #expect(body.full == #"{"hello":"world"}"#)

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverPreservesDeferredRequestBodiesForCompletedStableBootstrapRows() async throws {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                switch method {
                case WITransportCommands.Network.GetBootstrapSnapshot.method:
                    return makeBootstrapSnapshotResultPayload(
                        resources: [
                            makeBootstrapResourcePayload(
                                bootstrapRowID: "post-request-completed",
                                rawRequestID: "request-post-completed",
                                ownerSessionID: "page-A",
                                frameID: "frame-main",
                                targetIdentifier: "page-A",
                                url: "https://example.com/upload-completed",
                                method: "POST",
                                requestType: "Fetch",
                                mimeType: "application/json",
                                phase: "completed"
                            ),
                        ]
                    )
                case WITransportCommands.Network.GetRequestPostData.method:
                    return ["postData": #"{"completed":true}"#]
                default:
                    return nil
                }
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = try #require(driver.store.entries.first { $0.url == "https://example.com/upload-completed" })
        let locator = try #require(entry.requestBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .request)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected completed stable bootstrap request body to remain fetchable")
            return
        }

        #expect(body.full == #"{"completed":true}"#)

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverUsesCurrentPageTargetForStableRequestBodiesWhenPayloadTargetIsMissing() async throws {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                switch method {
                case WITransportCommands.Network.GetBootstrapSnapshot.method:
                    return makeBootstrapSnapshotResultPayload(
                        resources: [
                            makeBootstrapResourcePayload(
                                bootstrapRowID: "post-request-current-target",
                                rawRequestID: "request-post-current-target",
                                ownerSessionID: "page",
                                frameID: "frame-main",
                                targetIdentifier: nil,
                                url: "https://example.com/upload-current-target",
                                method: "POST",
                                requestType: "Fetch",
                                mimeType: "application/json",
                                phase: "completed"
                            ),
                        ]
                    )
                default:
                    return nil
                }
            },
            pageTargetedResultProvider: { method, _, targetIdentifier in
                guard method == WITransportCommands.Network.GetRequestPostData.method,
                      targetIdentifier == "page-A" else {
                    return nil
                }
                return ["postData": #"{"currentTarget":true}"#]
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = try #require(driver.store.entries.first { $0.url == "https://example.com/upload-current-target" })
        let locator = try #require(entry.requestBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .request)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected stable request body to use the current page target when payload target is missing")
            return
        }

        #expect(body.full == #"{"currentTarget":true}"#)
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Network.GetRequestPostData.method
                    && $0.targetIdentifier == "page-A"
            }
        )

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverUsesOwnerSessionForStableRequestBodiesWhenPayloadTargetIsMissing() async throws {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                switch method {
                case WITransportCommands.Network.GetBootstrapSnapshot.method:
                    return makeBootstrapSnapshotResultPayload(
                        resources: [
                            makeBootstrapResourcePayload(
                                bootstrapRowID: "post-request-owner-session",
                                rawRequestID: "request-post-owner-session",
                                ownerSessionID: "page-child",
                                frameID: "frame-child",
                                targetIdentifier: nil,
                                url: "https://example.com/upload-owner-session",
                                method: "POST",
                                requestType: "Fetch",
                                mimeType: "application/json",
                                phase: "completed"
                            ),
                        ]
                    )
                default:
                    return nil
                }
            },
            pageTargetedResultProvider: { method, _, targetIdentifier in
                guard method == WITransportCommands.Network.GetRequestPostData.method,
                      targetIdentifier == "page-child" else {
                    return nil
                }
                return ["postData": #"{"ownerSession":true}"#]
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = try #require(driver.store.entries.first { $0.url == "https://example.com/upload-owner-session" })
        let locator = try #require(entry.requestBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .request)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected stable request body to use owner session when payload target is missing")
            return
        }

        #expect(body.full == #"{"ownerSession":true}"#)
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Network.GetRequestPostData.method
                    && $0.targetIdentifier == "page-child"
            }
        )

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverUsesCapturedTargetForStableRequestBodiesWhenOwnerSessionIsEmpty() async throws {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                switch method {
                case WITransportCommands.Network.GetBootstrapSnapshot.method:
                    return makeBootstrapSnapshotResultPayload(
                        resources: [
                            makeBootstrapResourcePayload(
                                bootstrapRowID: "post-request-empty-owner",
                                rawRequestID: "request-post-empty-owner",
                                ownerSessionID: "",
                                frameID: "frame-main",
                                targetIdentifier: nil,
                                url: "https://example.com/upload-empty-owner",
                                method: "POST",
                                requestType: "Fetch",
                                mimeType: "application/json",
                                phase: "completed"
                            ),
                        ]
                    )
                default:
                    return nil
                }
            },
            pageTargetedResultProvider: { method, _, targetIdentifier in
                guard method == WITransportCommands.Network.GetRequestPostData.method,
                      targetIdentifier == "page-A" else {
                    return nil
                }
                return ["postData": #"{"emptyOwner":true}"#]
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        let entry = try #require(driver.store.entries.first { $0.url == "https://example.com/upload-empty-owner" })
        let locator = try #require(entry.requestBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .request)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected stable request body to use captured target when owner session is empty")
            return
        }

        #expect(body.full == #"{"emptyOwner":true}"#)
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Network.GetRequestPostData.method
                    && $0.targetIdentifier == "page-A"
            }
        )

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverReusesBootstrappedChildFrameDocumentAcrossTargetSessions() async {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Network.GetBootstrapSnapshot.method else {
                    return nil
                }
                backend.emitPageEvent(
                    method: "Network.responseReceived",
                    params: [
                        "requestId": "request-child-frame",
                        "frameId": "frame-child",
                        "timestamp": 8.0,
                        "type": "Document",
                        "response": [
                            "url": "https://example.com/frame.html",
                            "status": 200,
                            "statusText": "OK",
                            "headers": [:],
                            "mimeType": "text/html",
                        ],
                    ],
                    targetIdentifier: "page-child"
                )
                backend.emitPageEvent(
                    method: "Network.loadingFinished",
                    params: [
                        "requestId": "request-child-frame",
                        "timestamp": 9.0,
                        "metrics": [:],
                    ],
                    targetIdentifier: "page-child"
                )
                return makeBootstrapSnapshotResultPayload(
                    resources: [
                        makeBootstrapResourcePayload(
                            bootstrapRowID: "frame-child-doc",
                            rawRequestID: "request-child-frame",
                            ownerSessionID: "page-child",
                            frameID: "frame-child",
                            targetIdentifier: "page-child",
                            url: "https://example.com/frame.html",
                            method: "GET",
                            requestType: "Document",
                            mimeType: "text/html",
                            phase: "inFlight"
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/frame.html" }
            guard let entry = matches.first else {
                return false
            }
            return matches.count == 1
                && entry.statusCode == 200
                && entry.sessionID == "page-child"
        })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverRebindsStableBootstrapRowsAcrossTargetChanges() async {
        let backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Network.GetBootstrapSnapshot.method else {
                    return nil
                }
                return makeBootstrapSnapshotResultPayload(
                    resources: [
                        makeBootstrapResourcePayload(
                            bootstrapRowID: "target-swap",
                            rawRequestID: "request-target-swap",
                            ownerSessionID: "page-provisional",
                            frameID: "frame-main",
                            targetIdentifier: "page-provisional",
                            url: "https://example.com/swap.js",
                            method: "UNKNOWN",
                            requestType: "Script",
                            mimeType: "text/javascript",
                            phase: "inFlight"
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-target-swap",
                "timestamp": 12.0,
                "type": "Script",
                "request": [
                    "url": "https://example.com/swap.js",
                    "method": "GET",
                    "headers": [:],
                ],
            ],
            targetIdentifier: "page-committed"
        )
        backend.emitPageEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": "request-target-swap",
                "timestamp": 13.0,
                "type": "Script",
                "response": [
                    "url": "https://example.com/swap.js",
                    "status": 200,
                    "statusText": "OK",
                    "headers": [:],
                    "mimeType": "text/javascript",
                ],
            ],
            targetIdentifier: "page-committed"
        )
        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-target-swap",
                "timestamp": 14.0,
                "metrics": [
                    "responseBodyBytesReceived": 64,
                    "responseBodyDecodedSize": 64,
                ],
            ],
            targetIdentifier: "page-committed"
        )

        #expect(await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/swap.js" }
            guard let entry = matches.first else {
                return false
            }
            return matches.count == 1
                && entry.sessionID == "page-committed"
                && entry.phase == .completed
                && entry.statusCode == 200
                && entry.encodedBodyLength == 64
        })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverMatchesRedirectedStableContinuationByPreviousURL() async {
        let backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Network.GetBootstrapSnapshot.method else {
                    return nil
                }
                return makeBootstrapSnapshotResultPayload(
                    resources: [
                        makeBootstrapResourcePayload(
                            bootstrapRowID: "redirect-rebind",
                            rawRequestID: "request-redirect-rebind",
                            ownerSessionID: "page-provisional",
                            frameID: "frame-main",
                            targetIdentifier: "page-provisional",
                            url: "https://example.com/original.js",
                            method: "GET",
                            requestType: "Script",
                            mimeType: "text/javascript",
                            phase: "inFlight"
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-redirect-rebind",
                "timestamp": 12.0,
                "type": "Script",
                "request": [
                    "url": "https://example.com/final.js",
                    "method": "GET",
                    "headers": [:],
                ],
                "redirectResponse": [
                    "url": "https://example.com/original.js",
                    "status": 302,
                    "statusText": "Found",
                    "headers": [
                        "Location": "https://example.com/final.js",
                    ],
                    "mimeType": "text/javascript",
                ],
            ],
            targetIdentifier: "page-committed"
        )
        backend.emitPageEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": "request-redirect-rebind",
                "timestamp": 13.0,
                "type": "Script",
                "response": [
                    "url": "https://example.com/final.js",
                    "status": 200,
                    "statusText": "OK",
                    "headers": [:],
                    "mimeType": "text/javascript",
                ],
            ],
            targetIdentifier: "page-committed"
        )
        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-redirect-rebind",
                "timestamp": 14.0,
                "metrics": [
                    "responseBodyBytesReceived": 64,
                    "responseBodyDecodedSize": 64,
                ],
            ],
            targetIdentifier: "page-committed"
        )

        #expect(await waitForCondition {
            let originalMatches = driver.store.entries.filter { $0.url == "https://example.com/original.js" }
            let finalMatches = driver.store.entries.filter { $0.url == "https://example.com/final.js" }
            guard let originalEntry = originalMatches.first,
                  let finalEntry = finalMatches.first else {
                return false
            }
            return originalMatches.count == 1
                && finalMatches.count == 1
                && originalEntry.sessionID == "page-committed"
                && originalEntry.phase == .completed
                && originalEntry.statusCode == 302
                && finalEntry.sessionID == "page-committed"
                && finalEntry.phase == .completed
                && finalEntry.statusCode == 200
                && finalEntry.encodedBodyLength == 64
        })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverUpdatesRequestBodyTargetAcrossStableCrossTargetRebinds() async throws {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Network.GetBootstrapSnapshot.method else {
                    return nil
                }
                return makeBootstrapSnapshotResultPayload(
                    resources: [
                        makeBootstrapResourcePayload(
                            bootstrapRowID: "target-swap-request-body",
                            rawRequestID: "request-target-swap-request-body",
                            ownerSessionID: "page-provisional",
                            frameID: "frame-main",
                            targetIdentifier: "page-provisional",
                            url: "https://example.com/swap-request-body",
                            method: "POST",
                            requestType: "Fetch",
                            mimeType: "application/json",
                            phase: "inFlight"
                        ),
                    ]
                )
            },
            pageTargetedResultProvider: { method, _, targetIdentifier in
                guard method == WITransportCommands.Network.GetRequestPostData.method,
                      targetIdentifier == "page-committed" else {
                    return nil
                }
                return ["postData": #"{"committed":true}"#]
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-target-swap-request-body",
                "timestamp": 12.0,
                "type": "Fetch",
                "request": [
                    "url": "https://example.com/swap-request-body",
                    "method": "POST",
                    "headers": [:],
                ],
            ],
            targetIdentifier: "page-committed"
        )

        let entry = try #require(
            await waitForCondition {
                driver.store.entries.contains {
                    $0.url == "https://example.com/swap-request-body"
                        && $0.sessionID == "page-committed"
                }
            } ? driver.store.entries.first { $0.url == "https://example.com/swap-request-body" } : nil
        )
        let locator = try #require(entry.requestBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .request)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected cross-target stable request body to adopt the authoritative target from requestWillBeSent")
            return
        }

        #expect(body.full == #"{"committed":true}"#)
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Network.GetRequestPostData.method
                    && $0.targetIdentifier == "page-committed"
            }
        )

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverRebindsStableBootstrapRowsWhenCommittedTargetOnlyEmitsFinish() async {
        let backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Network.GetBootstrapSnapshot.method else {
                    return nil
                }
                return makeBootstrapSnapshotResultPayload(
                    resources: [
                        makeBootstrapResourcePayload(
                            bootstrapRowID: "target-swap-finish-only",
                            rawRequestID: "request-target-swap-finish-only",
                            ownerSessionID: "page-provisional",
                            frameID: "frame-main",
                            targetIdentifier: "page-provisional",
                            url: "https://example.com/swap-finish-only.js",
                            method: "GET",
                            requestType: "Script",
                            mimeType: "text/javascript",
                            phase: "inFlight"
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-target-swap-finish-only",
                "timestamp": 14.0,
                "metrics": [
                    "responseBodyBytesReceived": 64,
                    "responseBodyDecodedSize": 64,
                ],
            ],
            targetIdentifier: "page-committed"
        )

        #expect(await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/swap-finish-only.js" }
            guard let entry = matches.first else {
                return false
            }
            return matches.count == 1
                && entry.sessionID == "page-committed"
                && entry.phase == .completed
                && entry.encodedBodyLength == 64
        })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverUpdatesDeferredBodyLocatorWhenStableRowRebindsTargets() async throws {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, payload in
                switch method {
                case WITransportCommands.Network.GetBootstrapSnapshot.method:
                    return makeBootstrapSnapshotResultPayload(
                        resources: [
                            makeBootstrapResourcePayload(
                                bootstrapRowID: "target-swap-body",
                                rawRequestID: "request-target-swap-body",
                                ownerSessionID: "page-provisional",
                                frameID: "frame-main",
                                targetIdentifier: "page-provisional",
                                url: "https://example.com/body-swap.js",
                                method: "GET",
                                requestType: "Script",
                                mimeType: "text/javascript",
                                phase: "inFlight",
                                bodyFetchDescriptor: [
                                    "targetIdentifier": "page-provisional",
                                    "frameId": "frame-main",
                                    "url": "https://example.com/body-swap.js",
                                ]
                            ),
                        ]
                    )
                case WITransportCommands.Page.GetResourceContent.method:
                    let params = payload["params"] as? [String: Any]
                    let frameID = params?["frameId"] as? String
                    let url = params?["url"] as? String
                    guard frameID == "frame-main", url == "https://example.com/body-swap.js" else {
                        return nil
                    }
                    return [
                        "content": "console.log('rebound body');",
                        "base64Encoded": false,
                    ]
                default:
                    return nil
                }
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-target-swap-body",
                "timestamp": 14.0,
                "metrics": [:],
            ],
            targetIdentifier: "page-committed"
        )

        let entry = try #require(
            await waitForCondition {
                driver.store.entries.contains {
                    $0.url == "https://example.com/body-swap.js"
                        && $0.sessionID == "page-committed"
                        && $0.phase == .completed
                }
            } ? driver.store.entries.first { $0.url == "https://example.com/body-swap.js" } : nil
        )
        let locator = try #require(entry.responseBody?.deferredLocator)
        let fetched = await driver.fetchBodyResult(locator: locator, role: .response)

        guard case .fetched(let body) = fetched else {
            Issue.record("Expected rebound bootstrap body to stay fetchable")
            return
        }

        #expect(body.full == "console.log('rebound body');")
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportCommands.Page.GetResourceContent.method
                    && $0.targetIdentifier == "page-committed"
            }
        )

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverDisambiguatesCrossTargetRebindsByURL() async {
        let backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Network.GetBootstrapSnapshot.method else {
                    return nil
                }
                return makeBootstrapSnapshotResultPayload(
                    resources: [
                        makeBootstrapResourcePayload(
                            bootstrapRowID: "first-shared-id",
                            rawRequestID: "shared-request-id",
                            ownerSessionID: "page-provisional",
                            frameID: "frame-main",
                            targetIdentifier: "page-provisional",
                            url: "https://example.com/first.js",
                            method: "UNKNOWN",
                            requestType: "Script",
                            mimeType: "text/javascript",
                            phase: "inFlight"
                        ),
                        makeBootstrapResourcePayload(
                            bootstrapRowID: "second-shared-id",
                            rawRequestID: "shared-request-id",
                            ownerSessionID: "page-child",
                            frameID: "frame-child",
                            targetIdentifier: "page-child",
                            url: "https://example.com/second.js",
                            method: "UNKNOWN",
                            requestType: "Script",
                            mimeType: "text/javascript",
                            phase: "inFlight"
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "shared-request-id",
                "timestamp": 21.0,
                "type": "Script",
                "request": [
                    "url": "https://example.com/first.js",
                    "method": "GET",
                    "headers": [:],
                ],
            ],
            targetIdentifier: "page-committed"
        )

        #expect(await waitForCondition {
            let firstMatch = driver.store.entries.first { $0.url == "https://example.com/first.js" }
            let secondMatch = driver.store.entries.first { $0.url == "https://example.com/second.js" }
            return firstMatch?.sessionID == "page-committed"
                && secondMatch?.sessionID == "page-child"
                && driver.store.entries.filter { $0.url == "https://example.com/first.js" }.count == 1
                && driver.store.entries.filter { $0.url == "https://example.com/second.js" }.count == 1
        })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverFallsBackToLiveIngressWhenResourceTreeBootstrapFails() async {
        let backend = FakeRegistryBackend(
            pageMethodErrors: [WITransportCommands.Page.GetResourceTree.method: "Page.getResourceTree unavailable"]
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-live",
                "timestamp": 1.0,
                "type": "Fetch",
                "request": [
                    "url": "https://example.com/live.json",
                    "method": "GET",
                    "headers": [:],
                ],
            ]
        )

        #expect(await waitForCondition {
            driver.store.entries.contains {
                $0.url == "https://example.com/live.json"
                    && $0.method == "GET"
            }
        })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverFallsBackToResourceTreeWhenStableBootstrapFails() async {
        let backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageMethodErrors: [WITransportCommands.Network.GetBootstrapSnapshot.method: "Network.getBootstrapSnapshot unavailable"],
            pageResultProvider: { method, _ in
                guard method == WITransportCommands.Page.GetResourceTree.method else {
                    return nil
                }
                return makeResourceTreeResultPayload(
                    mainURL: "https://example.com/",
                    resources: [
                        makeFrameResourcePayload(
                            url: "https://example.com/app.js",
                            type: "Script",
                            mimeType: "text/javascript"
                        ),
                    ]
                )
            }
        )
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(await waitForCondition {
            driver.store.entries.contains {
                $0.url == "https://example.com/app.js"
                    && $0.requestType == "Script"
                    && $0.phase == .completed
            }
        })

        driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverCapturesRequestsFromPrewarmedProvisionalTargetBeforeCommit() async {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let driver = NetworkTransportDriver(registry: registry)
        let webView = makeIsolatedTestWebView()

        driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(await waitForCondition {
            backend.sentPageTargets.filter { $0.method == "Network.enable" }.map(\.targetIdentifier) == ["page-A"]
        })

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-B",
                    "type": "page",
                    "isProvisional": true,
                ],
            ]
        )

        #expect(await waitForCondition {
            backend.sentPageTargets.filter { $0.method == "Network.enable" }.map(\.targetIdentifier) == ["page-A", "page-B"]
        })

        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-early",
                "timestamp": 1.0,
                "type": "Document",
                "request": [
                    "url": "https://example.org/",
                    "method": "GET",
                    "headers": [:],
                ],
            ],
            targetIdentifier: "page-B"
        )

        #expect(await waitForCondition {
            driver.store.entries.contains {
                $0.sessionID == "page-B"
                    && $0.url == "https://example.org/"
                    && $0.method == "GET"
            }
        })

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
    func networkIngressPrewarmsProvisionalPageTargetWithoutDuplicatingCommitEnable() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let lease = registry.acquireLease(for: webView)
        let consumerID = UUID()
        lease.addNetworkConsumer(consumerID) { _ in }

        try await lease.ensureNetworkEventIngress()
        #expect(backend.sentPageTargets.filter { $0.method == "Network.enable" }.map(\.targetIdentifier) == ["page-A"])

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-B",
                    "type": "page",
                    "isProvisional": true,
                ],
            ]
        )

        #expect(await waitForCondition {
            backend.sentPageTargets.filter { $0.method == "Network.enable" }.map(\.targetIdentifier) == ["page-A", "page-B"]
        })

        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-A",
                "newTargetId": "page-B",
            ]
        )

        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(backend.sentPageTargets.filter { $0.method == "Network.enable" }.map(\.targetIdentifier) == ["page-A", "page-B"])

        lease.removeNetworkConsumer(consumerID)
        lease.release()
    }

    @Test
    func domIngressEnablesCommittedProvisionalTargetImmediatelyAfterCommit() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let lease = registry.acquireLease(for: webView)
        let consumerID = UUID()
        lease.addDOMConsumer(consumerID) { _ in }

        try await lease.ensureDOMEventIngress()
        #expect(backend.sentPageTargets.filter { $0.method == "DOM.enable" }.map(\.targetIdentifier) == ["page-A"])

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-B",
                    "type": "page",
                    "isProvisional": true,
                ],
            ]
        )

        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-A",
                "newTargetId": "page-B",
            ]
        )

        #expect(await waitForCondition {
            backend.sentPageTargets.filter { $0.method == "DOM.enable" }.map(\.targetIdentifier) == ["page-A", "page-B"]
        })

        lease.removeDOMConsumer(consumerID)
        lease.release()
    }

    @Test
    func destroyedTargetClearsNetworkEnableStateForReusedIdentifier() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let lease = registry.acquireLease(for: webView)
        let consumerID = UUID()
        lease.addNetworkConsumer(consumerID) { _ in }

        try await lease.ensureNetworkEventIngress()

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-B",
                    "type": "page",
                    "isProvisional": true,
                ],
            ]
        )

        #expect(await waitForCondition {
            backend.sentPageTargets.filter { $0.method == "Network.enable" }.map(\.targetIdentifier) == ["page-A", "page-B"]
        })

        backend.emitRootEvent(
            method: "Target.targetDestroyed",
            params: [
                "targetId": "page-B",
            ]
        )

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-B",
                    "type": "page",
                    "isProvisional": true,
                ],
            ]
        )

        #expect(await waitForCondition {
            backend.sentPageTargets.filter { $0.method == "Network.enable" }.map(\.targetIdentifier) == ["page-A", "page-B", "page-B"]
        })

        lease.removeNetworkConsumer(consumerID)
        lease.release()
    }

    @Test
    func destroyedCurrentTargetReenablesDOMOnFallbackTargetImmediately() async throws {
        let backend = FakeRegistryBackend()
        let registry = makeRegistry(using: backend)
        let webView = makeIsolatedTestWebView()

        let lease = registry.acquireLease(for: webView)
        let consumerID = UUID()
        lease.addDOMConsumer(consumerID) { _ in }

        try await lease.ensureDOMEventIngress()

        backend.emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": "page-B",
                    "type": "page",
                    "isProvisional": false,
                ],
            ]
        )

        #expect(await waitForCondition {
            backend.sentPageTargets.filter { $0.method == "DOM.enable" }.map(\.targetIdentifier) == ["page-A", "page-B"]
        })

        backend.emitRootEvent(
            method: "Target.targetDestroyed",
            params: [
                "targetId": "page-B",
            ]
        )

        #expect(await waitForCondition {
            backend.sentPageTargets.filter { $0.method == "DOM.enable" }.map(\.targetIdentifier) == ["page-A", "page-B", "page-A"]
        })

        lease.removeDOMConsumer(consumerID)
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

    var supportSnapshot: WITransportSupportSnapshot

    private(set) var attachCallCount = 0
    private(set) var detachCallCount = 0
    private(set) var sentPageMethods: [String] = []
    private(set) var sentPageTargets: [SentPageTarget] = []
    private(set) var sentPagePayloads: [[String: Any]] = []
    private(set) var documentDepthRequests: [Int] = []
    private var messageHandlers: WITransportBackendMessageHandlers?
    private var ownsWebKitTestIsolation = false
    private let pageMethodErrors: [String: String]
    fileprivate var pageResultProvider: ((String, [String: Any]) -> [String: Any]?)?
    fileprivate var pageTargetedResultProvider: ((String, [String: Any], String) -> [String: Any]?)?

    init(
        capabilities: Set<WITransportCapability> = [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain],
        pageMethodErrors: [String: String] = [:],
        pageResultProvider: ((String, [String: Any]) -> [String: Any]?)? = nil,
        pageTargetedResultProvider: ((String, [String: Any], String) -> [String: Any]?)? = nil
    ) {
        supportSnapshot = WITransportSupportSnapshot.supported(
            backendKind: .macOSNativeInspector,
            capabilities: capabilities
        )
        self.pageMethodErrors = pageMethodErrors
        self.pageResultProvider = pageResultProvider
        self.pageTargetedResultProvider = pageTargetedResultProvider
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
               let result = pageTargetedResultProvider?(method, payload, targetIdentifier)
                    ?? pageResultProvider?(method, payload),
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

    func emitPageEvent(method: String, params: [String: Any], targetIdentifier: String = "page-A") {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params),
              let paramsString = String(data: data, encoding: .utf8)
        else {
            Issue.record("Failed to encode fake page event params for \(method)")
            return
        }

        messageHandlers?.handlePageMessage(
            #"{"method":"\#(method)","params":\#(paramsString)}"#,
            targetIdentifier
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

private func makeResourceTreeResultPayload(
    mainURL: String,
    resources: [[String: Any]],
    frameID: String = "frame-main",
    loaderID: String = "loader-main",
    childFrames: [[String: Any]] = []
) -> [String: Any] {
    var frameTree: [String: Any] = [
        "frame": [
            "id": frameID,
            "loaderId": loaderID,
            "url": mainURL,
            "securityOrigin": "https://example.com",
            "mimeType": "text/html",
        ],
        "resources": resources,
    ]
    if !childFrames.isEmpty {
        frameTree["childFrames"] = childFrames
    }
    return ["frameTree": frameTree]
}

private func makeFrameResourcePayload(
    url: String,
    type: String,
    mimeType: String,
    failed: Bool? = nil,
    canceled: Bool? = nil,
    targetId: String? = nil
) -> [String: Any] {
    var payload: [String: Any] = [
        "url": url,
        "type": type,
        "mimeType": mimeType,
    ]
    if let failed {
        payload["failed"] = failed
    }
    if let canceled {
        payload["canceled"] = canceled
    }
    if let targetId {
        payload["targetId"] = targetId
    }
    return payload
}

private func makeBootstrapSnapshotResultPayload(
    resources: [[String: Any]]
) -> [String: Any] {
    ["resources": resources]
}

private func makeBootstrapResourcePayload(
    bootstrapRowID: String,
    rawRequestID: String? = nil,
    ownerSessionID: String,
    frameID: String? = nil,
    targetIdentifier: String? = nil,
    url: String,
    method: String,
    requestType: String,
    mimeType: String,
    statusCode: Int? = nil,
    statusText: String? = nil,
    phase: String,
    requestHeaders: [String: String] = [:],
    responseHeaders: [String: String] = [:],
    canceled: Bool? = nil,
    errorDescription: String? = nil,
    bodyFetchDescriptor: [String: Any]? = nil
) -> [String: Any] {
    var payload: [String: Any] = [
        "bootstrapRowID": bootstrapRowID,
        "ownerSessionID": ownerSessionID,
        "url": url,
        "method": method,
        "requestType": requestType,
        "mimeType": mimeType,
        "phase": phase,
        "requestHeaders": requestHeaders,
        "responseHeaders": responseHeaders,
    ]
    if let rawRequestID {
        payload["rawRequestID"] = rawRequestID
    }
    if let frameID {
        payload["frameID"] = frameID
    }
    if let targetIdentifier {
        payload["targetIdentifier"] = targetIdentifier
    }
    if let statusCode {
        payload["statusCode"] = statusCode
    }
    if let statusText {
        payload["statusText"] = statusText
    }
    if let canceled {
        payload["canceled"] = canceled
    }
    if let errorDescription {
        payload["errorDescription"] = errorDescription
    }
    if let bodyFetchDescriptor {
        payload["bodyFetchDescriptor"] = bodyFetchDescriptor
    }
    return payload
}
