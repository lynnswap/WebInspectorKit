import Foundation
import Testing
import WebKit
import WebInspectorTestSupport
@testable import WebInspectorEngine
@testable import WebInspectorTransport

@MainActor
@Suite(.serialized, .webKitIsolated)
struct NetworkTransportDriverTests {
    @Test
    func sameWebViewSharesSingleTransportAttachmentAcrossLeases() async throws {
        let backend = FakeRegistryBackend()
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()
        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(backend.attachCallCount == 1)

        await driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func sharedTransportUsesSingleAttachmentAcrossDomAndNetworkClients() async {
        let backend = FakeRegistryBackend()
        let sharedTransport = WISharedInspectorTransport(
            sessionFactory: makeTransportSessionFactory(using: backend)
        )
        let webView = makeIsolatedTestWebView()

        await sharedTransport.attach(client: .dom, to: webView)
        await sharedTransport.attach(client: .network, to: webView)
        await sharedTransport.waitForAttachForTesting()

        #expect(backend.attachCallCount == 1)

        await sharedTransport.suspend(client: .dom)
        #expect(backend.detachCallCount == 0)

        await sharedTransport.detach(client: .network)
        #expect(backend.detachCallCount == 1)
    }

    @Test
    func networkTransportDriverFetchesDeferredRequestBodiesFromOwningTarget() async {
        let backend = FakeRegistryBackend(
            pageTargetedResultProvider: { method, _, targetIdentifier in
                guard method == WITransportMethod.Network.getRequestPostData,
                      targetIdentifier == "page-child" else {
                    return nil
                }
                return ["postData": "targeted=value"]
            }
        )
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let session = WINetworkRuntime(configuration: .init(), backend: driver)
        let webView = makeIsolatedTestWebView()

        await session.attach(pageWebView: webView)

        #expect(await waitForCondition {
            backend.sentPageMethods.contains(WITransportMethod.Network.enable)
        })

        let body = await session.fetchBody(
            locator: .networkRequest(id: "request-1", targetIdentifier: "page-child"),
            role: .request
        )

        #expect(body?.role == .request)
        #expect(body?.full == "targeted=value")
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportMethod.Network.getRequestPostData
                    && $0.targetIdentifier == "page-child"
            }
        )

        await session.detach()
    }

    @Test
    func stableBootstrapMethodNotFoundDisablesFurtherAttemptsOnSameSession() async throws {
        let backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageTargetedResultProvider: { method, _, _ in
                guard method == WITransportMethod.Page.getResourceTree else {
                    return nil
                }
                return makeResourceTreeResultPayload(
                    mainURL: "https://example.com/",
                    resources: []
                )
            },
            pageErrorResponseProvider: { method, _, _ in
                guard method == WITransportMethod.Network.getBootstrapSnapshot else {
                    return nil
                }
                return "'Network.getBootstrapSnapshot' was not found"
            }
        )
        let session = makeTransportSessionFactory(using: backend)()
        let transportClient = NetworkTransportClient()
        let webView = makeIsolatedTestWebView()

        try await session.attach(to: webView)

        let firstLoad = try await transportClient.loadBootstrapResources(
            using: session,
            targetIdentifier: "page-A",
            allocateRequestID: { 1 },
            defaultSessionID: { $0 ?? "page-A" },
            normalizeScopeID: { $0 },
            logFailure: { _ in }
        )
        let secondLoad = try await transportClient.loadBootstrapResources(
            using: session,
            targetIdentifier: "page-A",
            allocateRequestID: { 1 },
            defaultSessionID: { $0 ?? "page-A" },
            normalizeScopeID: { $0 },
            logFailure: { _ in }
        )

        #expect(firstLoad.snapshots.count == 1)
        #expect(secondLoad.snapshots.count == 1)
        #expect(backend.sentPageTargets.filter { $0.method == WITransportMethod.Network.getBootstrapSnapshot }.count == 1)
        #expect(backend.sentPageTargets.filter { $0.method == WITransportMethod.Page.getResourceTree }.count == 2)

        session.detach()
    }

    @Test
    func networkTransportDriverBootstrapsExistingResourcesFromResourceTreeOnAttach() async throws {
        let backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportMethod.Page.getResourceTree else {
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
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(backend.sentPageMethods.contains(WITransportMethod.Page.getResourceTree))
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

        let scriptEntry = try #require(driver.store.entries.first { $0.url == "https://example.com/app.js" })
        let locator = try #require(scriptEntry.responseBody?.deferredLocator)

        backend.pageTargetedResultProvider = { method, _, targetIdentifier in
            guard method == WITransportMethod.Page.getResourceContent,
                  targetIdentifier == "page-A" else {
                return nil
            }
            return [
                "content": "console.log('bootstrap');",
                "base64Encoded": false,
            ]
        }

        let fetched = await driver.fetchBodyResult(locator: locator, role: .response)
        guard case .fetched(let body) = fetched else {
            Issue.record("Expected bootstrapped resource content to be fetched via Page.getResourceContent")
            return
        }

        #expect(body.full == "console.log('bootstrap');")
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportMethod.Page.getResourceContent
                    && $0.targetIdentifier == "page-A"
            }
        )

        await driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverRetriesAttachAfterTransientFailureOnSameWebView() async {
        let backend = FakeRegistryBackend(failingAttachCount: 1)
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(backend.attachCallCount == 1)

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(backend.attachCallCount == 2)

        await driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverKeepsTransportAliveWhenInitialPageTargetArrivesLate() async {
        let backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportMethod.Page.getResourceTree else {
                    return nil
                }
                return makeResourceTreeResultPayload(
                    mainURL: "https://example.com/",
                    resources: [
                        makeFrameResourcePayload(
                            url: "https://example.com/late.js",
                            type: "Script",
                            mimeType: "text/javascript"
                        ),
                    ]
                )
            },
            attachHandler: { _ in }
        )
        let driver = NetworkTransportDriver(
            transportSessionFactory: makeTransportSessionFactory(
                using: backend,
                configuration: .init(responseTimeout: .milliseconds(25))
            )
        )
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(backend.attachCallCount == 1)
        #expect(backend.detachCallCount == 0)

        backend.emitPageTargetCreated(
            identifier: "page-late",
            isProvisional: false
        )

        let recoveredWithoutReattach = await waitForCondition {
            backend.attachCallCount == 1
                && backend.detachCallCount == 0
                && backend.sentPageTargets.contains {
                    $0.method == WITransportMethod.Network.enable
                        && $0.targetIdentifier == "page-late"
                }
                && backend.sentPageTargets.contains {
                    $0.method == WITransportMethod.Page.getResourceTree
                        && $0.targetIdentifier == "page-late"
                }
                && driver.store.entries.contains { entry in
                    entry.url == "https://example.com/late.js"
                        && entry.phase == .completed
                }
        }
        if !recoveredWithoutReattach {
            let snapshot = driver.store.entries.map {
                "\($0.url)|session=\($0.sessionID)|phase=\($0.phase.rawValue)|status=\($0.statusCode.map(String.init) ?? "nil")|bytes=\($0.encodedBodyLength.map(String.init) ?? "nil")"
            }
            Issue.record(
                """
                late target recovery snapshot:
                sentTargets=\(backend.sentPageTargets)
                store=\(snapshot)
                """
            )
        }
        #expect(recoveredWithoutReattach)

        await driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverReconnectsUsingReplacementWebView() async {
        let backend = FakeRegistryBackend()
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let session = NetworkSession(configuration: .init(), backend: driver)
        let firstWebView = makeIsolatedTestWebView()
        let secondWebView = makeIsolatedTestWebView()

        await session.attach(pageWebView: firstWebView)
        await driver.waitForAttachForTesting()

        session.prepareForNavigationReconnect()
        session.resumeAfterNavigationReconnect(to: secondWebView)
        await driver.waitForAttachForTesting()

        #expect(driver.webView === secondWebView)
        #expect(
            backend.attachedWebViewIDs == [
                ObjectIdentifier(firstWebView),
                ObjectIdentifier(secondWebView),
            ]
        )

        await session.detach()
    }

    @Test
    func networkTransportDriverUsesSurvivingPageTargetAfterAttachChurn() async {
        let backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportMethod.Page.getResourceTree else {
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
            },
            attachHandler: { messageSink in
                messageSink.didReceiveRootMessage(
                    #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-A","type":"page","isProvisional":false}}}"#
                )
                messageSink.didReceiveRootMessage(
                    #"{"method":"Target.targetDestroyed","params":{"targetId":"page-A"}}"#
                )
                messageSink.didReceiveRootMessage(
                    #"{"method":"Target.targetCreated","params":{"targetInfo":{"targetId":"page-B","type":"page","isProvisional":false}}}"#
                )
                await messageSink.waitForPendingMessages()
            }
        )
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportMethod.Network.enable
                    && $0.targetIdentifier == "page-B"
            }
        )
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportMethod.Page.getResourceTree
                    && $0.targetIdentifier == "page-B"
            }
        )
        #expect(
            !backend.sentPageTargets.contains {
                $0.method == WITransportMethod.Page.getResourceTree
                    && $0.targetIdentifier == "page-A"
            }
        )

        await driver.detachPageWebView(preparing: NetworkLoggingMode.stopped)
    }

    @Test
    func networkTransportDriverRetriesInitialTargetEnableWhenReplacementEventsDrainLater() async {
        var backend: FakeRegistryBackend!
        var shouldFailInitialEnable = true
        backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportMethod.Page.getResourceTree else {
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
            },
            pageTargetedResultProvider: { method, _, targetIdentifier in
                guard shouldFailInitialEnable,
                      method == WITransportMethod.Network.enable,
                      targetIdentifier == "page-A" else {
                    return nil
                }
                shouldFailInitialEnable = false
                Task { @MainActor [backend] in
                    guard let backend else {
                        return
                    }
                    backend.emitRootEvent(
                        method: "Target.targetDestroyed",
                        params: ["targetId": "page-A"]
                    )
                    backend.emitRootEvent(
                        method: "Target.targetCreated",
                        params: [
                            "targetInfo": [
                                "targetId": "page-B",
                                "type": "page",
                                "isProvisional": false,
                            ]
                        ]
                    )
                }
                throw WITransportError.remoteError(
                    scope: .root,
                    method: "Target.sendMessageToTarget",
                    message: "target closed"
                )
            }
        )
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportMethod.Network.enable
                    && $0.targetIdentifier == "page-B"
            }
        )
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportMethod.Page.getResourceTree
                    && $0.targetIdentifier == "page-B"
            }
        )

        await driver.detachPageWebView(preparing: NetworkLoggingMode.stopped)
    }

    @Test
    func networkTransportDriverRechecksCurrentTargetAfterSuccessfulEnableBeforeBootstrap() async {
        var backend: FakeRegistryBackend!
        var shouldReplaceTargetAfterInitialEnable = true
        backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportMethod.Page.getResourceTree else {
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
            },
            pageTargetedResultProvider: { method, _, targetIdentifier in
                guard shouldReplaceTargetAfterInitialEnable,
                      method == WITransportMethod.Network.enable,
                      targetIdentifier == "page-A" else {
                    return nil
                }
                shouldReplaceTargetAfterInitialEnable = false
                Task { @MainActor [backend] in
                    guard let backend else {
                        return
                    }
                    backend.emitRootEvent(
                        method: "Target.targetDestroyed",
                        params: ["targetId": "page-A"]
                    )
                    backend.emitRootEvent(
                        method: "Target.targetCreated",
                        params: [
                            "targetInfo": [
                                "targetId": "page-B",
                                "type": "page",
                                "isProvisional": false,
                            ]
                        ]
                    )
                }
                return [:]
            }
        )
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportMethod.Network.enable
                    && $0.targetIdentifier == "page-B"
            }
        )
        #expect(
            backend.sentPageTargets.contains {
                $0.method == WITransportMethod.Page.getResourceTree
                    && $0.targetIdentifier == "page-B"
            }
        )
        #expect(
            !backend.sentPageTargets.contains {
                $0.method == WITransportMethod.Page.getResourceTree
                    && $0.targetIdentifier == "page-A"
            }
        )

        await driver.detachPageWebView(preparing: NetworkLoggingMode.stopped)
    }

    @Test
    func networkTransportDriverKeepsBootstrapAndLiveRequestsWhenSameURLStartsDuringBootstrap() async {
        var backend: FakeRegistryBackend!
        backend = FakeRegistryBackend(
            pageResultProvider: { method, _ in
                guard method == WITransportMethod.Page.getResourceTree else {
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
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        #expect(await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/poll.json" }
            return matches.count == 2
                && matches.contains { $0.method == "POST" }
                && matches.contains { $0.method == "UNKNOWN" }
        })

        await driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverKeepsIndependentTargetsWithMatchingRequestIDsSeparateWithoutCommitLineage() async {
        let backend = FakeRegistryBackend()
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-collision",
                "timestamp": 12.0,
                "type": "Fetch",
                "request": [
                    "url": "https://example.com/collision.json",
                    "method": "GET",
                    "headers": [:],
                ],
            ],
            targetIdentifier: "page-first"
        )
        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-collision",
                "timestamp": 13.0,
                "type": "Fetch",
                "request": [
                    "url": "https://example.com/collision.json",
                    "method": "GET",
                    "headers": [:],
                ],
            ],
            targetIdentifier: "page-second"
        )
        backend.emitPageEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": "request-collision",
                "timestamp": 14.0,
                "type": "Fetch",
                "response": [
                    "url": "https://example.com/collision.json",
                    "status": 201,
                    "statusText": "Created",
                    "headers": [:],
                    "mimeType": "application/json",
                ],
            ],
            targetIdentifier: "page-first"
        )
        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-collision",
                "timestamp": 15.0,
                "metrics": [
                    "responseBodyBytesReceived": 32,
                    "responseBodyDecodedSize": 32,
                ],
            ],
            targetIdentifier: "page-first"
        )
        backend.emitPageEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": "request-collision",
                "timestamp": 16.0,
                "type": "Fetch",
                "response": [
                    "url": "https://example.com/collision.json",
                    "status": 202,
                    "statusText": "Accepted",
                    "headers": [:],
                    "mimeType": "application/json",
                ],
            ],
            targetIdentifier: "page-second"
        )
        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-collision",
                "timestamp": 17.0,
                "metrics": [
                    "responseBodyBytesReceived": 64,
                    "responseBodyDecodedSize": 64,
                ],
            ],
            targetIdentifier: "page-second"
        )

        #expect(await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/collision.json" }
            guard matches.count == 2 else {
                return false
            }
            let sessions = Set(matches.map(\.sessionID))
            let statuses = Set(matches.compactMap(\.statusCode))
            let lengths = Set(matches.compactMap(\.encodedBodyLength))
            return sessions == ["page-first", "page-second"]
                && statuses == [201, 202]
                && lengths == [32, 64]
                && matches.allSatisfy { $0.phase == .completed }
        })

        await driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverRebindsLiveRequestsAcrossCommittedTargetLineage() async {
        let backend = FakeRegistryBackend()
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageTargetCreated(
            identifier: "page-provisional",
            isProvisional: true
        )
        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-live-target-swap",
                "timestamp": 12.0,
                "type": "Fetch",
                "request": [
                    "url": "https://example.com/live-target-swap.json",
                    "method": "GET",
                    "headers": [:],
                ],
            ],
            targetIdentifier: "page-provisional"
        )
        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-provisional",
                "newTargetId": "page-committed",
            ]
        )
        backend.emitPageEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": "request-live-target-swap",
                "timestamp": 13.0,
                "type": "Fetch",
                "response": [
                    "url": "https://example.com/live-target-swap.json",
                    "status": 200,
                    "statusText": "OK",
                    "headers": [:],
                    "mimeType": "application/json",
                ],
            ],
            targetIdentifier: "page-committed"
        )
        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-live-target-swap",
                "timestamp": 14.0,
                "metrics": [
                    "responseBodyBytesReceived": 64,
                    "responseBodyDecodedSize": 64,
                ],
            ],
            targetIdentifier: "page-committed"
        )

        #expect(await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/live-target-swap.json" }
            guard let entry = matches.first else {
                return false
            }
            return matches.count == 1
                && entry.sessionID == "page-committed"
                && entry.phase == .completed
                && entry.statusCode == 200
                && entry.encodedBodyLength == 64
        })

        await driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverDefersLiveContinuationUntilCommitArrives() async {
        let backend = FakeRegistryBackend()
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageTargetCreated(
            identifier: "page-provisional",
            isProvisional: true
        )
        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-precommit-continuation",
                "timestamp": 12.0,
                "type": "Fetch",
                "request": [
                    "url": "https://example.com/precommit-continuation.json",
                    "method": "GET",
                    "headers": [:],
                ],
            ],
            targetIdentifier: "page-provisional"
        )
        backend.emitPageEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": "request-precommit-continuation",
                "timestamp": 13.0,
                "type": "Fetch",
                "response": [
                    "url": "https://example.com/precommit-continuation.json",
                    "status": 200,
                    "statusText": "OK",
                    "headers": [:],
                    "mimeType": "application/json",
                ],
            ],
            targetIdentifier: "page-committed"
        )

        #expect(await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/precommit-continuation.json" }
            guard let entry = matches.first else {
                return false
            }
            return matches.count == 1
                && entry.sessionID == "page-provisional"
                && entry.phase == .pending
                && entry.statusCode == nil
        })

        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-provisional",
                "newTargetId": "page-committed",
            ]
        )
        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-precommit-continuation",
                "timestamp": 14.0,
                "metrics": [
                    "responseBodyBytesReceived": 64,
                    "responseBodyDecodedSize": 64,
                ],
            ],
            targetIdentifier: "page-committed"
        )

        #expect(await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/precommit-continuation.json" }
            guard let entry = matches.first else {
                return false
            }
            return matches.count == 1
                && entry.sessionID == "page-committed"
                && entry.phase == .completed
                && entry.statusCode == 200
                && entry.encodedBodyLength == 64
        })

        await driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverDoesNotLetUnrelatedCommittedTargetStealProvisionalRequest() async {
        let backend = FakeRegistryBackend()
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitPageTargetCreated(
            identifier: "page-provisional",
            isProvisional: true
        )
        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-provisional-only",
                "timestamp": 12.0,
                "type": "Fetch",
                "request": [
                    "url": "https://example.com/provisional-only.json",
                    "method": "GET",
                    "headers": [:],
                ],
            ],
            targetIdentifier: "page-provisional"
        )
        backend.emitPageEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": "request-provisional-only",
                "timestamp": 13.0,
                "type": "Fetch",
                "response": [
                    "url": "https://example.com/provisional-only.json",
                    "status": 200,
                    "statusText": "OK",
                    "headers": [:],
                    "mimeType": "application/json",
                ],
            ],
            targetIdentifier: "page-unrelated"
        )
        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-provisional-only",
                "timestamp": 14.0,
                "metrics": [
                    "responseBodyBytesReceived": 64,
                    "responseBodyDecodedSize": 64,
                ],
            ],
            targetIdentifier: "page-unrelated"
        )

        #expect(await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/provisional-only.json" }
            guard let entry = matches.first else {
                return false
            }
            return matches.count == 1
                && entry.sessionID == "page-provisional"
                && entry.phase == .pending
                && entry.statusCode == nil
                && entry.encodedBodyLength == nil
        })

        await driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTimelineResolverClearsCommittedTargetLineageWhenBeginningNewContext() {
        let resolver = NetworkTimelineResolver()
        let store = NetworkStore()

        resolver.recordCommittedTargetTransition(
            from: "page-old",
            to: "page-new"
        )
        resolver.begin(contextID: UUID())

        _ = resolver.resolveRequestStart(
            sessionID: "page-old",
            rawRequestID: "request-lineage-reset",
            url: "https://example.com/lineage-reset.json",
            requestType: "Fetch",
            targetIdentifier: "page-old",
            store: store
        )

        let reboundRequestID = resolver.resolveEvent(
            sessionID: "page-new",
            rawRequestID: "request-lineage-reset",
            url: "https://example.com/lineage-reset.json",
            requestType: "Fetch",
            targetIdentifier: "page-new",
            store: store
        )

        #expect(reboundRequestID == nil)
    }

    @Test
    func networkTransportDriverReconnectClearsDeferredEnvelopesBeforeNextAttach() async {
        let backend = FakeRegistryBackend()
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let session = NetworkSession(configuration: .init(), backend: driver)
        let firstWebView = makeIsolatedTestWebView()
        let secondWebView = makeIsolatedTestWebView()

        await session.attach(pageWebView: firstWebView)
        await driver.waitForAttachForTesting()

        backend.emitPageTargetCreated(
            identifier: "page-provisional",
            isProvisional: true
        )
        backend.emitPageEvent(
            method: "Network.requestWillBeSent",
            params: [
                "requestId": "request-reconnect-clear",
                "timestamp": 12.0,
                "type": "Fetch",
                "request": [
                    "url": "https://example.com/reconnect-clear.json",
                    "method": "GET",
                    "headers": [:],
                ],
            ],
            targetIdentifier: "page-provisional"
        )
        backend.emitPageEvent(
            method: "Network.responseReceived",
            params: [
                "requestId": "request-reconnect-clear",
                "timestamp": 13.0,
                "type": "Fetch",
                "response": [
                    "url": "https://example.com/reconnect-clear.json",
                    "status": 200,
                    "statusText": "OK",
                    "headers": [:],
                    "mimeType": "application/json",
                ],
            ],
            targetIdentifier: "page-committed"
        )

        session.prepareForNavigationReconnect()
        session.resumeAfterNavigationReconnect(to: secondWebView)
        await driver.waitForAttachForTesting()

        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-provisional",
                "newTargetId": "page-committed",
            ]
        )
        backend.emitPageEvent(
            method: "Network.loadingFinished",
            params: [
                "requestId": "request-reconnect-clear",
                "timestamp": 14.0,
                "metrics": [
                    "responseBodyBytesReceived": 64,
                    "responseBodyDecodedSize": 64,
                ],
            ],
            targetIdentifier: "page-committed"
        )

        let reconnectClearedDeferred = await waitForCondition {
            let matches = driver.store.entries.filter { $0.url == "https://example.com/reconnect-clear.json" }
            return matches.allSatisfy { entry in
                entry.sessionID != "page-committed"
                    && entry.phase == .pending
                    && entry.statusCode == nil
                    && entry.encodedBodyLength == nil
            }
        }
        if !reconnectClearedDeferred {
            let snapshot = driver.store.entries.map {
                "\($0.url)|session=\($0.sessionID)|phase=\($0.phase.rawValue)|status=\($0.statusCode.map(String.init) ?? "nil")|bytes=\($0.encodedBodyLength.map(String.init) ?? "nil")"
            }
            Issue.record("reconnect clear snapshot: \(snapshot)")
        }
        #expect(reconnectClearedDeferred)

        await session.detach()
    }

    @Test
    func networkTransportDriverRebindsStableBootstrapRowsAcrossTargetChanges() async {
        let backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                guard method == WITransportMethod.Network.getBootstrapSnapshot else {
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
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-provisional",
                "newTargetId": "page-committed",
            ]
        )
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

        await driver.detachPageWebView(preparing: .stopped)
    }

    @Test
    func networkTransportDriverMatchesRedirectedStableContinuationByPreviousURL() async {
        let backend = FakeRegistryBackend(
            capabilities: [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain, .networkBootstrapSnapshot],
            pageResultProvider: { method, _ in
                guard method == WITransportMethod.Network.getBootstrapSnapshot else {
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
        let driver = NetworkTransportDriver(transportSessionFactory: makeTransportSessionFactory(using: backend))
        let webView = makeIsolatedTestWebView()

        await driver.attachPageWebView(webView)
        await driver.waitForAttachForTesting()

        backend.emitRootEvent(
            method: "Target.didCommitProvisionalTarget",
            params: [
                "oldTargetId": "page-provisional",
                "newTargetId": "page-committed",
            ]
        )
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

        let matchedRedirectEntries = await waitForCondition {
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
        }
        if !matchedRedirectEntries {
            let snapshot = driver.store.entries.map {
                "\($0.url)|session=\($0.sessionID)|phase=\($0.phase.rawValue)|status=\($0.statusCode.map(String.init) ?? "nil")|bytes=\($0.encodedBodyLength.map(String.init) ?? "nil")"
            }
            Issue.record("redirect continuity snapshot: \(snapshot)")
        }
        #expect(matchedRedirectEntries)

        await driver.detachPageWebView(preparing: .stopped)
    }
}

@MainActor
private extension NetworkTransportDriverTests {
    func makeTransportSessionFactory(
        using backend: FakeRegistryBackend,
        configuration: WITransportConfiguration = .init(responseTimeout: .seconds(1))
    ) -> @MainActor () -> WITransportSession {
        {
            let session = WITransportSession(
                configuration: configuration,
                backendFactory: { _ in backend }
            )
            session.derivedPageTargetIdentifierProviderForTesting = { _ in nil }
            return session
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
    private(set) var attachedWebViewIDs: [ObjectIdentifier] = []
    private(set) var sentPageMethods: [String] = []
    private(set) var sentPageTargets: [SentPageTarget] = []

    fileprivate var pageResultProvider: ((String, [String: Any]) throws -> [String: Any]?)?
    fileprivate var pageTargetedResultProvider: ((String, [String: Any], String) throws -> [String: Any]?)?
    fileprivate var pageErrorResponseProvider: ((String, [String: Any], String) throws -> String?)?
    private var failingAttachCount: Int
    private let attachHandler: ((any WITransportBackendMessageSink) async -> Void)?

    private var messageSink: (any WITransportBackendMessageSink)?
    private var ownsWebKitTestIsolation = false

    init(
        capabilities: Set<WITransportCapability> = [.rootMessaging, .pageMessaging, .pageTargetRouting, .domDomain, .networkDomain],
        failingAttachCount: Int = 0,
        pageResultProvider: ((String, [String: Any]) throws -> [String: Any]?)? = nil,
        pageTargetedResultProvider: ((String, [String: Any], String) throws -> [String: Any]?)? = nil,
        pageErrorResponseProvider: ((String, [String: Any], String) throws -> String?)? = nil,
        attachHandler: ((any WITransportBackendMessageSink) async -> Void)? = nil
    ) {
        supportSnapshot = .supported(
            backendKind: .macOSNativeInspector,
            capabilities: capabilities
        )
        self.failingAttachCount = failingAttachCount
        self.pageResultProvider = pageResultProvider
        self.pageTargetedResultProvider = pageTargetedResultProvider
        self.pageErrorResponseProvider = pageErrorResponseProvider
        self.attachHandler = attachHandler
    }

    deinit {
        guard ownsWebKitTestIsolation else {
            return
        }
        Task { @MainActor in
            await releaseWebKitTestIsolation()
        }
    }

    func attach(to webView: WKWebView, messageSink: any WITransportBackendMessageSink) async throws {
        if isWebKitTestIsolationActive {
            ownsWebKitTestIsolation = false
        } else {
            await acquireWebKitTestIsolation()
            ownsWebKitTestIsolation = true
        }
        attachCallCount += 1
        attachedWebViewIDs.append(ObjectIdentifier(webView))
        if failingAttachCount > 0 {
            failingAttachCount -= 1
            throw WITransportError.attachFailed("simulated attach failure")
        }
        self.messageSink = messageSink
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
        detachCallCount += 1
        messageSink = nil
        guard ownsWebKitTestIsolation else {
            return
        }
        ownsWebKitTestIsolation = false
        Task { @MainActor in
            await releaseWebKitTestIsolation()
        }
    }

    func sendRootMessage(_ message: String) throws {
        _ = message
    }

    func sendPageMessage(_ message: String, targetIdentifier: String, outerIdentifier: Int) throws {
        _ = outerIdentifier
        let payload = try decodeMessagePayload(message)
        guard let method = payload["method"] as? String else {
            return
        }
        sentPageMethods.append(method)
        sentPageTargets.append(SentPageTarget(method: method, targetIdentifier: targetIdentifier))

        guard let identifier = payload["id"] as? Int else {
            return
        }

        if let errorMessage = try pageErrorResponseProvider?(method, payload, targetIdentifier) {
            messageSink?.didReceivePageMessage(
                #"{"id":\#(identifier),"error":{"message":"\#(errorMessage)"}}"#,
                targetIdentifier: targetIdentifier
            )
            return
        }

        let result = try pageTargetedResultProvider?(method, payload, targetIdentifier)
            ?? pageResultProvider?(method, payload)
            ?? [:]

        guard JSONSerialization.isValidJSONObject(result),
              let data = try? JSONSerialization.data(withJSONObject: result),
              let resultString = String(data: data, encoding: .utf8) else {
            messageSink?.didReceivePageMessage(
                #"{"id":\#(identifier),"result":{}}"#,
                targetIdentifier: targetIdentifier
            )
            return
        }

        messageSink?.didReceivePageMessage(
            #"{"id":\#(identifier),"result":\#(resultString)}"#,
            targetIdentifier: targetIdentifier
        )
    }

    func compatibilityResponse(scope: WITransportTargetScope, method: String) -> Data? {
        _ = scope
        _ = method
        return nil
    }

    func emitPageEvent(method: String, params: [String: Any], targetIdentifier: String = "page-A") {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params),
              let paramsString = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to encode fake page event params for \(method)")
            return
        }

        messageSink?.didReceivePageMessage(
            #"{"method":"\#(method)","params":\#(paramsString)}"#,
            targetIdentifier: targetIdentifier
        )
    }

    func emitRootEvent(method: String, params: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(params),
              let data = try? JSONSerialization.data(withJSONObject: params),
              let paramsString = String(data: data, encoding: .utf8) else {
            Issue.record("Failed to encode fake root event params for \(method)")
            return
        }

        messageSink?.didReceiveRootMessage(
            #"{"method":"\#(method)","params":\#(paramsString)}"#
        )
    }

    func emitPageTargetCreated(identifier: String, isProvisional: Bool) {
        emitRootEvent(
            method: "Target.targetCreated",
            params: [
                "targetInfo": [
                    "targetId": identifier,
                    "type": "page",
                    "isProvisional": isProvisional,
                ]
            ]
        )
    }

    private func decodeMessagePayload(_ message: String) throws -> [String: Any] {
        let data = Data(message.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }
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

private func makeBootstrapSnapshotResultPayload(resources: [[String: Any]]) -> [String: Any] {
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
