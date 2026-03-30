import Testing
import WebKit
import WebInspectorEngine
@testable import WebInspectorUI
@testable import WebInspectorRuntime

@MainActor


struct DOMInspectorTests {
    @Test
    func exposesSelectedItemFromSessionGraphStore() {
        let controller = WIInspectorController()
        let inspector = controller.dom
        #expect(inspector.documentStore.selectedEntry == nil)
        #expect(inspector.documentStore.selectedEntry == nil)
    }

    @Test
    func hasPageWebViewReflectsAttachAndDetach() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let webView = makeTestWebView()

        #expect(inspector.hasPageWebView == false)
        await inspector.attach(to: webView)
        #expect(inspector.hasPageWebView == true)
        #expect(inspector.session.lastPageWebView === webView)

        await inspector.detach()
        #expect(inspector.hasPageWebView == false)
        #expect(inspector.session.lastPageWebView == nil)
        #expect(inspector.documentStore.selectedEntry == nil)
    }

    @Test
    func requestSelectionModeToggleUpdatesSelectionStateImmediately() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        await loadHTML("<html><body><div id=\"target\">Target</div></body></html>", in: webView)

        #expect(inspector.isSelectingElement == false)

        inspector.requestSelectionModeToggle()
        #expect(inspector.isSelectingElement)

        let selectionStarted = await waitForCondition {
            await self.selectionIsActive(in: webView)
        }
        #expect(selectionStarted == true)

        inspector.requestSelectionModeToggle()
        #expect(inspector.isSelectingElement == false)

        let selectionEnded = await waitForCondition {
            await self.selectionIsActive(in: webView) == false
        }
        #expect(selectionEnded == true)
    }

    @Test
    func attachSwitchingPageClearsPendingMutationBundles() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let firstWebView = makeTestWebView()
        let secondWebView = makeTestWebView()

        await inspector.attach(to: firstWebView)
        inspector.enqueueMutationBundle("{\"kind\":\"test\"}", preservingInspectorState: true)
        #expect(inspector.pendingMutationBundleCount == 1)

        await inspector.attach(to: secondWebView)

        #expect(inspector.session.lastPageWebView === secondWebView)
        #expect(inspector.pendingMutationBundleCount == 0)
    }

    @Test
    func suspendAndReattachSameWebViewAdvancesPageEpoch() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        await loadHTML("<html><body><div id=\"target\">Reattach</div></body></html>", in: webView)
        let initialPageEpoch = inspector.frontendStore.currentPageEpoch

        await inspector.suspend()
        await inspector.attach(to: webView)

        #expect(inspector.frontendStore.currentPageEpoch > initialPageEpoch)
        let expectedPageEpoch = inspector.frontendStore.currentPageEpoch
        let pageEpochApplied = await waitForCondition {
            await self.domAgentPageEpoch(in: webView) == expectedPageEpoch
        }
        #expect(pageEpochApplied == true)
    }

    @Test
    func requestReloadPageAdvancesPageEpochAndClearsQueuedMutations() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        await loadHTML("<html><body><div id=\"target\">Reload</div></body></html>", in: webView)
        inspector.enqueueMutationBundle("{\"kind\":\"test\"}", preservingInspectorState: true)
        let initialPageEpoch = inspector.frontendStore.currentPageEpoch

        inspector.requestReloadPage()

        let epochAdvanced = await waitForCondition {
            inspector.frontendStore.currentPageEpoch == initialPageEpoch + 1
        }
        #expect(epochAdvanced == true)
        let mutationBundlesCleared = await waitForCondition {
            inspector.pendingMutationBundleCount == 0
        }
        #expect(mutationBundlesCleared == true)
        let pageEpochApplied = await waitForCondition {
            await self.domAgentPageEpoch(in: webView) == initialPageEpoch + 1
        }
        #expect(pageEpochApplied == true)
    }

    @Test
    func requestReloadPageReappliesAutoSnapshotToFreshJSContext() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        await loadHTML("<html><body><div id=\"target\">Reload</div></body></html>", in: webView)
        await inspector.session.setAutoSnapshot(enabled: true)

        let initialAutoSnapshotEnabled = await waitForCondition {
            await self.autoSnapshotEnabled(in: webView)
        }
        #expect(initialAutoSnapshotEnabled == true)

        inspector.requestReloadPage()

        let pageEpochAdvanced = await waitForCondition {
            let currentPageEpoch = inspector.frontendStore.currentPageEpoch
            guard currentPageEpoch > 0 else {
                return false
            }
            let appliedPageEpoch = await self.domAgentPageEpoch(in: webView)
            return appliedPageEpoch == currentPageEpoch
        }
        #expect(pageEpochAdvanced == true)

        let autoSnapshotReapplied = await waitForCondition {
            await self.autoSnapshotEnabled(in: webView)
        }
        #expect(autoSnapshotReapplied == true)
    }

    @Test
    func requestReloadPageResetsSelectionInteractionState() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        await loadHTML("<html><body><div id=\"target\">Reload</div></body></html>", in: webView)

        inspector.requestSelectionModeToggle()
        let selectionStarted = await waitForCondition {
            await self.selectionIsActive(in: webView)
        }
        #expect(selectionStarted == true)
        #expect(inspector.isSelectingElement == true)

        inspector.requestReloadPage()

        let selectionReset = await waitForCondition {
            guard inspector.isSelectingElement == false else {
                return false
            }
            return await self.selectionIsActive(in: webView) == false
        }
        #expect(selectionReset == true)
    }

    @Test
    func consecutiveReloadRequestsKeepLatestPageEpochApplied() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        await loadHTML("<html><body><div id=\"target\">Reload</div></body></html>", in: webView)

        inspector.requestReloadPage()
        inspector.requestReloadPage()

        let pageEpochAdvanced = await waitForCondition {
            inspector.frontendStore.currentPageEpoch >= 2
        }
        #expect(pageEpochAdvanced == true)
        let expectedPageEpoch = inspector.frontendStore.currentPageEpoch
        let pageEpochApplied = await waitForCondition {
            await self.domAgentPageEpoch(in: webView) == expectedPageEpoch
        }
        #expect(pageEpochApplied == true)
    }

    @Test
    func requestReloadPageWhileSuspendedDoesNotAdvancePageEpoch() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        await loadHTML("<html><body><div id=\"target\">Reload</div></body></html>", in: webView)
        await inspector.suspend()
        let suspendedPageEpoch = inspector.frontendStore.currentPageEpoch

        inspector.requestReloadPage()

        #expect(inspector.frontendStore.currentPageEpoch == suspendedPageEpoch)
    }

    @Test
    func repeatedSuspendDoesNotAdvancePageEpochAgain() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let webView = makeTestWebView()

        await inspector.attach(to: webView)
        await loadHTML("<html><body><div id=\"target\">Suspend</div></body></html>", in: webView)
        await inspector.suspend()
        let suspendedPageEpoch = inspector.frontendStore.currentPageEpoch

        await inspector.suspend()

        #expect(inspector.frontendStore.currentPageEpoch == suspendedPageEpoch)
    }

    @Test
    func reloadInspectorWithoutPageSetsErrorMessage() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        #expect(inspector.documentStore.errorMessage == nil)

        await inspector.reloadDocument()

        #expect(inspector.documentStore.errorMessage == "Web view unavailable.")
    }

    @Test
    func updateSnapshotDepthClampsAndUpdatesConfiguration() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        await inspector.updateSnapshotDepth(0)
        #expect(inspector.session.configuration.snapshotDepth == 1)

        await inspector.updateSnapshotDepth(6)
        #expect(inspector.session.configuration.snapshotDepth == 6)
    }

    @Test
    func updateAndRemoveAttributeMutateSelectionState() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        inspector.documentStore.applySelectionSnapshot(
            .init(
                localID: 7,
                preview: "<div id=\"foo\">",
                attributes: [
                    DOMAttribute(nodeId: 7, name: "class", value: "old"),
                    DOMAttribute(nodeId: 7, name: "id", value: "foo"),
                ],
                path: [],
                selectorPath: "#foo",
                styleRevision: 0
            )
        )

        await inspector.updateSelectedAttribute(name: "class", value: "new")
        #expect(inspector.documentStore.selectedEntry?.attributes.first(where: { $0.name == "class" })?.value == "new")

        await inspector.removeSelectedAttribute(name: "id")
        #expect(inspector.documentStore.selectedEntry?.attributes.contains(where: { $0.name == "id" }) == false)
    }

    @Test
    func updateAndRemoveAttributeSurviveSelectedNodeReprojection() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        inspector.documentStore.replaceDocument(
            with: .init(
                root: .init(
                    localID: 7,
                    backendNodeID: 7,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    nodeValue: "",
                    attributes: [
                        .init(nodeId: 7, name: "class", value: "old"),
                        .init(nodeId: 7, name: "id", value: "foo"),
                    ],
                    childCount: 0,
                    layoutFlags: [],
                    isRendered: true,
                    children: []
                ),
                selectedLocalID: 7
            )
        )

        guard let originalEntry = inspector.documentStore.selectedEntry else {
            Issue.record("Expected initial selection")
            return
        }

        inspector.documentStore.replaceDocument(
            with: .init(
                root: .init(
                    localID: 7,
                    backendNodeID: 7,
                    nodeType: 1,
                    nodeName: "DIV",
                    localName: "div",
                    nodeValue: "",
                    attributes: [
                        .init(nodeId: 7, name: "class", value: "old"),
                        .init(nodeId: 7, name: "id", value: "foo"),
                    ],
                    childCount: 0,
                    layoutFlags: [],
                    isRendered: true,
                    children: []
                ),
                selectedLocalID: 7
            )
        )

        guard let reprojectedEntry = inspector.documentStore.selectedEntry else {
            Issue.record("Expected reprojected selection")
            return
        }
        #expect(reprojectedEntry !== originalEntry)

        await inspector.updateSelectedAttribute(name: "class", value: "new")
        #expect(reprojectedEntry.attributes.first(where: { $0.name == "class" })?.value == "new")

        await inspector.removeSelectedAttribute(name: "id")
        #expect(reprojectedEntry.attributes.contains(where: { $0.name == "id" }) == false)
    }

    @Test
    func detachClearsErrorMessage() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        await inspector.reloadDocument()
        #expect(inspector.documentStore.errorMessage != nil)

        await inspector.detach()

        #expect(inspector.documentStore.errorMessage == nil)
    }

    @Test
    func detachClearsMatchedStylesState() async {
        let controller = WIInspectorController()
        let inspector = controller.dom
        inspector.documentStore.applySelectionSnapshot(
            .init(
                localID: 11,
                preview: "<div class=\"target\">",
                attributes: [],
                path: [],
                selectorPath: ".target",
                styleRevision: 0
            )
        )
        guard let selectedEntry = inspector.documentStore.selectedEntry else {
            Issue.record("Expected selection placeholder before detach")
            return
        }
        inspector.documentStore.applyMatchedStyles(
            .init(
                nodeId: 11,
                rules: [
                    DOMMatchedStyleRule(
                        origin: .author,
                        selectorText: ".target",
                        declarations: [DOMMatchedStyleDeclaration(name: "color", value: "red", important: false)],
                        sourceLabel: "inline"
                    ),
                ],
                truncated: true,
                blockedStylesheetCount: 3
            ),
            for: selectedEntry
        )
        inspector.documentStore.beginMatchedStylesLoading(for: selectedEntry)

        await inspector.detach()

        #expect(inspector.documentStore.selectedEntry == nil)
        #expect(inspector.documentStore.rootEntry == nil)
    }

    @Test
    func deletingTwoNodesThenUndoTwiceRestoresBothNodes() async throws {
        let controller = WIInspectorController()
        let inspector = controller.dom
        let webView = makeTestWebView()
        let undoManager = UndoManager()
        let html = """
        <html>
            <body>
                <div id="first">First</div>
                <div id="second">Second</div>
            </body>
        </html>
        """

        await inspector.attach(to: webView)
        await loadHTML(html, in: webView)

        let snapshot = try await inspector.session.captureSnapshot(maxDepth: 5)
        guard let firstNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "first"),
              let secondNodeID = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "second")
        else {
            Issue.record("target nodes were not found in snapshot")
            return
        }

        await inspector.deleteNode(nodeId: firstNodeID, undoManager: undoManager)
        await inspector.deleteNode(nodeId: secondNodeID, undoManager: undoManager)

        let bothDeleted = await waitForCondition {
            let firstExists = await domNodeExists(withID: "first", in: webView)
            let secondExists = await domNodeExists(withID: "second", in: webView)
            return !firstExists && !secondExists
        }
        #expect(bothDeleted == true)

        undoManager.undo()
        let secondRestored = await waitForCondition {
            await domNodeExists(withID: "second", in: webView)
        }
        #expect(secondRestored == true)
        #expect(await domNodeExists(withID: "first", in: webView) == false)

        undoManager.undo()
        let firstRestored = await waitForCondition {
            await domNodeExists(withID: "first", in: webView)
        }
        #expect(firstRestored == true)
        #expect(await domNodeExists(withID: "second", in: webView) == true)
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

    private func domAgentPageEpoch(in webView: WKWebView) async -> Int? {
        let rawValue = try? await webView.callAsyncJavaScript(
            "return window.webInspectorDOM?.debugStatus?.().pageEpoch ?? null;",
            arguments: [:],
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        if let value = rawValue as? Int {
            return value
        }
        if let value = rawValue as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private func autoSnapshotEnabled(in webView: WKWebView) async -> Bool {
        let rawValue = try? await webView.callAsyncJavaScript(
            "return Boolean(window.webInspectorDOM?.debugStatus?.().snapshotAutoUpdateEnabled);",
            arguments: [:],
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        return (rawValue as? Bool) ?? (rawValue as? NSNumber)?.boolValue ?? false
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
