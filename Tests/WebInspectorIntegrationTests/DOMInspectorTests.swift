import Foundation
import Testing
import WebKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime

#if canImport(UIKit)
import UIKit
#endif

@MainActor
@Suite(.serialized)
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
    func selectingPageElementUpdatesSelectedNodeWithoutFreshReload() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
#if canImport(UIKit)
        let window = makeUIKitWindow(containing: webView)
        defer {
            tearDownUIKitWindow(window)
        }
#endif

        await inspector.attach(to: webView)
        await inspector.setAutoSnapshotEnabled(true)
        await loadHTML(
            """
            <html>
                <body>
                    <main>
                        <section>
                            <div id="target" data-testid="picked">Target</div>
                        </section>
                    </main>
                </body>
            </html>
            """,
            in: webView
        )
        try await seedDocumentFromPageSnapshot(in: inspector, depth: 6)
        let initialDocumentLoaded = await waitForCondition {
            inspector.document.rootNode != nil
        }
        #expect(initialDocumentLoaded == true)
        let initialDocumentScopeID = inspector.transport.currentDocumentScopeID

        let selectionTask = Task { try await inspector.beginSelectionMode() }
        let selectionStarted = await waitForCondition {
            await selectionIsActive(in: webView)
        }
        #expect(selectionStarted == true)

        let didDispatchSelection = await triggerElementSelection(elementID: "target", in: webView)
        #expect(didDispatchSelection == true)

        let selectionResult = try await selectionTask.value
        #expect(selectionResult.cancelled == false)

        let selectionApplied = await waitForCondition {
            inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "target" }) == true
        }
        #expect(selectionApplied == true)
        #expect(inspector.transport.currentDocumentScopeID == initialDocumentScopeID)
    }

    @Test
    func autoSnapshotMutationsContinueAfterPageElementSelection() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
#if canImport(UIKit)
        let window = makeUIKitWindow(containing: webView)
        defer {
            tearDownUIKitWindow(window)
        }
#endif

        await inspector.attach(to: webView)
        await inspector.setAutoSnapshotEnabled(true)
        await loadHTML(
            """
            <html>
                <body>
                    <main id="feed">
                        <div id="target">Target</div>
                    </main>
                </body>
            </html>
            """,
            in: webView
        )
        try await seedDocumentFromPageSnapshot(in: inspector, depth: 6)
        let initialDocumentLoaded = await waitForCondition {
            inspector.document.rootNode != nil
        }
        #expect(initialDocumentLoaded == true)

        let selectionTask = Task { try await inspector.beginSelectionMode() }
        let selectionStarted = await waitForCondition {
            await selectionIsActive(in: webView)
        }
        #expect(selectionStarted == true)
        #expect(await triggerElementSelection(elementID: "target", in: webView) == true)
        _ = try await selectionTask.value

        let didAppendNode = try await appendElement(
            parentElementID: "feed",
            newElementID: "appended",
            in: webView
        )
        #expect(didAppendNode == true)

        let mutationApplied = await waitForCondition(maxAttempts: 300) {
            self.modelContainsNode(
                inspector.document.rootNode,
                attributeName: "id",
                attributeValue: "appended"
            )
        }
        #expect(mutationApplied == true)
    }

    @Test
    func selectionDepthExpansionDoesNotResetExpandedTreeState() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
#if canImport(UIKit)
        let window = makeUIKitWindow(containing: webView)
        defer {
            tearDownUIKitWindow(window)
        }
#endif

        await inspector.attach(to: webView)
        await inspector.setAutoSnapshotEnabled(true)
        await loadHTML(
            """
            <html>
                <body>
                    <main>
                        <section id="level-1">
                            <section id="level-2">
                                <section id="level-3">
                                    <section id="level-4">
                                        <section id="level-5">
                                            <section id="level-6">
                                                <div id="target-deep">Target</div>
                                            </section>
                                        </section>
                                    </section>
                                </section>
                            </section>
                        </section>
                    </main>
                </body>
            </html>
            """,
            in: webView
        )
        try await seedDocumentFromPageSnapshot(in: inspector, depth: 4)
        let initialDocumentLoaded = await waitForCondition {
            inspector.document.rootNode != nil
        }
        #expect(initialDocumentLoaded == true)
        let initialDocumentScopeID = inspector.transport.currentDocumentScopeID
        let initialSnapshotDepth = inspector.session.configuration.snapshotDepth
        let initialDebugStatus = await domAgentDebugStatus(in: webView)
        let initialPageSnapshotDepth = (initialDebugStatus?["snapshotAutoUpdateMaxDepth"] as? Int)
            ?? (initialDebugStatus?["snapshotAutoUpdateMaxDepth"] as? NSNumber)?.intValue
            ?? initialSnapshotDepth

        let selectionTask = Task { try await inspector.beginSelectionMode() }
        let selectionStarted = await waitForCondition {
            await selectionIsActive(in: webView)
        }
        #expect(selectionStarted == true)
        #expect(await triggerElementSelection(elementID: "target-deep", in: webView) == true)

        let selectionResult = try await selectionTask.value
        #expect(selectionResult.cancelled == false)
        #expect(selectionResult.requiredDepth > initialSnapshotDepth)

        let selectionApplied = await waitForCondition(maxAttempts: 300) {
            inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "target-deep" }) == true
                && self.modelContainsNode(
                    inspector.document.rootNode,
                    attributeName: "id",
                    attributeValue: "target-deep"
                )
        }
        #expect(selectionApplied == true)
        #expect(inspector.transport.currentDocumentScopeID == initialDocumentScopeID)
        #expect(inspector.session.configuration.snapshotDepth == initialSnapshotDepth)
        let currentDebugStatus = await domAgentDebugStatus(in: webView)
        let currentPageSnapshotDepth = (currentDebugStatus?["snapshotAutoUpdateMaxDepth"] as? Int)
            ?? (currentDebugStatus?["snapshotAutoUpdateMaxDepth"] as? NSNumber)?.intValue
            ?? initialSnapshotDepth
        #expect(currentPageSnapshotDepth == initialPageSnapshotDepth)
    }

    @Test
    func selectionIgnoresUnrelatedMutationStormWithoutFreshReset() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
#if canImport(UIKit)
        let window = makeUIKitWindow(containing: webView)
        defer {
            tearDownUIKitWindow(window)
        }
#endif

        await inspector.attach(to: webView)
        await inspector.setAutoSnapshotEnabled(true)
        await loadHTML(
            """
            <html>
                <body>
                    <main>
                        <section id="target-branch">
                            <div id="target-stable">Target</div>
                        </section>
                        <section id="churn-root"></section>
                    </main>
                </body>
            </html>
            """,
            in: webView
        )
        try await seedDocumentFromPageSnapshot(in: inspector, depth: 6)
        let initialDocumentLoaded = await waitForCondition {
            inspector.document.rootNode != nil
        }
        #expect(initialDocumentLoaded == true)

        let initialDocumentScopeID = inspector.transport.currentDocumentScopeID
        let initialDocumentIdentity = inspector.document.documentIdentity

        let selectionTask = Task { try await inspector.beginSelectionMode() }
        let selectionStarted = await waitForCondition {
            await selectionIsActive(in: webView)
        }
        #expect(selectionStarted == true)
        #expect(await triggerElementSelection(elementID: "target-stable", in: webView) == true)
        _ = try await selectionTask.value

        let selectionApplied = await waitForCondition(maxAttempts: 300) {
            inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "target-stable" }) == true
        }
        #expect(selectionApplied == true)
        #expect(inspector.transport.currentDocumentScopeID == initialDocumentScopeID)
        #expect(inspector.document.documentIdentity == initialDocumentIdentity)

        let didAppendStorm = try await appendManyElements(
            parentElementID: "churn-root",
            elementIDPrefix: "churn-item",
            count: 180,
            in: webView
        )
        #expect(didAppendStorm == true)

        let mutationApplied = await waitForCondition(maxAttempts: 400) {
            self.modelContainsNode(
                inspector.document.rootNode,
                attributeName: "id",
                attributeValue: "churn-item-179"
            )
                && inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "target-stable" }) == true
                && inspector.transport.currentDocumentScopeID == initialDocumentScopeID
                && inspector.document.documentIdentity == initialDocumentIdentity
        }
        #expect(mutationApplied == true)
    }

    @Test
    func selectionResolvesAgainstAuthoritativePageSnapshotWhenLocalTreeIsStale() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
#if canImport(UIKit)
        let window = makeUIKitWindow(containing: webView)
        defer {
            tearDownUIKitWindow(window)
        }
#endif

        await inspector.attach(to: webView)
        await loadHTML(
            """
            <html>
                <body>
                    <main id="feed">
                        <article id="first"><span id="first-label">First</span></article>
                        <article id="target"><span id="target-label">Target</span></article>
                    </main>
                </body>
            </html>
            """,
            in: webView
        )
        try await seedDocumentFromPageSnapshot(in: inspector, depth: 6)
        let initialDocumentLoaded = await waitForCondition {
            inspector.document.rootNode != nil
        }
        #expect(initialDocumentLoaded == true)

        let didReorder = try await reorderChildren(
            parentElementID: "feed",
            movingElementID: "target",
            beforeElementID: "first",
            in: webView
        )
        #expect(didReorder == true)

        let selectionTask = Task { try await inspector.beginSelectionMode() }
        let selectionStarted = await waitForCondition {
            await selectionIsActive(in: webView)
        }
        #expect(selectionStarted == true)
        #expect(await triggerElementSelection(elementID: "target", in: webView) == true)

        let selectionResult = try await selectionTask.value
        #expect(selectionResult.cancelled == false)

        let selectionApplied = await waitForCondition(maxAttempts: 300) {
            inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "target" }) == true
        }
        #expect(selectionApplied == true)
    }

    @Test
    func selectionDoesNotTriggerAutoSnapshotRebootstrap() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
#if canImport(UIKit)
        let window = makeUIKitWindow(containing: webView)
        defer {
            tearDownUIKitWindow(window)
        }
#endif

        await inspector.attach(to: webView)
        await inspector.setAutoSnapshotEnabled(true)
        await loadHTML(
            """
            <html>
                <body>
                    <main>
                        <section id="level-1">
                            <section id="level-2">
                                <section id="level-3">
                                    <section id="level-4">
                                        <section id="level-5">
                                            <div id="target">Target</div>
                                        </section>
                                    </section>
                                </section>
                            </section>
                        </section>
                    </main>
                </body>
            </html>
            """,
            in: webView
        )
        try await seedDocumentFromPageSnapshot(in: inspector, depth: 4)
        let initialStatus = await domAgentDebugStatus(in: webView)
        let initialMaxDepth = (initialStatus?["snapshotAutoUpdateMaxDepth"] as? Int)
            ?? (initialStatus?["snapshotAutoUpdateMaxDepth"] as? NSNumber)?.intValue
            ?? 4

        let selectionTask = Task { try await inspector.beginSelectionMode() }
        let selectionStarted = await waitForCondition {
            await selectionIsActive(in: webView)
        }
        #expect(selectionStarted == true)
        #expect(await triggerElementSelection(elementID: "target", in: webView) == true)
        _ = try await selectionTask.value

        let selectionApplied = await waitForCondition(maxAttempts: 300) {
            inspector.document.selectedNode?.attributes.contains(where: { $0.name == "id" && $0.value == "target" }) == true
        }
        #expect(selectionApplied == true)

        let finalStatus = await domAgentDebugStatus(in: webView)
        let finalMaxDepth = (finalStatus?["snapshotAutoUpdateMaxDepth"] as? Int)
            ?? (finalStatus?["snapshotAutoUpdateMaxDepth"] as? NSNumber)?.intValue
            ?? initialMaxDepth
        #expect(finalMaxDepth == initialMaxDepth)
    }

    @Test
    func backForwardNavigationRefreshesDOMTreeToCurrentPage() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
#if canImport(UIKit)
        let window = makeUIKitWindow(containing: webView)
        defer {
            tearDownUIKitWindow(window)
        }
#endif
        let fixture = try makeNavigationFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        await inspector.attach(to: webView)
        await inspector.setAutoSnapshotEnabled(true)
        await loadFileURL(fixture.page1, allowingReadAccessTo: fixture.directory, in: webView)

        let pageOneLoaded = await waitForCondition(maxAttempts: 400) {
            self.modelContainsNode(
                inspector.document.rootNode,
                attributeName: "id",
                attributeValue: "page-one"
            )
        }
        #expect(pageOneLoaded == true)

        #expect(await clickElement(withID: "to-page-two", in: webView) == true)

        let pageTwoLoaded = await waitForCondition(maxAttempts: 400) {
            self.modelContainsNode(
                inspector.document.rootNode,
                attributeName: "id",
                attributeValue: "page-two"
            )
        }
        #expect(pageTwoLoaded == true)

        await goBack(in: webView)

        let returnedToPageOne = await waitForCondition(maxAttempts: 400) {
            self.modelContainsNode(
                inspector.document.rootNode,
                attributeName: "id",
                attributeValue: "page-one"
            )
                && self.modelContainsNode(
                    inspector.document.rootNode,
                    attributeName: "id",
                    attributeValue: "page-two"
                ) == false
        }
        #expect(returnedToPageOne == true)
    }

    @Test
    func goForwardAfterBackRefreshesDOMTreeAgain() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
#if canImport(UIKit)
        let window = makeUIKitWindow(containing: webView)
        defer {
            tearDownUIKitWindow(window)
        }
#endif
        let fixture = try makeNavigationFixture()
        defer {
            try? FileManager.default.removeItem(at: fixture.directory)
        }

        await inspector.attach(to: webView)
        await inspector.setAutoSnapshotEnabled(true)
        await loadFileURL(fixture.page1, allowingReadAccessTo: fixture.directory, in: webView)

        let pageOneLoaded = await waitForCondition(maxAttempts: 400) {
            self.modelContainsNode(
                inspector.document.rootNode,
                attributeName: "id",
                attributeValue: "page-one"
            )
        }
        #expect(pageOneLoaded == true)

        #expect(await clickElement(withID: "to-page-two", in: webView) == true)

        let pageTwoLoaded = await waitForCondition(maxAttempts: 400) {
            self.modelContainsNode(
                inspector.document.rootNode,
                attributeName: "id",
                attributeValue: "page-two"
            )
        }
        #expect(pageTwoLoaded == true)

        await goBack(in: webView)
        let returnedToPageOne = await waitForCondition(maxAttempts: 400) {
            self.modelContainsNode(
                inspector.document.rootNode,
                attributeName: "id",
                attributeValue: "page-one"
            )
        }
        #expect(returnedToPageOne == true)

        await goForward(in: webView)
        let returnedToPageTwo = await waitForCondition(maxAttempts: 400) {
            self.modelContainsNode(
                inspector.document.rootNode,
                attributeName: "id",
                attributeValue: "page-two"
            )
                && self.modelContainsNode(
                    inspector.document.rootNode,
                    attributeName: "id",
                    attributeValue: "page-one"
                ) == false
        }
        #expect(returnedToPageTwo == true)
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
    func increasingSnapshotDepthUpdatesSessionConfigurationWithoutImmediateReload() async {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
        var documentRequests: [(depth: Int, mode: DOMDocumentReloadMode)] = []

        await inspector.attach(to: webView)
        inspector.document.replaceDocument(
            with: .init(
                root: makeNode(localID: 1)
            )
        )
        inspector.transport.testConfigurationApplyOverride = { _ in }
        inspector.transport.testPreferredDepthApplyOverride = { _ in }
        inspector.transport.testDocumentRequestApplyOverride = { depth, mode in
            documentRequests.append((depth, mode))
        }
        inspector.transport.testSetReady(true)
        await inspector.transport.testWaitForBootstrapForTesting()
        documentRequests.removeAll()

        await inspector.updateSnapshotDepth(8)

        #expect(documentRequests.isEmpty)
        #expect(inspector.session.configuration.snapshotDepth == 8)
    }

    @Test
    func initialSnapshotWithDifferentDocumentURLReplacesExistingTree() async {
        let inspector = WIInspectorController().dom
        inspector.document.replaceDocument(
            with: .init(
                root: makeNode(
                    localID: 1,
                    children: [
                        makeNode(
                            localID: 2,
                            attributes: [.init(name: "id", value: "page-one")],
                            nodeName: "BODY",
                            localName: "body"
                        ),
                    ],
                    nodeName: "HTML",
                    localName: "html"
                )
            )
        )
        let initialScopeID = inspector.transport.currentDocumentScopeID

        inspector.transport.handleDOMBundle(
            .init(
                objectEnvelope: [
                    "version": 1,
                    "kind": "snapshot",
                    "reason": "initial",
                    "documentURL": "https://example.com/page-two",
                    "snapshot": [
                        "root": [
                            "nodeId": 10,
                            "nodeType": 1,
                            "nodeName": "HTML",
                            "localName": "html",
                            "attributes": [],
                            "children": [
                                [
                                    "nodeId": 11,
                                    "nodeType": 1,
                                    "nodeName": "BODY",
                                    "localName": "body",
                                    "attributes": ["id", "page-two"],
                                    "children": [],
                                ],
                            ],
                        ],
                    ],
                ],
                pageEpoch: inspector.transport.currentPageEpoch,
                documentScopeID: initialScopeID
            )
        )

        #expect(modelContainsNode(inspector.document.rootNode, attributeName: "id", attributeValue: "page-two") == true)
        #expect(modelContainsNode(inspector.document.rootNode, attributeName: "id", attributeValue: "page-one") == false)
        #expect(inspector.transport.currentDocumentScopeID == initialScopeID)
    }

    @Test
    func reloadDocumentWithoutPageWebViewPublishesRecoverableError() async {
        let inspector = WIInspectorController().dom

        let result = await inspector.reloadDocument()

        #expect(result == .failed)
        #expect(inspector.document.errorMessage == "Web view unavailable.")
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

        let targetNode = try #require(
            try await waitForLiveNode(
                in: inspector,
                attributeName: "id",
                attributeValue: "target"
            )
        )
        inspector.document.applySelectionSnapshot(selectionSnapshot(for: targetNode))

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
    func attachAdoptsNewerPreparedPageContextBeforeAttributeMutation() async throws {
        let inspector = WIInspectorController().dom
        let webView = makeTestWebView()
        let controller = webView.configuration.userContentController
        let registry = WIUserContentControllerStateRegistry.shared
        let seedAgent = DOMPageAgent(
            configuration: .init(),
            controllerStateRegistry: registry
        )
        let html = """
        <html>
            <body>
                <div id="target" class="before">Target</div>
            </body>
        </html>
        """
        defer {
            registry.clearState(for: controller)
        }

        seedAgent.attachPageWebView(webView)
        await loadHTML(html, in: webView)
        await seedAgent.ensureDOMAgentScriptInstalled(on: webView, pageEpoch: 4, documentScopeID: 6)
        let seeded = await waitForCondition {
            seedAgent.testCachedPageEpoch == 4 && seedAgent.testCachedDocumentScopeID == 6
        }
        #expect(seeded == true)

        await inspector.attach(to: webView)

        #expect(inspector.transport.currentPageEpoch == 4)
        #expect(inspector.transport.currentDocumentScopeID == 6)

        let targetNode = try #require(
            try await waitForLiveNode(
                in: inspector,
                attributeName: "id",
                attributeValue: "target"
            )
        )
        inspector.document.applySelectionSnapshot(selectionSnapshot(for: targetNode))

        let updateResult = await inspector.updateSelectedAttribute(name: "class", value: "after")
        #expect(updateResult == .applied)

        let classUpdated = await waitForCondition {
            let pageValue = await domAttributeValue(elementID: "target", attributeName: "class", in: webView)
            let modelValue = inspector.document.selectedNode?.attributes.first(where: { $0.name == "class" })?.value
            return pageValue == "after" && modelValue == "after"
        }
        #expect(classUpdated == true)
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

        let targetNode = try #require(
            try await waitForLiveNode(
                in: inspector,
                attributeName: "id",
                attributeValue: "target"
            )
        )
        inspector.document.applySelectionSnapshot(selectionSnapshot(for: targetNode))
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
    func reloadDocumentAppliesWhenFreshRequestDoesNotNeedSyntheticDocumentScopeSync() async {
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

        #expect(result == .applied)
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

        let targetNode = try #require(
            try await waitForLiveNode(
                in: inspector,
                attributeName: "id",
                attributeValue: "target"
            )
        )
        inspector.document.applySelectionSnapshot(selectionSnapshot(for: targetNode))

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

        let targetNode = try #require(
            try await waitForLiveNode(
                in: inspector,
                attributeName: "id",
                attributeValue: "target"
            )
        )
        let targetNodeID = try #require(targetNode.backendNodeID)
        inspector.document.applySelectionSnapshot(selectionSnapshot(for: targetNode))

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

        let targetNode = try #require(
            try await waitForLiveNode(
                in: inspector,
                attributeName: "id",
                attributeValue: "target"
            )
        )
        let targetNodeID = try #require(targetNode.backendNodeID)
        inspector.document.applySelectionSnapshot(selectionSnapshot(for: targetNode))

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

        let targetNode = try #require(
            try await waitForLiveNode(
                in: inspector,
                attributeName: "id",
                attributeValue: "target"
            )
        )
        let targetNodeID = try #require(targetNode.backendNodeID)
        inspector.document.applySelectionSnapshot(selectionSnapshot(for: targetNode))

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

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
            configuration: configuration
        )
    }

    private func loadHTML(_ html: String, in webView: WKWebView) async {
        await loadHTML(html, baseURL: nil, in: webView)
    }

    private func loadHTML(_ html: String, baseURL: URL?, in webView: WKWebView) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    private func loadFileURL(
        _ fileURL: URL,
        allowingReadAccessTo readAccessURL: URL,
        in webView: WKWebView
    ) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            webView.loadFileURL(fileURL, allowingReadAccessTo: readAccessURL)
        }
    }

    private func goBack(in webView: WKWebView) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            webView.goBack()
        }
    }

    private func goForward(in webView: WKWebView) async {
        let navigationDelegate = NavigationDelegate()
        webView.navigationDelegate = navigationDelegate

        await withCheckedContinuation { continuation in
            navigationDelegate.continuation = continuation
            webView.goForward()
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

    private func domAgentDebugStatus(in webView: WKWebView) async -> [String: Any]? {
        let rawValue = try? await webView.callAsyncJavaScript(
            "return window.webInspectorDOM.debugStatus();",
            arguments: [:],
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        if let dictionary = rawValue as? [String: Any] {
            return dictionary
        }
        if let dictionary = rawValue as? NSDictionary {
            return dictionary as? [String: Any]
        }
        return nil
    }

    private func seedDocumentFromPageSnapshot(
        in inspector: WIDOMInspector,
        depth: Int
    ) async throws {
        let payload = try await inspector.session.captureSnapshotPayload(
            maxDepth: depth,
            initialModeOwnership: .consumePendingInitialMode
        )
        let snapshot = try #require(DOMPayloadNormalizer().normalizeSnapshot(payload))
        inspector.document.replaceDocument(with: snapshot, isFreshDocument: true)
    }

    private func clickElement(withID elementID: String, in webView: WKWebView) async -> Bool {
        let rawValue = try? await webView.callAsyncJavaScript(
            """
            return (function(elementID) {
                const element = document.getElementById(elementID);
                if (!element) {
                    return false;
                }
                element.click();
                return true;
            })(elementID);
            """,
            arguments: ["elementID": elementID],
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        return (rawValue as? Bool) ?? (rawValue as? NSNumber)?.boolValue ?? false
    }

    private func triggerElementSelection(elementID: String, in webView: WKWebView) async -> Bool {
        let rawValue = try? await webView.callAsyncJavaScript(
            """
            return (function(elementID, shieldAttribute) {
                const target = document.getElementById(elementID);
                const shield = document.querySelector(`[${shieldAttribute}]`);
                if (!target || !shield) {
                    return false;
                }
                const rect = target.getBoundingClientRect();
                const clientX = rect.left + Math.max(1, Math.min(rect.width, 20)) / 2;
                const clientY = rect.top + Math.max(1, Math.min(rect.height, 20)) / 2;
                const move = new MouseEvent("mousemove", { bubbles: true, cancelable: true, clientX, clientY, view: window });
                const down = new MouseEvent("mousedown", { bubbles: true, cancelable: true, clientX, clientY, view: window });
                const up = new MouseEvent("mouseup", { bubbles: true, cancelable: true, clientX, clientY, view: window });
                shield.dispatchEvent(move);
                shield.dispatchEvent(down);
                shield.dispatchEvent(up);
                return true;
            })(elementID, shieldAttribute);
            """,
            arguments: [
                "elementID": elementID,
                "shieldAttribute": "data-web-inspector-selection-shield",
            ],
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        return (rawValue as? Bool) ?? (rawValue as? NSNumber)?.boolValue ?? false
    }

    private func appendElement(
        parentElementID: String,
        newElementID: String,
        in webView: WKWebView
    ) async throws -> Bool {
        let rawValue = try await webView.callAsyncJavaScript(
            """
            return (function(parentElementID, newElementID) {
                const parent = document.getElementById(parentElementID);
                if (!parent) {
                    return false;
                }
                const child = document.createElement("div");
                child.id = newElementID;
                child.textContent = "Appended";
                parent.appendChild(child);
                return true;
            })(parentElementID, newElementID);
            """,
            arguments: [
                "parentElementID": parentElementID,
                "newElementID": newElementID,
            ],
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        return (rawValue as? Bool) ?? (rawValue as? NSNumber)?.boolValue ?? false
    }

    private func appendManyElements(
        parentElementID: String,
        elementIDPrefix: String,
        count: Int,
        in webView: WKWebView
    ) async throws -> Bool {
        let rawValue = try await webView.callAsyncJavaScript(
            """
            return (function(parentElementID, elementIDPrefix, count) {
                const parent = document.getElementById(parentElementID);
                if (!parent) {
                    return false;
                }
                for (let index = 0; index < count; index += 1) {
                    const child = document.createElement("div");
                    child.id = `${elementIDPrefix}-${index}`;
                    child.textContent = `Item ${index}`;
                    parent.appendChild(child);
                }
                return true;
            })(parentElementID, elementIDPrefix, count);
            """,
            arguments: [
                "parentElementID": parentElementID,
                "elementIDPrefix": elementIDPrefix,
                "count": count,
            ],
            in: nil,
            contentWorld: WISPIContentWorldProvider.bridgeWorld()
        )
        return (rawValue as? Bool) ?? (rawValue as? NSNumber)?.boolValue ?? false
    }

    private func reorderChildren(
        parentElementID: String,
        movingElementID: String,
        beforeElementID: String,
        in webView: WKWebView
    ) async throws -> Bool {
        let rawValue = try await webView.callAsyncJavaScript(
            """
            return (function(parentElementID, movingElementID, beforeElementID) {
                const parent = document.getElementById(parentElementID);
                const moving = document.getElementById(movingElementID);
                const before = document.getElementById(beforeElementID);
                if (!parent || !moving || !before || moving.parentElement !== parent || before.parentElement !== parent) {
                    return false;
                }
                parent.insertBefore(moving, before);
                return true;
            })(parentElementID, movingElementID, beforeElementID);
            """,
            arguments: [
                "parentElementID": parentElementID,
                "movingElementID": movingElementID,
                "beforeElementID": beforeElementID,
            ],
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

    private func waitForLiveNode(
        in inspector: WIDOMInspector,
        attributeName: String,
        attributeValue: String,
        maxAttempts: Int = 250
    ) async throws -> DOMNodeModel? {
        await inspector.transport.testWaitForReconcileForTesting()

        if let matchedNode = await resolveLiveNode(
            in: inspector,
            attributeName: attributeName,
            attributeValue: attributeValue,
            maxAttempts: maxAttempts
        ) {
            return matchedNode
        }

        try await seedDocumentFromPageSnapshot(in: inspector, depth: 5)
        await inspector.transport.testWaitForReconcileForTesting()

        return await resolveLiveNode(
            in: inspector,
            attributeName: attributeName,
            attributeValue: attributeValue,
            maxAttempts: maxAttempts
        )
    }

    private func resolveLiveNode(
        in inspector: WIDOMInspector,
        attributeName: String,
        attributeValue: String,
        maxAttempts: Int
    ) async -> DOMNodeModel? {
        var matchedNode: DOMNodeModel?
        let didResolve = await waitForCondition(maxAttempts: maxAttempts) {
            await inspector.transport.testWaitForReconcileForTesting()
            guard let node = findLiveNode(
                in: inspector.document.rootNode,
                attributeName: attributeName,
                attributeValue: attributeValue
            ) else {
                return false
            }
            matchedNode = node
            return true
        }
        return didResolve ? matchedNode : nil
    }

    private func findLiveNode(
        in node: DOMNodeModel?,
        attributeName: String,
        attributeValue: String
    ) -> DOMNodeModel? {
        guard let node else {
            return nil
        }
        if node.attributes.contains(where: { $0.name == attributeName && $0.value == attributeValue }) {
            return node
        }
        for child in node.children {
            if let matchedNode = findLiveNode(
                in: child,
                attributeName: attributeName,
                attributeValue: attributeValue
            ) {
                return matchedNode
            }
        }
        return nil
    }

    private func selectionSnapshot(for node: DOMNodeModel) -> DOMSelectionSnapshotPayload {
        .init(
            localID: node.localID,
            backendNodeID: node.backendNodeID,
            preview: selectionPreview(for: node),
            attributes: selectionAttributes(for: node),
            path: selectionPath(for: node),
            selectorPath: selectionSelectorPath(for: node),
            styleRevision: node.styleRevision
        )
    }

    private func selectionAttributes(for node: DOMNodeModel) -> [DOMAttribute] {
        node.attributes.map {
            .init(
                nodeId: $0.nodeId ?? node.backendNodeID,
                name: $0.name,
                value: $0.value
            )
        }
    }

    private func selectionPreview(for node: DOMNodeModel) -> String {
        if !node.preview.isEmpty {
            return node.preview
        }
        let tagName = selectionTagName(for: node)
        if let id = node.attributes.first(where: { $0.name == "id" })?.value,
           !id.isEmpty {
            return "<\(tagName) id=\"\(id)\">"
        }
        if let className = node.attributes.first(where: { $0.name == "class" })?.value,
           !className.isEmpty {
            return "<\(tagName) class=\"\(className)\">"
        }
        return "<\(tagName)>"
    }

    private func selectionPath(for node: DOMNodeModel) -> [String] {
        if !node.path.isEmpty {
            return node.path
        }

        var labels: [String] = []
        var current: DOMNodeModel? = node
        while let currentNode = current {
            labels.append(selectionTagName(for: currentNode))
            current = currentNode.parent
        }
        return labels.reversed()
    }

    private func selectionSelectorPath(for node: DOMNodeModel) -> String {
        if !node.selectorPath.isEmpty {
            return node.selectorPath
        }
        if let id = node.attributes.first(where: { $0.name == "id" })?.value,
           !id.isEmpty {
            return "#\(id)"
        }
        return selectionTagName(for: node)
    }

    private func selectionTagName(for node: DOMNodeModel) -> String {
        if !node.localName.isEmpty {
            return node.localName
        }
        if !node.nodeName.isEmpty {
            return node.nodeName.lowercased()
        }
        return "node"
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

    private func makeNavigationFixture() throws -> (directory: URL, page1: URL, page2: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DOMInspectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let page1 = directory.appendingPathComponent("page1.html")
        let page2 = directory.appendingPathComponent("page2.html")
        let page1HTML = """
        <!DOCTYPE html>
        <html>
            <body>
                <main id="page-one">Page One</main>
                <a id="to-page-two" href="page2.html">Go</a>
            </body>
        </html>
        """
        let page2HTML = """
        <!DOCTYPE html>
        <html>
            <body>
                <main id="page-two">Page Two</main>
            </body>
        </html>
        """
        try page1HTML.write(to: page1, atomically: true, encoding: .utf8)
        try page2HTML.write(to: page2, atomically: true, encoding: .utf8)
        return (directory, page1, page2)
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

#if canImport(UIKit)
@MainActor
private func makeUIKitWindow(containing webView: WKWebView) -> UIWindow {
    let viewController = UIViewController()
    viewController.loadViewIfNeeded()
    webView.translatesAutoresizingMaskIntoConstraints = false
    viewController.view.addSubview(webView)
    NSLayoutConstraint.activate([
        webView.topAnchor.constraint(equalTo: viewController.view.topAnchor),
        webView.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
        webView.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
        webView.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor),
    ])

    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = viewController
    window.isHidden = false
    return window
}

@MainActor
private func tearDownUIKitWindow(_ window: UIWindow) {
    window.isHidden = true
    window.rootViewController = nil
}
#endif
