import Testing
import WebKit
@testable import WebInspectorEngine
@testable import WebInspectorBridge

private let bootstrapUserScriptMarker = "__wiDOMAgentBootstrapUserScript"

@MainActor
struct DOMSessionTests {
    @Test
    func detachClearsLastPageWebView() async {
        let session = DOMSession(configuration: .init(snapshotDepth: 3, subtreeDepth: 2))
        let (webView, _) = makeTestWebView()
        _ = await session.attach(to: webView)

        await session.detach()

        #expect(session.lastPageWebView == nil)
        #expect(session.pageWebView == nil)
    }

    @Test
    func beginSelectionModeWithoutWebViewThrows() async {
        let session = DOMSession(configuration: .init())
        do {
            _ = try await session.beginSelectionMode()
            #expect(Bool(false))
        } catch let error as WebInspectorCoreError {
            guard case .scriptUnavailable = error else {
                #expect(Bool(false))
                return
            }
        } catch {
            #expect(Bool(false))
        }
    }

    @Test
    func captureSnapshotWithoutWebViewThrows() async {
        let session = DOMSession(configuration: .init(snapshotDepth: 2))
        do {
            _ = try await session.captureSnapshot(maxDepth: 2)
            #expect(Bool(false))
        } catch let error as WebInspectorCoreError {
            guard case .scriptUnavailable = error else {
                #expect(Bool(false))
                return
            }
        } catch {
            #expect(Bool(false))
        }
    }

    @Test
    func captureSnapshotPreservesPendingInitialSnapshotMode() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 2))
        let (webView, _) = makeTestWebView()
        _ = await session.attach(to: webView)
        await loadHTML("<html><body><div id='target'></div></body></html>", in: webView)

        try await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM.nextInitialSnapshotMode = 'fresh';",
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )

        _ = try await session.captureSnapshot(maxDepth: 2)

        let status = await autoSnapshotStatus(on: webView)
        let nextInitialSnapshotMode =
            (status?["nextInitialSnapshotMode"] as? String)
            ?? (status?["nextInitialSnapshotMode"] as? NSString as String?)
        #expect(nextInitialSnapshotMode == "fresh")
    }

    @Test
    func captureSnapshotConsumesPendingInitialSnapshotModeWhenRequested() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 2))
        let (webView, _) = makeTestWebView()
        _ = await session.attach(to: webView)
        await loadHTML("<html><body><div id='target'></div></body></html>", in: webView)

        try await webView.callAsyncVoidJavaScript(
            "window.webInspectorDOM.nextInitialSnapshotMode = 'fresh';",
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )

        _ = try await session.captureSnapshot(
            maxDepth: 2,
            initialModeOwnership: .consumePendingInitialMode
        )

        let status = await autoSnapshotStatus(on: webView)
        let nextInitialSnapshotMode =
            (status?["nextInitialSnapshotMode"] as? String)
            ?? (status?["nextInitialSnapshotMode"] as? NSString as String?)
        #expect(nextInitialSnapshotMode == nil)
    }

    @Test
    func attachRegistersHandlersAndInstallsUserScripts() async {
        let session = DOMSession(configuration: .init())
        let (webView, controller) = makeTestWebView()
        let bridgeWorld = WISPIContentWorldProvider.bridgeWorld()

        _ = await session.attach(to: webView)

        let addedHandlerNames = controller.addedHandlers.map(\.name)
        #expect(addedHandlerNames.contains("webInspectorDOMSnapshot"))
        #expect(addedHandlerNames.contains("webInspectorDOMMutations"))
        #expect(controller.addedHandlers.allSatisfy { $0.world == bridgeWorld })
        #expect(controller.userScripts.count == 3)
        #expect(controller.userScripts.contains { $0.source.contains(bootstrapUserScriptMarker) })
        #expect(controller.userScripts.contains { $0.source.contains("webInspectorDOM") })
    }

    @Test
    func reattachingSameWebViewDoesNotRequestReload() async {
        let session = DOMSession(configuration: .init())
        let (webView, _) = makeTestWebView()

        let firstAttach = await session.attach(to: webView)
        #expect(firstAttach.shouldReload == true)
        #expect(firstAttach.shouldPreserveInspectorState == false)

        let secondAttach = await session.attach(to: webView)

        #expect(secondAttach.shouldReload == false)
        #expect(secondAttach.shouldPreserveInspectorState == false)
    }

    @Test
    func reattachingSameWebViewRefreshesCachedPageContext() async throws {
        let session = DOMSession(configuration: .init())
        let (webView, _) = makeTestWebView()

        session.preparePageEpoch(1)
        session.prepareDocumentScopeID(2)
        _ = await session.attach(to: webView)
        await loadHTML("<html><body><div id='first'></div></body></html>", in: webView)
        await session.attach(to: webView)

        try await webView.callAsyncVoidJavaScript(
            """
            window.webInspectorDOM.setPageEpoch(5);
            window.webInspectorDOM.setDocumentScopeID(7);
            """,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )

        let secondAttach = await session.attach(to: webView)

        #expect(secondAttach.shouldReload == false)
        #expect(secondAttach.shouldPreserveInspectorState == false)
        #expect(secondAttach.observedPageContext?.pageEpoch == 5)
        #expect(secondAttach.observedPageContext?.documentScopeID == 7)
        #expect(session.testCachedPageEpoch == 5)
        #expect(session.testCachedDocumentScopeID == 7)
    }

    @Test
    func reattachingSameWebViewAdoptsObservedDocumentScopeWhenEpochAdvances() async throws {
        let session = DOMSession(configuration: .init())
        let (webView, _) = makeTestWebView()

        session.preparePageEpoch(4)
        session.prepareDocumentScopeID(8)
        _ = await session.attach(to: webView)
        await loadHTML("<html><body><div id='first'></div></body></html>", in: webView)
        await session.attach(to: webView)

        try await webView.callAsyncVoidJavaScript(
            """
            window.webInspectorDOM.setPageEpoch(5);
            window.webInspectorDOM.setDocumentScopeID(7);
            """,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )

        let secondAttach = await session.attach(to: webView)

        #expect(secondAttach.shouldReload == false)
        #expect(secondAttach.shouldPreserveInspectorState == false)
        #expect(secondAttach.observedPageContext?.pageEpoch == 5)
        #expect(secondAttach.observedPageContext?.documentScopeID == 7)
        #expect(session.testCachedPageEpoch == 5)
        #expect(session.testCachedDocumentScopeID == 7)
    }

    @Test
    func suspendRemovesHandlersAndClearsWebView() async {
        let session = DOMSession(configuration: .init())
        let (webView, controller) = makeTestWebView()
        let bridgeWorld = WISPIContentWorldProvider.bridgeWorld()

        _ = await session.attach(to: webView)
        let removedBefore = controller.removedHandlers.count

        await session.suspend()

        let removedHandlerNames = controller.removedHandlers.map(\.name)
        #expect(controller.removedHandlers.count > removedBefore)
        #expect(removedHandlerNames.contains("webInspectorDOMSnapshot"))
        #expect(removedHandlerNames.contains("webInspectorDOMMutations"))
        #expect(controller.removedHandlers.allSatisfy { $0.world == bridgeWorld })
        #expect(session.pageWebView == nil)
    }

    @Test
    func attachInstallsInspectorScriptIntoPage() async throws {
        let session = DOMSession(configuration: .init())
        let (webView, _) = makeTestWebView()

        _ = await session.attach(to: webView)
        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)

        let raw = try await webView.evaluateJavaScript(
            "(() => Boolean(window.webInspectorDOM && window.webInspectorDOM.__installed))();",
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        let installed = (raw as? Bool) ?? (raw as? NSNumber)?.boolValue ?? false
        #expect(installed == true)
    }

    @Test
    func attachInstallsBridgeWorldScriptWhenPageWorldProbeAlreadyExists() async throws {
        let session = DOMSession(configuration: .init())
        let (webView, controller) = makeTestWebView()
        controller.addUserScript(
            WKUserScript(
                source: "(function() { /* webInspectorDOM */ })();",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        _ = await session.attach(to: webView)
        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)

        let raw = try await webView.evaluateJavaScript(
            "(() => Boolean(window.webInspectorDOM && window.webInspectorDOM.__installed))();",
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        let installed = (raw as? Bool) ?? (raw as? NSNumber)?.boolValue ?? false
        #expect(installed == true)
    }

    @Test
    func pageEpochSyncClearsCachedHandles() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        await loadHTML("<html><body><div id='first'></div></body></html>", in: webView)
        await agent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 0)

        let handleCache = try #require(extractHandleCache(from: agent))
        handleCache.store(handle: NSObject(), for: 1)
        #expect(handleCache.handle(for: 1) != nil)

        await agent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 1)

        for _ in 0..<20 where handleCache.handle(for: 1) != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(handleCache.handle(for: 1) == nil)
    }

    @Test
    func commitPageContextIgnoresHashOnlyDocumentURLChanges() throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        agent.commitPageContext(
            .init(pageEpoch: 1, documentScopeID: 2, documentURL: "https://example.com/page#first"),
            on: webView
        )

        let handleCache = try #require(extractHandleCache(from: agent))
        handleCache.store(handle: NSObject(), for: 1)

        agent.commitPageContext(
            .init(pageEpoch: 1, documentScopeID: 2, documentURL: "https://example.com/page#second"),
            on: webView
        )

        #expect(handleCache.handle(for: 1) != nil)
        #expect(agent.currentPageContext.documentURL == "https://example.com/page")
    }

    @Test
    func stalePageEpochSyncDoesNotRegressNativeEpoch() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        await loadHTML("<html><body><div id='first'></div></body></html>", in: webView)

        await agent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 1)
        let firstSyncApplied = await waitForCondition {
            let jsEpoch = try? await currentDOMAgentPageEpoch(in: webView)
            return jsEpoch == 1 && extractPageEpoch(from: agent) == 1
        }
        #expect(firstSyncApplied == true)

        await agent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 0)
        let staleSyncDidNotRegress = await waitForCondition {
            let jsEpoch = try? await currentDOMAgentPageEpoch(in: webView)
            return jsEpoch == 1 && extractPageEpoch(from: agent) == 1
        }
        #expect(staleSyncDidNotRegress == true)
    }

    @Test
    func preparedPageContextAcceptsNewerPageStateWithoutSchedulingRetry() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        await loadHTML("<html><body><div id='first'></div></body></html>", in: webView)

        await agent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 3, documentScopeID: 5)
        let initialSyncApplied = await waitForCondition {
            let jsEpoch = try? await currentDOMAgentPageEpoch(in: webView)
            let jsScope = try? await currentDOMAgentDocumentScopeID(in: webView)
            return jsEpoch == 3 && jsScope == 5
        }
        #expect(initialSyncApplied == true)

        await agent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 1, documentScopeID: 2)

        #expect(agent.testHasPreparedPageContextSyncTask == false)
        #expect(agent.testCachedPageEpoch == 3)
        #expect(agent.testCachedDocumentScopeID == 5)
        #expect(try await currentDOMAgentPageEpoch(in: webView) == 3)
        #expect(try await currentDOMAgentDocumentScopeID(in: webView) == 5)
    }

    @Test
    func staleDocumentScopeSyncReturnsAfterNewerScopeIsApplied() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        await loadHTML("<html><body><div id='first'></div></body></html>", in: webView)
        await agent.ensureDOMAgentScriptInstalled(on: webView)
        await agent.syncDocumentScopeIDIfNeeded(2, on: webView)

        let staleSyncFinished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await agent.syncDocumentScopeIDIfNeeded(1, on: webView)
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        #expect(staleSyncFinished == true)
        #expect(extractDocumentScopeID(from: agent) == 2)
        #expect(try await currentDOMAgentDocumentScopeID(in: webView) == 2)
    }

    @Test
    func waitForPreparedPageContextSyncDiscardsCompletedStaleTask() async {
        let agent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: WIUserContentControllerStateRegistry.shared
        )

        agent.testInstallCompletedPreparedPageContextSyncTask(generation: 1)
        agent.testAdvancePageEpochApplyGenerationWithoutClearingTask()

        await agent.waitForPreparedPageContextSyncIfNeeded()
        #expect(agent.testHasPreparedPageContextSyncTask == false)
    }

    @Test
    func syncDocumentScopeAppliesPreparedScopeWhenPageRestoresOlderDocumentScope() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        agent.testSetCachedDocumentScopeID(4)
        agent.testPageContextFromPageOverride = { _ in
            .init(pageEpoch: 0, documentScopeID: 1)
        }
        var appliedScopeIDs: [UInt64] = []
        agent.testApplyDocumentScopeIDOverride = { documentScopeID, _ in
            appliedScopeIDs.append(documentScopeID)
            return true
        }

        let didSync = await agent.syncDocumentScopeIDIfNeeded(4, on: webView)

        #expect(didSync == true)
        #expect(extractDocumentScopeID(from: agent) == 4)
        #expect(appliedScopeIDs == [4])
    }

    @Test
    func syncDocumentScopeDoesNotWriteOlderScopeWhenRefreshIsUnavailable() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        await loadHTML("<html><body><div id='first'></div></body></html>", in: webView)
        await agent.ensureDOMAgentScriptInstalled(on: webView)
        await agent.syncDocumentScopeIDIfNeeded(3, on: webView)
        agent.testSetDocumentScopeSyncRetryLimitOverride(2)

        try await webView.callAsyncVoidJavaScript(
            """
            window.__domPageAgentTestsOriginalConsoleLog = console.log;
            console.log = function() {
                throw new Error("debugStatus unavailable");
            };
            """,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )

        let didSync = await agent.syncDocumentScopeIDIfNeeded(2, on: webView)

        try await webView.callAsyncVoidJavaScript(
            """
            if (window.__domPageAgentTestsOriginalConsoleLog) {
                console.log = window.__domPageAgentTestsOriginalConsoleLog;
            }
            delete window.__domPageAgentTestsOriginalConsoleLog;
            """,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )

        #expect(didSync == false)
        #expect(extractDocumentScopeID(from: agent) == 3)
        #expect(try await currentDOMAgentDocumentScopeID(in: webView) == 3)
    }

    @Test
    func syncDocumentScopeRefreshesStaleCachedScopeAfterRejectedApply() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        await loadHTML("<html><body><div id='first'></div></body></html>", in: webView)
        await agent.ensureDOMAgentScriptInstalled(on: webView)
        await agent.syncDocumentScopeIDIfNeeded(3, on: webView)
        agent.testSetCachedDocumentScopeID(1)
        #expect(try await currentDOMAgentDocumentScopeID(in: webView) == 3)
        #expect(extractDocumentScopeID(from: agent) == 1)

        let syncFinished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await agent.syncDocumentScopeIDIfNeeded(2, on: webView)
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        #expect(syncFinished == true)
        #expect(extractDocumentScopeID(from: agent) == 3)
        #expect(try await currentDOMAgentDocumentScopeID(in: webView) == 3)
    }

    @Test
    func staleExpectedPageEpochDoesNotApplyDocumentScopeToNewerPage() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        await loadHTML("<html><body><div id='first'></div></body></html>", in: webView)
        await agent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 1)
        await agent.syncDocumentScopeIDIfNeeded(3, on: webView)

        await agent.syncDocumentScopeIDIfNeeded(2, on: webView, expectedPageEpoch: 0)

        #expect(extractDocumentScopeID(from: agent) == 3)
        #expect(try await currentDOMAgentDocumentScopeID(in: webView) == 3)
    }

    @Test
    func syncDocumentScopeReturnsFalseWhenDOMAgentIsUnavailable() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        await loadHTML("<html><body><div id='first'></div></body></html>", in: webView)
        agent.testSetDocumentScopeSyncRetryLimitOverride(3)

        let didSync = await agent.syncDocumentScopeIDIfNeeded(1, on: webView)

        #expect(didSync == false)
        #expect(extractDocumentScopeID(from: agent) == 0)
    }

    @Test
    func attachAcceptsNewerPreparedPageContextAndMutationsDoNotWaitOnStaleSync() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let seedAgent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }
        let session = DOMSession(configuration: .init())
        let html = """
        <html>
            <body>
                <div id="target" class="before">Target</div>
            </body>
        </html>
        """

        seedAgent.attachPageWebView(webView)
        await loadHTML(html, in: webView)
        await seedAgent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 4, documentScopeID: 6)
        let seeded = await waitForCondition {
            let jsEpoch = try? await currentDOMAgentPageEpoch(in: webView)
            let jsScope = try? await currentDOMAgentDocumentScopeID(in: webView)
            return jsEpoch == 4 && jsScope == 6
        }
        #expect(seeded == true)

        session.preparePageEpoch(1)
        session.prepareDocumentScopeID(2)

        _ = await session.attach(to: webView)

        #expect(session.testHasPreparedPageContextSyncTask == false)
        #expect(session.testCachedPageEpoch == 4)
        #expect(session.testCachedDocumentScopeID == 6)
        #expect(try await currentDOMAgentPageEpoch(in: webView) == 4)
        #expect(try await currentDOMAgentDocumentScopeID(in: webView) == 6)

        let snapshot = try await session.captureSnapshot(maxDepth: 5)
        let nodeId = try #require(
            findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "target")
        )

        let mutationFinished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                matchesApplied(
                    await session.setAttribute(target: .local(UInt64(nodeId)), name: "class", value: "after")
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        #expect(mutationFinished == true)
        let didApplyMutation = await waitForCondition {
            await domAttributeValue(elementID: "target", attributeName: "class", in: webView) == "after"
        }
        #expect(didApplyMutation == true)
    }

    @Test
    func attachReappliesPreparedDocumentScopeUsingObservedPageEpochWhenPreparedPageEpochIsUnset() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let seedAgent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }
        let session = DOMSession(configuration: .init())

        seedAgent.attachPageWebView(webView)
        await loadHTML("<html><body><div id='target'></div></body></html>", in: webView)
        await seedAgent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 4, documentScopeID: 1)

        let seeded = await waitForCondition {
            let jsEpoch = try? await currentDOMAgentPageEpoch(in: webView)
            let jsScope = try? await currentDOMAgentDocumentScopeID(in: webView)
            return jsEpoch == 4 && jsScope == 1
        }
        #expect(seeded == true)

        session.prepareDocumentScopeID(6)

        _ = await session.attach(to: webView)

        #expect(session.testCachedPageEpoch == 4)
        #expect(session.testCachedDocumentScopeID == 6)
        #expect(try await currentDOMAgentPageEpoch(in: webView) == 4)
        #expect(try await currentDOMAgentDocumentScopeID(in: webView) == 6)
    }

    @Test
    func attachingSecondSessionToSameControllerDoesNotDuplicateScripts() async {
        let firstSession = DOMSession(configuration: .init())
        let secondSession = DOMSession(configuration: .init())
        let (webView, controller) = makeTestWebView()

        _ = await firstSession.attach(to: webView)
        let firstScriptCount = controller.userScripts.count
        #expect(firstScriptCount == 3)

        _ = await secondSession.attach(to: webView)

        #expect(controller.userScripts.count == firstScriptCount)
    }

    @Test
    func installFailureKeepsBridgeScriptMarkedInstalled() async {
        struct InstallFailure: Error {}

        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry,
            installDOMBridgeScript: { _, _, _ in
                throw InstallFailure()
            }
        )
        defer {
            registry.clearState(for: controller)
        }

        await agent.ensureDOMAgentScriptInstalled(on: webView)
        let firstScriptCount = controller.userScripts.count

        #expect(firstScriptCount == 3)
        #expect(registry.domBridgeScriptInstalled(on: controller) == true)

        await agent.ensureDOMAgentScriptInstalled(on: webView)

        #expect(controller.userScripts.count == firstScriptCount)
    }

    @Test
    func bootstrapRefreshReplacesExistingBootstrapUserScript() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(snapshotDepth: 5, subtreeDepth: 2, autoUpdateDebounce: 0.2),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)
        await agent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 1, documentScopeID: 2)

        let initialScriptCount = controller.userScripts.count
        #expect(initialScriptCount == 3)
        #expect(controller.userScripts.first?.source.contains(bootstrapUserScriptMarker) == true)

        await agent.setAutoSnapshot(enabled: true)
        #expect(controller.userScripts.count == initialScriptCount)
        #expect(controller.userScripts.first?.source.contains(bootstrapUserScriptMarker) == true)

        await agent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 3, documentScopeID: 4)
        #expect(controller.userScripts.count == initialScriptCount)
        #expect(controller.userScripts.first?.source.contains(bootstrapUserScriptMarker) == true)

        let bootstrapScripts = controller.userScripts.filter { $0.source.contains(bootstrapUserScriptMarker) }
        #expect(bootstrapScripts.count == 1)
    }

    @Test
    func setAutoSnapshotAfterAttachEventuallyConfiguresAgent() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 7, subtreeDepth: 2, autoUpdateDebounce: 0.2))
        let (webView, _) = makeTestWebView()

        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)
        _ = await session.attach(to: webView)
        await session.setAutoSnapshot(enabled: true)
        await waitForAutoSnapshotEnabled(on: webView)

        let rawStatus = try await webView.evaluateJavaScript(
            "(() => window.webInspectorDOM?.debugStatus?.() ?? null)();",
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        let status = rawStatus as? [String: Any]
        let enabled = (status?["snapshotAutoUpdateEnabled"] as? Bool)
            ?? (status?["snapshotAutoUpdateEnabled"] as? NSNumber)?.boolValue
            ?? false
        let maxDepth = (status?["snapshotAutoUpdateMaxDepth"] as? Int)
            ?? (status?["snapshotAutoUpdateMaxDepth"] as? NSNumber)?.intValue
        let debounce = (status?["snapshotAutoUpdateDebounce"] as? Int)
            ?? (status?["snapshotAutoUpdateDebounce"] as? NSNumber)?.intValue

        #expect(enabled == true)
        #expect(maxDepth == 7)
        #expect(debounce == 200)
    }

    @Test
    func tearDownForDeinitBestEffortDetachesAutoSnapshot() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 7, subtreeDepth: 2, autoUpdateDebounce: 0.2))
        let (webView, _) = makeTestWebView()

        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)
        _ = await session.attach(to: webView)
        await session.setAutoSnapshot(enabled: true)
        await waitForAutoSnapshotEnabled(on: webView)

        session.tearDownForDeinit()

        for _ in 0..<100 {
            let status = await autoSnapshotStatus(on: webView)
            let enabled = (status?["snapshotAutoUpdateEnabled"] as? Bool)
                ?? (status?["snapshotAutoUpdateEnabled"] as? NSNumber)?.boolValue
                ?? false
            if enabled == false {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let finalStatus = await autoSnapshotStatus(on: webView)
        let enabled = (finalStatus?["snapshotAutoUpdateEnabled"] as? Bool)
            ?? (finalStatus?["snapshotAutoUpdateEnabled"] as? NSNumber)?.boolValue
            ?? false

        #expect(enabled == false)
        #expect(session.pageWebView == nil)
    }

    @Test
    func setAutoSnapshotBeforeAttachEventuallyConfiguresAgent() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 5, subtreeDepth: 2, autoUpdateDebounce: 0.3))
        let (webView, _) = makeTestWebView()

        await session.setAutoSnapshot(enabled: true)
        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)
        _ = await session.attach(to: webView)
        await waitForAutoSnapshotEnabled(on: webView)

        let status = await autoSnapshotStatus(on: webView)
        let maxDepth = (status?["snapshotAutoUpdateMaxDepth"] as? Int)
            ?? (status?["snapshotAutoUpdateMaxDepth"] as? NSNumber)?.intValue
        let debounce = (status?["snapshotAutoUpdateDebounce"] as? Int)
            ?? (status?["snapshotAutoUpdateDebounce"] as? NSNumber)?.intValue

        #expect(maxDepth == 5)
        #expect(debounce == 300)
    }

    @Test
    func documentStartBootstrapRestoresPageContextAndAutoSnapshotAfterReload() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(snapshotDepth: 6, subtreeDepth: 2, autoUpdateDebounce: 0.18),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        await loadHTML("<html><body><p>first</p></body></html>", in: webView)
        await agent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 3, documentScopeID: 5)
        await agent.setAutoSnapshot(enabled: true)
        await waitForAutoSnapshotEnabled(on: webView)

        #expect(try await currentDOMAgentPageEpoch(in: webView) == 3)
        #expect(try await currentDOMAgentDocumentScopeID(in: webView) == 5)

        await loadHTML("<html><body><p>second</p></body></html>", in: webView)

        let restoredAfterReload = await waitForCondition(attempts: 100) {
            let status = await autoSnapshotStatus(on: webView)
            let enabled = (status?["snapshotAutoUpdateEnabled"] as? Bool)
                ?? (status?["snapshotAutoUpdateEnabled"] as? NSNumber)?.boolValue
                ?? false
            let maxDepth = (status?["snapshotAutoUpdateMaxDepth"] as? Int)
                ?? (status?["snapshotAutoUpdateMaxDepth"] as? NSNumber)?.intValue
            let debounce = (status?["snapshotAutoUpdateDebounce"] as? Int)
                ?? (status?["snapshotAutoUpdateDebounce"] as? NSNumber)?.intValue
            let pageEpoch = try? await currentDOMAgentPageEpoch(in: webView)
            let documentScopeID = try? await currentDOMAgentDocumentScopeID(in: webView)
            return enabled && maxDepth == 6 && debounce == 180 && pageEpoch == 3 && documentScopeID == 5
        }

        #expect(restoredAfterReload == true)
    }

    @Test
    func preparingDocumentScopeWhileAttachedRefreshesBootstrapBeforeNextNavigation() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 4, subtreeDepth: 2, autoUpdateDebounce: 0.2))
        let (webView, _) = makeTestWebView()

        _ = await session.attach(to: webView)
        await loadHTML("<html><body><p>first</p></body></html>", in: webView)
        await session.setAutoSnapshot(enabled: true)
        await waitForAutoSnapshotEnabled(on: webView)

        session.prepareDocumentScopeID(2)

        let appliedToCurrentPage = await waitForCondition {
            (try? await currentDOMAgentDocumentScopeID(in: webView)) == 2
        }
        #expect(appliedToCurrentPage == true)

        await loadHTML("<html><body><p>second</p></body></html>", in: webView)

        let restoredOnNextNavigation = await waitForCondition {
            (try? await currentDOMAgentDocumentScopeID(in: webView)) == 2
        }
        #expect(restoredOnNextNavigation == true)
    }

    @Test
    func updateConfigurationWhileAutoSnapshotEnabledEventuallyReconfiguresAgent() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 4, subtreeDepth: 2, autoUpdateDebounce: 0.2))
        let (webView, _) = makeTestWebView()

        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)
        _ = await session.attach(to: webView)
        await session.setAutoSnapshot(enabled: true)
        await waitForAutoSnapshotEnabled(on: webView)

        await session.updateConfiguration(.init(snapshotDepth: 9, subtreeDepth: 2, autoUpdateDebounce: 0.12))
        await waitForAutoSnapshotConfiguration(on: webView, maxDepth: 9, debounce: 120)

        let status = await autoSnapshotStatus(on: webView)
        let maxDepth = (status?["snapshotAutoUpdateMaxDepth"] as? Int)
            ?? (status?["snapshotAutoUpdateMaxDepth"] as? NSNumber)?.intValue
        let debounce = (status?["snapshotAutoUpdateDebounce"] as? Int)
            ?? (status?["snapshotAutoUpdateDebounce"] as? NSNumber)?.intValue

        #expect(maxDepth == 9)
        #expect(debounce == 120)
    }

    @Test
    func autoSnapshotDebounceHasMinimumClamp() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 4, subtreeDepth: 2, autoUpdateDebounce: 0.01))
        let (webView, _) = makeTestWebView()

        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)
        _ = await session.attach(to: webView)
        await session.setAutoSnapshot(enabled: true)
        await waitForAutoSnapshotEnabled(on: webView)

        let status = await autoSnapshotStatus(on: webView)
        let debounce = (status?["snapshotAutoUpdateDebounce"] as? Int)
            ?? (status?["snapshotAutoUpdateDebounce"] as? NSNumber)?.intValue

        #expect(debounce == 50)
    }

    @Test
    func removeNodeSupportsUndoAndRedo() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 5, subtreeDepth: 3))
        let (webView, _) = makeTestWebView()
        let html = """
        <html>
            <body>
                <div id="container">
                    <div id="target">Target</div>
                </div>
            </body>
        </html>
        """

        _ = await session.attach(to: webView)
        await loadHTML(html, in: webView)
        let snapshot = try await session.captureSnapshot(maxDepth: 5)
        guard let nodeId = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "target") else {
            Issue.record("target nodeId was not found in snapshot")
            return
        }

        let removeResult = await session.removeNodeWithUndo(target: .local(UInt64(nodeId)))
        guard case let .applied(undoToken) = removeResult else {
            Issue.record("removeNodeWithUndo should return a valid token")
            return
        }
        #expect(await domNodeExists(withID: "target", in: webView) == false)

        let restored = await session.undoRemoveNode(undoToken: undoToken)
        #expect(matchesApplied(restored) == true)
        #expect(await domNodeExists(withID: "target", in: webView) == true)

        let removedAgain = await session.redoRemoveNode(undoToken: undoToken)
        #expect(matchesApplied(removedAgain) == true)
        #expect(await domNodeExists(withID: "target", in: webView) == false)
    }

    @Test
    func removeNodeWithUndoEncodesLocalTargetsWithExplicitKind() {
        let agent = DOMPageAgent(configuration: .init(snapshotDepth: 5, subtreeDepth: 3))

        let argument = agent.testJavaScriptRemovalTargetArgument(for: .local(42)) as? NSDictionary

        #expect(argument?["kind"] as? String == "local")
        #expect((argument?["value"] as? NSNumber)?.intValue == 42)
    }

    @Test
    func removeNodeWithUndoClearsCachedHandlesForLocalAndBackendIDs() async throws {
        let registry = WIUserContentControllerStateRegistry.shared
        let (webView, controller) = makeTestWebView()
        let agent = DOMPageAgent(
            configuration: .init(snapshotDepth: 5, subtreeDepth: 3),
            controllerStateRegistry: registry
        )
        defer {
            registry.clearState(for: controller)
        }

        agent.attachPageWebView(webView)
        await loadHTML(
            """
            <html>
                <body>
                    <div id="target">Target</div>
                </body>
            </html>
            """,
            in: webView
        )
        await agent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 0)

        let snapshot = try await agent.captureSnapshot(maxDepth: 5)
        let node = try #require(
            findNodeDescriptor(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "target")
        )
        let localID = try #require(node.localID)
        let backendNodeID = localID + 10_000
        #expect(localID != backendNodeID)

        let handleCache = try #require(extractHandleCache(from: agent))
        handleCache.store(handle: NSObject(), for: localID)
        handleCache.store(handle: NSObject(), for: backendNodeID)
        #expect(handleCache.handle(for: localID) != nil)
        #expect(handleCache.handle(for: backendNodeID) != nil)

        let removeResult = await agent.removeNodeWithUndo(target: .local(UInt64(localID)))
        guard case let .applied(undoToken) = removeResult else {
            Issue.record("removeNodeWithUndo should succeed for cached-handle invalidation test")
            return
        }

        #expect(handleCache.handle(for: localID) == nil)
        #expect(handleCache.handle(for: backendNodeID) == nil)
        #expect(matchesApplied(await agent.undoRemoveNode(undoToken: undoToken)) == true)
    }

    @Test
    func removeNodeDoesNotDependOnHandleMutationAPI() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 5, subtreeDepth: 3))
        let (webView, _) = makeTestWebView()
        let html = """
        <html>
            <body>
                <div id="target">Target</div>
            </body>
        </html>
        """

        _ = await session.attach(to: webView)
        await loadHTML(html, in: webView)
        let snapshot = try await session.captureSnapshot(maxDepth: 5)
        guard let nodeId = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "target") else {
            Issue.record("target nodeId was not found in snapshot")
            return
        }

        let didDisableHandleAPI = try await webView.callAsyncJavaScriptCompat(
            """
            return (function() {
                if (!window.webInspectorDOM) {
                    return false;
                }
                try {
                    window.webInspectorDOM.createNodeHandle = undefined;
                } catch (_) {}
                try {
                    window.webInspectorDOM.removeNodeHandle = undefined;
                } catch (_) {}
                try {
                    window.webInspectorDOM.removeNodeHandleWithUndo = undefined;
                } catch (_) {}
                return typeof window.webInspectorDOM.createNodeHandle !== "function";
            })();
            """,
            arguments: [:],
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )

        let removeResult = await session.removeNode(target: .local(UInt64(nodeId)))

        #expect(matchesApplied(removeResult) == true)
        #expect(await domNodeExists(withID: "target", in: webView) == false)
        _ = didDisableHandleAPI
    }

    private func makeTestWebView() -> (WKWebView, RecordingUserContentController) {
        let controller = RecordingUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController = controller
        let webView = WKWebView(frame: .zero, configuration: configuration)
        return (webView, controller)
    }

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func waitForAutoSnapshotEnabled(on webView: WKWebView) async {
        for _ in 0..<100 {
            let raw = try? await webView.evaluateJavaScript(
                "(() => Boolean(window.webInspectorDOM?.debugStatus?.().snapshotAutoUpdateEnabled))();",
                in: nil,
                contentWorld: WISPIContentWorldProvider.bridgeWorld()
            )
            let enabled = (raw as? Bool) ?? (raw as? NSNumber)?.boolValue ?? false
            if enabled {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func waitForAutoSnapshotConfiguration(
        on webView: WKWebView,
        maxDepth: Int,
        debounce: Int
    ) async {
        for _ in 0..<100 {
            let status = await autoSnapshotStatus(on: webView)
            let currentDepth = (status?["snapshotAutoUpdateMaxDepth"] as? Int)
                ?? (status?["snapshotAutoUpdateMaxDepth"] as? NSNumber)?.intValue
            let currentDebounce = (status?["snapshotAutoUpdateDebounce"] as? Int)
                ?? (status?["snapshotAutoUpdateDebounce"] as? NSNumber)?.intValue
            if currentDepth == maxDepth, currentDebounce == debounce {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func autoSnapshotStatus(on webView: WKWebView) async -> [String: Any]? {
        let rawStatus = try? await webView.evaluateJavaScript(
            "(() => window.webInspectorDOM?.debugStatus?.() ?? null)();",
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        return rawStatus as? [String: Any]
    }

    private func findNodeId(
        inSnapshotJSON snapshotJSON: String,
        attributeName: String,
        attributeValue: String
    ) -> Int? {
        guard
            let data = snapshotJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let root = object["root"] as? [String: Any]
        else {
            return nil
        }
        return findNodeDescriptor(inNode: root, attributeName: attributeName, attributeValue: attributeValue)?.localID
    }

    private func findNodeDescriptor(
        inSnapshotJSON snapshotJSON: String,
        attributeName: String,
        attributeValue: String
    ) -> (localID: Int?, backendNodeID: Int?)? {
        guard
            let data = snapshotJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let root = object["root"] as? [String: Any]
        else {
            return nil
        }
        return findNodeDescriptor(inNode: root, attributeName: attributeName, attributeValue: attributeValue)
    }

    private func findNodeId(
        inNode node: [String: Any],
        attributeName: String,
        attributeValue: String
    ) -> Int? {
        findNodeDescriptor(inNode: node, attributeName: attributeName, attributeValue: attributeValue)?.localID
    }

    private func findNodeDescriptor(
        inNode node: [String: Any],
        attributeName: String,
        attributeValue: String
    ) -> (localID: Int?, backendNodeID: Int?)? {
        if let attributes = node["attributes"] as? [String] {
            var index = 0
            while index + 1 < attributes.count {
                let currentName = attributes[index]
                let currentValue = attributes[index + 1]
                if currentName == attributeName, currentValue == attributeValue {
                    let localID =
                        (node["localId"] as? Int)
                        ?? (node["localId"] as? NSNumber)?.intValue
                        ?? (node["nodeId"] as? Int)
                        ?? (node["nodeId"] as? NSNumber)?.intValue
                    let backendNodeID =
                        (node["backendNodeId"] as? Int)
                        ?? (node["backendNodeId"] as? NSNumber)?.intValue
                    return (localID, backendNodeID)
                }
                index += 2
            }
        }

        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                if let descriptor = findNodeDescriptor(
                    inNode: child,
                    attributeName: attributeName,
                    attributeValue: attributeValue
                ) {
                    return descriptor
                }
            }
        }
        return nil
    }

    private func domNodeExists(withID id: String, in webView: WKWebView) async -> Bool {
        let rawValue = try? await webView.callAsyncJavaScriptCompat(
            "return document.getElementById(identifier) !== null;",
            arguments: ["identifier": id],
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        return (rawValue as? Bool) ?? (rawValue as? NSNumber)?.boolValue ?? false
    }

    private func domAttributeValue(
        elementID: String,
        attributeName: String,
        in webView: WKWebView
    ) async -> String? {
        let rawValue = try? await webView.callAsyncJavaScriptCompat(
            "return document.getElementById(identifier)?.getAttribute(attributeName) ?? null;",
            arguments: [
                "identifier": elementID,
                "attributeName": attributeName,
            ],
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        if rawValue is NSNull {
            return nil
        }
        return rawValue as? String
    }
}

private func matchesApplied(_ result: DOMMutationExecutionResult<Void>) -> Bool {
    if case .applied = result {
        return true
    }
    return false
}

private func extractHandleCache(from agent: DOMPageAgent) -> WIJSHandleCache? {
    Mirror(reflecting: agent).descendant("handleCache") as? WIJSHandleCache
}

private func extractPageEpoch(from agent: DOMPageAgent) -> Int? {
    Mirror(reflecting: agent).descendant("pageEpoch") as? Int
}

private func extractDocumentScopeID(from agent: DOMPageAgent) -> UInt64? {
    Mirror(reflecting: agent).descendant("documentScopeID") as? UInt64
}

@MainActor
private func currentDOMAgentPageEpoch(in webView: WKWebView) async throws -> Int? {
    let rawValue = try await webView.evaluateJavaScript(
        "(() => window.webInspectorDOM?.debugStatus?.().pageEpoch ?? null)();",
        in: nil,
        contentWorld: WISPIContentWorldProvider.bridgeWorld()
    )
    if rawValue is NSNull {
        return nil
    }
    if let value = rawValue as? Int {
        return value
    }
    if let value = rawValue as? NSNumber {
        return value.intValue
    }
    return nil
}

@MainActor
private func currentDOMAgentDocumentScopeID(in webView: WKWebView) async throws -> UInt64? {
    let rawValue = try await webView.evaluateJavaScript(
        "(() => window.webInspectorDOM?.debugStatus?.().documentScopeID ?? null)();",
        in: nil,
        contentWorld: WISPIContentWorldProvider.bridgeWorld()
    )
    if rawValue is NSNull {
        return nil
    }
    if let value = rawValue as? UInt64 {
        return value
    }
    if let value = rawValue as? NSNumber {
        return value.uint64Value
    }
    return nil
}

@MainActor
private func waitForCondition(
    attempts: Int = 20,
    intervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
    }
    return await condition()
}

private final class RecordingUserContentController: WKUserContentController {
    private(set) var addedHandlers: [(name: String, world: WKContentWorld)] = []
    private(set) var removedHandlers: [(name: String, world: WKContentWorld)] = []

    override func add(_ scriptMessageHandler: WKScriptMessageHandler, contentWorld: WKContentWorld, name: String) {
        addedHandlers.append((name, contentWorld))
        super.add(scriptMessageHandler, contentWorld: contentWorld, name: name)
    }

    override func removeScriptMessageHandler(forName name: String, contentWorld: WKContentWorld) {
        removedHandlers.append((name, contentWorld))
        super.removeScriptMessageHandler(forName: name, contentWorld: contentWorld)
    }
}

private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Never>?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        continuation?.resume()
        continuation = nil
    }
}
