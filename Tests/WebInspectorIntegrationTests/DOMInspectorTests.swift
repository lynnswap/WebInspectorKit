import Testing
import WebKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

@MainActor
struct DOMInspectorTests {
    @Test
    func inspectorStartsWithEmptyDocument() {
        let inspector = WIInspectorController().dom

        #expect(inspector.document.rootNode == nil)
        #expect(inspector.document.selectedNode == nil)
        #expect(inspector.document.errorMessage == nil)
    }

    @Test
    @available(*, deprecated, message: "Legacy API compatibility coverage.")
    func deprecatedWIDOMModelDocumentStoreAliasForwardsToDocument() {
        let inspector: WIDOMModel = WIInspectorController().dom

        #expect(ObjectIdentifier(legacyDocumentStore(of: inspector)) == ObjectIdentifier(inspector.document))
    }

    @Test
    func hasPageWebViewReflectsAttachAndDetach() async {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()

        #expect(inspector.hasPageWebView == false)
        await inspector.attach(to: webView)
        #expect(inspector.hasPageWebView == true)

        await inspector.detach()
        #expect(inspector.hasPageWebView == false)
        #expect(inspector.document.selectedNode == nil)
        #expect(inspector.document.rootNode == nil)
    }

    @Test
    func requestSelectionModeToggleUpdatesSelectionStateImmediately() async {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        await loadHTML("<html><body><div id=\"target\">Target</div></body></html>", in: webView)

        #expect(inspector.isSelectingElement == false)

        inspector.requestSelectionModeToggle()
        #expect(inspector.isSelectingElement == true)

        let selectionStarted = await waitForCondition {
            await selectionIsActive(in: webView)
        }
        #expect(selectionStarted == true)

        inspector.requestSelectionModeToggle()
        let selectionEnded = await waitForCondition {
            guard inspector.isSelectingElement == false else {
                return false
            }
            return await selectionIsActive(in: webView) == false
        }
        #expect(selectionEnded == true)
    }

    @Test
    func reloadPageAdvancesPageEpoch() async {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        await loadHTML("<html><body><div id=\"target\">Reload</div></body></html>", in: webView)
        let initialPageEpoch = inspector.transport.currentPageEpoch

        let result = await inspector.reloadPage()

        #expect(result == .applied)
        let epochAdvanced = await waitForCondition {
            inspector.transport.currentPageEpoch == initialPageEpoch + 1
        }
        #expect(epochAdvanced == true)
    }

    @Test
    func reloadDocumentWithoutPageWebViewPublishesRecoverableError() async {
        let inspector = WIInspectorController().dom

        let result = await inspector.reloadDocument()

        #expect(result == .failed)
        #expect(inspector.document.errorMessage == "Web view unavailable.")
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
    func reloadDocumentReturnsAppliedAfterFreshReloadAdvancesDocumentScope() async {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
        var didApplyDocumentRequest = false

        await inspector.attach(to: webView)
        inspector.transport.testConfigurationApplyOverride = { _ in }
        inspector.transport.testPreferredDepthApplyOverride = { _ in }
        inspector.transport.testDocumentRequestApplyOverride = { _, _ in
            didApplyDocumentRequest = true
        }
        inspector.transport.testSetReady(true)
        await inspector.transport.testWaitForBootstrapForTesting()
        didApplyDocumentRequest = false

        let result = await inspector.reloadDocument()

        #expect(result == .applied)
        #expect(didApplyDocumentRequest == true)
    }

    @Test
    func sameLocalIDReprojectionPreservesNodeIdentity() {
        let inspector = WIInspectorController().dom
        inspector.document.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 7)]),
                selectedLocalID: 7
            )
        )

        let initialID = try! #require(inspector.document.selectedNode?.id)

        inspector.document.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [makeNode(localID: 7, attributes: [.init(nodeId: 7, name: "class", value: "updated")])]
                ),
                selectedLocalID: 7
            ),
            isFreshDocument: false
        )

        let reprojectedID = try! #require(inspector.document.selectedNode?.id)
        #expect(reprojectedID == initialID)
    }

    @Test
    func freshDocumentChangesNodeIdentity() {
        let inspector = WIInspectorController().dom
        inspector.document.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 7)]),
                selectedLocalID: 7
            )
        )

        let initialID = try! #require(inspector.document.selectedNode?.id)

        inspector.document.replaceDocument(
            with: .init(
                root: makeNode(localID: 1, children: [makeNode(localID: 7)]),
                selectedLocalID: 7
            ),
            isFreshDocument: true
        )

        let refreshedID = try! #require(inspector.document.selectedNode?.id)
        #expect(refreshedID != initialID)
    }

    @Test
    func successfulAttributeMutationUpdatesPageAndModel() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
        let html = """
        <html>
            <body>
                <div id="target" class="before" title="legacy">Target</div>
            </body>
        </html>
        """

        await inspector.attach(to: webView)
        await loadHTML(html, in: webView)
        _ = await inspector.reloadDocumentPreservingInspectorState()

        let snapshot = try await inspector.session.captureSnapshot(maxDepth: 5)
        guard let targetNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "target") else {
            Issue.record("target node was not found in snapshot")
            return
        }

        inspector.document.applySelectionSnapshot(
            .init(
                localID: UInt64(targetNodeID),
                preview: "<div id=\"target\">",
                attributes: [
                    .init(nodeId: targetNodeID, name: "id", value: "target"),
                    .init(nodeId: targetNodeID, name: "class", value: "before"),
                    .init(nodeId: targetNodeID, name: "title", value: "legacy"),
                ],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        let updateResult = await inspector.updateSelectedAttribute(name: "class", value: "after")
        #expect(updateResult == .applied)

        let classUpdated = await waitForCondition {
            let pageValue = await domAttributeValue(elementID: "target", attributeName: "class", in: webView)
            let modelValue = inspector.document.selectedNode?.attributes.first(where: { $0.name == "class" })?.value
            return pageValue == "after" && modelValue == "after"
        }
        #expect(classUpdated == true)

        let removeResult = await inspector.removeSelectedAttribute(name: "title")
        #expect(removeResult == .applied)

        let titleRemoved = await waitForCondition {
            let pageValue = await domAttributeValue(elementID: "target", attributeName: "title", in: webView)
            let hasTitle = inspector.document.selectedNode?.attributes.contains(where: { $0.name == "title" }) == true
            return pageValue == nil && hasTitle == false
        }
        #expect(titleRemoved == true)
    }

    @Test
    func attributeMutationDoesNotReachPageWhileResyncFails() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
        let html = """
        <html>
            <body>
                <div id="target" class="before">Target</div>
            </body>
        </html>
        """

        await inspector.attach(to: webView)
        await loadHTML(html, in: webView)
        _ = await inspector.reloadDocumentPreservingInspectorState()

        let snapshot = try await inspector.session.captureSnapshot(maxDepth: 5)
        guard let targetNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "target") else {
            Issue.record("target node was not found in snapshot")
            return
        }

        inspector.document.applySelectionSnapshot(
            .init(
                localID: UInt64(targetNodeID),
                preview: "<div id=\"target\">",
                attributes: [
                    .init(nodeId: targetNodeID, name: "id", value: "target"),
                    .init(nodeId: targetNodeID, name: "class", value: "before"),
                ],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )
        inspector.transport.testDocumentScopeSyncOverride = { _ in }
        inspector.transport.testDocumentScopeSyncResultOverride = false
        inspector.transport.testDocumentScopeResyncRetryAttemptsOverride = 1
        inspector.transport.testDocumentScopeResyncRetryDelayNanosecondsOverride = 0
        inspector.transport.testPendingDocumentScopeSyncRetryAttemptsOverride = 1
        inspector.transport.testPendingDocumentScopeSyncRetryDelayNanosecondsOverride = 0
        var setAttributeCallCount = 0
        inspector.session.testSetAttributeInterposer = { _, _, _, _, _, performMutation in
            setAttributeCallCount += 1
            return await performMutation()
        }

        let updateResult = await inspector.updateSelectedAttribute(name: "class", value: "after")

        #expect(updateResult == .ignoredStaleContext)
        #expect(setAttributeCallCount == 0)
        #expect(await domAttributeValue(elementID: "target", attributeName: "class", in: webView) == "before")
        #expect(
            inspector.document.selectedNode?.attributes.first(where: { $0.name == "class" })?.value == "before"
        )
    }

    @Test
    func staleNodeIdentityMutationIsIgnoredAfterFreshReplacement() async {
        let inspector = WIInspectorController().dom
        inspector.document.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [makeNode(localID: 7, attributes: [.init(nodeId: 7, name: "id", value: "target")])]
                ),
                selectedLocalID: 7
            )
        )

        let staleID = try! #require(inspector.document.selectedNode?.id)
        inspector.document.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [makeNode(localID: 7, attributes: [.init(nodeId: 7, name: "id", value: "target")])]
                ),
                selectedLocalID: 7
            ),
            isFreshDocument: true
        )

        let result = await inspector.removeAttribute(nodeID: staleID, name: "id")

        #expect(result == .ignoredStaleContext)
        #expect(inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" }) == true)
    }

    @Test
    func reloadDocumentPreservingInspectorStateIgnoresStaleDocumentScopeChange() async {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
        var didApplyDocumentRequest = false

        await inspector.attach(to: webView)
        inspector.transport.testConfigurationApplyOverride = { _ in }
        inspector.transport.testPreferredDepthApplyOverride = { _ in
            inspector.transport.testAdvanceCurrentDocumentScopeWithoutClearingModel()
        }
        inspector.transport.testDocumentRequestApplyOverride = { _, _ in
            didApplyDocumentRequest = true
        }
        inspector.transport.testSetReady(true)
        await inspector.transport.testWaitForBootstrapForTesting()
        didApplyDocumentRequest = false

        let result = await inspector.reloadDocumentPreservingInspectorState()

        #expect(result == .ignoredStaleContext)
        #expect(didApplyDocumentRequest == false)
    }

    @Test
    func reloadDocumentClearsPendingSelectionOverride() async {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        inspector.transport.testConfigurationApplyOverride = { _ in }
        inspector.transport.testSetReady(true)
        await inspector.transport.testWaitForBootstrapForTesting()

        inspector.transport.setPendingSelectionOverride(localID: 42)

        let result = await inspector.reloadDocument()

        #expect(result == .applied)
        #expect(inspector.transport.testPendingSelectionOverrideLocalID == nil)
    }

    @Test
    func reloadDocumentIgnoresFreshRequestAbortedAfterDocumentScopeSync() async {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        await loadHTML("<html><body><div id=\"target\">Target</div></body></html>", in: webView)
        inspector.transport.testConfigurationApplyOverride = { _ in }
        inspector.transport.testFrontendDispatchOverride = { _ in true }
        inspector.transport.testDocumentScopeSyncOverride = { _ in
            inspector.transport.testSetPhaseIdleForCurrentPage()
        }
        inspector.transport.testSetReady(true)
        await inspector.transport.testWaitForBootstrapForTesting()

        let result = await inspector.reloadDocument()

        #expect(result == .ignoredStaleContext)
    }

    @Test
    func undoSelectionRestoreUsesSelectedNodeLocalID() {
        let inspector = WIInspectorController().dom
        let selectedLocalID: UInt64 = 42
        let selectedBackendNodeID = 77
        inspector.document.replaceDocument(
            with: .init(
                root: DOMGraphNodeDescriptor(
                    localID: 1,
                    backendNodeID: 1,
                    nodeType: 1,
                    nodeName: "HTML",
                    localName: "html",
                    nodeValue: "",
                    attributes: [],
                    childCount: 1,
                    layoutFlags: [],
                    isRendered: true,
                    children: [
                        DOMGraphNodeDescriptor(
                            localID: selectedLocalID,
                            backendNodeID: selectedBackendNodeID,
                            nodeType: 1,
                            nodeName: "DIV",
                            localName: "div",
                            nodeValue: "",
                            attributes: [.init(nodeId: selectedBackendNodeID, name: "id", value: "target")],
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        )
                    ]
                ),
                selectedLocalID: selectedLocalID
            )
        )
        inspector.document.applySelectionSnapshot(
            .init(
                localID: selectedLocalID,
                preview: "<div id=\"target\">",
                attributes: [.init(nodeId: selectedBackendNodeID, name: "id", value: "target")],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        let payload = inspector.testSelectionRestorePayload(for: selectedBackendNodeID)
        inspector.transport.setPendingSelectionOverride(localID: payload?.localID)

        #expect(payload?.localID == selectedLocalID)
        #expect(inspector.transport.testPendingSelectionOverrideLocalID == selectedLocalID)
    }

    @Test
    func deleteSelectionDoesNotPruneModelAfterMutationContextChangesMidFlight() async {
        let inspector = WIInspectorController().dom
        inspector.document.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [makeNode(localID: 7, attributes: [.init(nodeId: 7, name: "id", value: "target")])]
                ),
                selectedLocalID: 7
            )
        )
        inspector.session.testRemoveNodeOverride = { _, _, _ in
            inspector.transport.testAdvanceCurrentDocumentScopeWithoutClearingModel()
            return .applied(())
        }

        let result = await inspector.deleteSelection()

        #expect(result == .applied)
        #expect(inspector.document.selectedNode?.backendNodeID == 7)
        #expect(inspector.document.node(backendNodeID: 7) != nil)
    }

    @Test
    func deleteSelectionRemovesPageNodeAndClearsSelection() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
        let html = """
        <html>
            <body>
                <div id="target">Target</div>
            </body>
        </html>
        """

        await inspector.attach(to: webView)
        await loadHTML(html, in: webView)
        _ = await inspector.reloadDocumentPreservingInspectorState()

        let snapshot = try await inspector.session.captureSnapshot(maxDepth: 5)
        guard let targetNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "target") else {
            Issue.record("target node was not found in snapshot")
            return
        }

        inspector.document.applySelectionSnapshot(
            .init(
                localID: UInt64(targetNodeID),
                preview: "<div id=\"target\">",
                attributes: [.init(nodeId: targetNodeID, name: "id", value: "target")],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        let result = await inspector.deleteSelection()
        #expect(result == .applied)

        let deleted = await waitForCondition {
            let exists = await domNodeExists(withID: "target", in: webView)
            return exists == false && inspector.document.selectedNode == nil
        }
        #expect(deleted == true)
    }

    @Test
    func undoDeleteRestoresPageNodeAndSelection() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
        let undoManager = UndoManager()
        let html = """
        <html>
            <body>
                <div id="target">Target</div>
            </body>
        </html>
        """

        await inspector.attach(to: webView)
        await loadHTML(html, in: webView)
        _ = await inspector.reloadDocumentPreservingInspectorState()

        let snapshot = try await inspector.session.captureSnapshot(maxDepth: 5)
        guard let targetNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "target") else {
            Issue.record("target node was not found in snapshot")
            return
        }

        inspector.document.applySelectionSnapshot(
            .init(
                localID: UInt64(targetNodeID),
                preview: "<div id=\"target\">",
                attributes: [.init(nodeId: targetNodeID, name: "id", value: "target")],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        let deleteResult = await inspector.deleteSelection(undoManager: undoManager)
        #expect(deleteResult == .applied)

        let deleted = await waitForCondition {
            let exists = await domNodeExists(withID: "target", in: webView)
            return exists == false && inspector.document.selectedNode == nil
        }
        #expect(deleted == true)

        undoManager.undo()

        let restored = await waitForCondition {
            let exists = await domNodeExists(withID: "target", in: webView)
            let selectedBackendNodeID = inspector.document.selectedNode?.backendNodeID
            return exists && selectedBackendNodeID == targetNodeID
        }
        #expect(restored == true)
    }

    @Test
    func undoDeleteReloadsDocumentWhenMutationContextChangesAfterRestore() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
        let undoManager = UndoManager()
        let html = """
        <html>
            <body>
                <div id="target">Target</div>
            </body>
        </html>
        """

        await inspector.attach(to: webView)
        await loadHTML(html, in: webView)
        _ = await inspector.reloadDocumentPreservingInspectorState()

        let snapshot = try await inspector.session.captureSnapshot(maxDepth: 5)
        guard let targetNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "target") else {
            Issue.record("target node was not found in snapshot")
            return
        }

        inspector.document.applySelectionSnapshot(
            .init(
                localID: UInt64(targetNodeID),
                preview: "<div id=\"target\">",
                attributes: [.init(nodeId: targetNodeID, name: "id", value: "target")],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        let deleteResult = await inspector.deleteSelection(undoManager: undoManager)
        #expect(deleteResult == .applied)
        let deleted = await waitForCondition {
            let exists = await domNodeExists(withID: "target", in: webView)
            return exists == false && inspector.document.selectedNode == nil
        }
        #expect(deleted == true)

        inspector.session.testUndoRemoveNodeInterposer = { _, _, _, perform in
            let result = await perform()
            inspector.transport.testAdvanceCurrentDocumentScopeWithoutClearingModel()
            return result
        }
        defer {
            inspector.session.testUndoRemoveNodeInterposer = nil
        }

        undoManager.undo()

        let restoredInPage = await waitForCondition {
            await domNodeExists(withID: "target", in: webView)
        }
        #expect(restoredInPage == true)

        let restoredInModel = await waitForCondition {
            modelContainsNode(
                inspector.document.rootNode,
                attributeName: "id",
                attributeValue: "target"
            )
        }
        #expect(restoredInModel == true)
    }

    @Test
    func redoDeleteReloadsDocumentWhenMutationContextChangesAfterRemove() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
        let undoManager = UndoManager()
        let html = """
        <html>
            <body>
                <div id="target">Target</div>
            </body>
        </html>
        """

        await inspector.attach(to: webView)
        await loadHTML(html, in: webView)
        _ = await inspector.reloadDocumentPreservingInspectorState()

        let snapshot = try await inspector.session.captureSnapshot(maxDepth: 5)
        guard let targetNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "target") else {
            Issue.record("target node was not found in snapshot")
            return
        }

        inspector.document.applySelectionSnapshot(
            .init(
                localID: UInt64(targetNodeID),
                preview: "<div id=\"target\">",
                attributes: [.init(nodeId: targetNodeID, name: "id", value: "target")],
                path: ["html", "body", "div"],
                selectorPath: "#target",
                styleRevision: 0
            )
        )

        let deleteResult = await inspector.deleteSelection(undoManager: undoManager)
        #expect(deleteResult == .applied)
        let deleted = await waitForCondition {
            let exists = await domNodeExists(withID: "target", in: webView)
            return exists == false && inspector.document.selectedNode == nil
        }
        #expect(deleted == true)

        undoManager.undo()
        let restored = await waitForCondition {
            let exists = await domNodeExists(withID: "target", in: webView)
            return exists && inspector.document.node(backendNodeID: targetNodeID) != nil
        }
        #expect(restored == true)

        inspector.session.testRedoRemoveNodeInterposer = { _, _, _, _, perform in
            let result = await perform()
            inspector.transport.testAdvanceCurrentDocumentScopeWithoutClearingModel()
            return result
        }
        defer {
            inspector.session.testRedoRemoveNodeInterposer = nil
        }

        undoManager.redo()

        let removedAgain = await waitForCondition {
            let exists = await domNodeExists(withID: "target", in: webView)
            return exists == false && inspector.document.node(backendNodeID: targetNodeID) == nil
        }
        #expect(removedAgain == true)
    }

    @Test
    func staleReloadClearsPendingSelectionOverride() async {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
        await inspector.attach(to: webView)
        var didRequestDocument = false
        inspector.transport.testConfigurationApplyOverride = { _ in }
        inspector.transport.testPreferredDepthApplyOverride = { _ in
            inspector.transport.testAdvanceCurrentDocumentScopeWithoutClearingModel()
        }
        inspector.transport.testDocumentRequestApplyOverride = { _, _ in
            didRequestDocument = true
        }
        inspector.transport.testSetReady(true)
        await inspector.transport.testWaitForBootstrapForTesting()
        didRequestDocument = false

        inspector.transport.setPendingSelectionOverride(localID: 42)

        let result = await inspector.reloadDocumentPreservingInspectorState()

        #expect(result == .ignoredStaleContext)
        #expect(didRequestDocument == false)
        #expect(inspector.transport.testPendingSelectionOverrideLocalID == nil)
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private func waitForCondition(
        maxAttempts: Int = 250,
        intervalNanoseconds: UInt64 = 20_000_000,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<maxAttempts {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return await condition()
    }

    private func domNodeExists(withID id: String, in webView: WKWebView) async -> Bool {
        let rawValue = try? await webView.callAsyncJavaScript(
            "return document.getElementById(identifier) !== null;",
            arguments: ["identifier": id],
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        return (rawValue as? Bool) ?? (rawValue as? NSNumber)?.boolValue ?? false
    }

    private func selectionIsActive(in webView: WKWebView) async -> Bool {
        let rawValue = try? await webView.callAsyncJavaScript(
            "return window.webInspectorDOM.debugStatus().selectionActive;",
            arguments: [:],
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
        let rawValue = try? await webView.callAsyncJavaScript(
            "return document.getElementById(elementID)?.getAttribute(attributeName) ?? null;",
            arguments: [
                "elementID": elementID,
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
        return findNodeId(inNode: root, attributeName: attributeName, attributeValue: attributeValue)
    }

    private func findNodeId(
        inNode node: [String: Any],
        attributeName: String,
        attributeValue: String
    ) -> Int? {
        if let attributes = node["attributes"] as? [String] {
            var index = 0
            while index + 1 < attributes.count {
                if attributes[index] == attributeName, attributes[index + 1] == attributeValue {
                    return node["nodeId"] as? Int
                }
                index += 2
            }
        }

        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                if let nodeID = findNodeId(inNode: child, attributeName: attributeName, attributeValue: attributeValue) {
                    return nodeID
                }
            }
        }
        return nil
    }

    private func modelContainsNode(
        _ node: DOMNodeModel?,
        attributeName: String,
        attributeValue: String
    ) -> Bool {
        guard let node else {
            return false
        }
        if node.attributes.contains(where: { $0.name == attributeName && $0.value == attributeValue }) {
            return true
        }
        return node.children.contains {
            modelContainsNode($0, attributeName: attributeName, attributeValue: attributeValue)
        }
    }

    private func makeNode(
        localID: UInt64,
        attributes: [DOMAttribute] = [],
        children: [DOMGraphNodeDescriptor] = [],
        nodeType: Int = 1,
        nodeName: String = "DIV",
        localName: String = "div",
        nodeValue: String = ""
    ) -> DOMGraphNodeDescriptor {
        DOMGraphNodeDescriptor(
            localID: localID,
            backendNodeID: Int(localID),
            nodeType: nodeType,
            nodeName: nodeName,
            localName: localName,
            nodeValue: nodeValue,
            attributes: attributes,
            childCount: children.count,
            layoutFlags: [],
            isRendered: true,
            children: children
        )
    }
}

@available(*, deprecated, message: "Legacy API compatibility coverage.")
@MainActor
private func legacyDocumentStore(of inspector: WIDOMModel) -> DOMDocumentModel {
    inspector.documentStore
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
