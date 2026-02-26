import Testing
import WebKit
@testable import WebInspectorEngine

@MainActor
struct DOMSessionTests {
    @Test
    func detachClearsSelection() {
        let session = DOMSession(configuration: .init(snapshotDepth: 3, subtreeDepth: 2))
        session.selection.nodeId = 42
        session.selection.preview = "<div>"
        session.selection.attributes = [DOMAttribute(nodeId: 42, name: "class", value: "title")]
        session.selection.path = ["html", "body", "div"]
        session.selection.selectorPath = "#title"
        session.selection.matchedStyles = [
            DOMMatchedStyleRule(
                origin: .author,
                selectorText: ".title",
                declarations: [DOMMatchedStyleDeclaration(name: "color", value: "red", important: false)],
                sourceLabel: "inline"
            )
        ]
        session.selection.isLoadingMatchedStyles = true
        session.selection.matchedStylesTruncated = true
        session.selection.blockedStylesheetCount = 2

        session.detach()

        #expect(session.selection.nodeId == nil)
        #expect(session.selection.preview.isEmpty)
        #expect(session.selection.attributes.isEmpty)
        #expect(session.selection.path.isEmpty)
        #expect(session.selection.selectorPath.isEmpty)
        #expect(session.selection.matchedStyles.isEmpty)
        #expect(session.selection.isLoadingMatchedStyles == false)
        #expect(session.selection.matchedStylesTruncated == false)
        #expect(session.selection.blockedStylesheetCount == 0)
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
    func selectionCopyTextWithoutWebViewThrows() async {
        let session = DOMSession(configuration: .init())
        do {
            _ = try await session.selectionCopyText(nodeId: 1, kind: .html)
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
    func matchedStylesWithoutWebViewThrows() async {
        let session = DOMSession(configuration: .init())
        do {
            _ = try await session.matchedStyles(nodeId: 1)
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
    func attachRegistersHandlersAndInstallsUserScripts() {
        let session = DOMSession(configuration: .init())
        let (webView, controller) = makeTestWebView()
        let bridgeWorld = WISPIContentWorldProvider.bridgeWorld()

        session.attach(to: webView)

        let addedHandlerNames = controller.addedHandlers.map(\.name)
        #expect(addedHandlerNames.contains("webInspectorDOMSnapshot"))
        #expect(addedHandlerNames.contains("webInspectorDOMMutations"))
        #expect(controller.addedHandlers.allSatisfy { $0.world == bridgeWorld })
        #expect(controller.userScripts.count == 2)
        #expect(controller.userScripts.contains { $0.source.contains("webInspectorDOM") })
    }

    @Test
    func reattachingSameWebViewKeepsSelectionAndDoesNotRequestReload() {
        let session = DOMSession(configuration: .init())
        let (webView, _) = makeTestWebView()

        let firstAttach = session.attach(to: webView)
        #expect(firstAttach.shouldReload == true)
        #expect(firstAttach.preserveState == false)

        session.selection.nodeId = 42
        session.selection.preview = "<div id=\"selected\">"

        let secondAttach = session.attach(to: webView)

        #expect(secondAttach.shouldReload == false)
        #expect(secondAttach.preserveState == false)
        #expect(session.selection.nodeId == 42)
        #expect(session.selection.preview == "<div id=\"selected\">")
    }

    @Test
    func suspendRemovesHandlersAndClearsWebView() {
        let session = DOMSession(configuration: .init())
        let (webView, controller) = makeTestWebView()
        let bridgeWorld = WISPIContentWorldProvider.bridgeWorld()

        session.attach(to: webView)
        let removedBefore = controller.removedHandlers.count

        session.suspend()

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

        session.attach(to: webView)
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

        session.attach(to: webView)
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
    func attachingSecondSessionToSameControllerDoesNotDuplicateScripts() {
        let firstSession = DOMSession(configuration: .init())
        let secondSession = DOMSession(configuration: .init())
        let (webView, controller) = makeTestWebView()

        firstSession.attach(to: webView)
        let firstScriptCount = controller.userScripts.count
        #expect(firstScriptCount == 2)

        secondSession.attach(to: webView)

        #expect(controller.userScripts.count == firstScriptCount)
    }

    @Test
    func setAutoSnapshotAfterAttachEventuallyConfiguresAgent() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 7, subtreeDepth: 2, autoUpdateDebounce: 0.2))
        let (webView, _) = makeTestWebView()

        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)
        session.attach(to: webView)
        session.setAutoSnapshot(enabled: true)
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
    func setAutoSnapshotBeforeAttachEventuallyConfiguresAgent() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 5, subtreeDepth: 2, autoUpdateDebounce: 0.3))
        let (webView, _) = makeTestWebView()

        session.setAutoSnapshot(enabled: true)
        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)
        session.attach(to: webView)
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
    func updateConfigurationWhileAutoSnapshotEnabledEventuallyReconfiguresAgent() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 4, subtreeDepth: 2, autoUpdateDebounce: 0.2))
        let (webView, _) = makeTestWebView()

        await loadHTML("<html><body><p>hi</p></body></html>", in: webView)
        session.attach(to: webView)
        session.setAutoSnapshot(enabled: true)
        await waitForAutoSnapshotEnabled(on: webView)

        session.updateConfiguration(.init(snapshotDepth: 9, subtreeDepth: 2, autoUpdateDebounce: 0.12))
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
        session.attach(to: webView)
        session.setAutoSnapshot(enabled: true)
        await waitForAutoSnapshotEnabled(on: webView)

        let status = await autoSnapshotStatus(on: webView)
        let debounce = (status?["snapshotAutoUpdateDebounce"] as? Int)
            ?? (status?["snapshotAutoUpdateDebounce"] as? NSNumber)?.intValue

        #expect(debounce == 50)
    }

    @Test
    func matchedStylesReturnsInlineAndMatchedRules() async throws {
        let session = DOMSession(configuration: .init(snapshotDepth: 6, subtreeDepth: 4))
        let (webView, _) = makeTestWebView()
        let html = """
        <html>
            <head>
                <style>
                    .match-target { color: rgb(255, 0, 0); }
                    div { margin: 0; }
                </style>
            </head>
            <body>
                <div id="target" class="match-target" style="display: inline; color: blue !important;">Hello</div>
            </body>
        </html>
        """

        session.attach(to: webView)
        await loadHTML(html, in: webView)
        let snapshot = try await session.captureSnapshot(maxDepth: 6)
        guard let nodeId = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "target") else {
            Issue.record("target nodeId was not found in snapshot")
            return
        }

        let payload = try await session.matchedStyles(nodeId: nodeId)

        #expect(payload.nodeId == nodeId)
        #expect(payload.rules.contains(where: { $0.origin == .inline && $0.selectorText == "element.style" }))
        #expect(payload.rules.contains(where: { $0.selectorText == ".match-target" }))
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

        session.attach(to: webView)
        await loadHTML(html, in: webView)
        let snapshot = try await session.captureSnapshot(maxDepth: 5)
        guard let nodeId = findNodeId(inSnapshotJSON: snapshot, attributeName: "id", attributeValue: "target") else {
            Issue.record("target nodeId was not found in snapshot")
            return
        }

        guard let undoToken = await session.removeNodeWithUndo(nodeId: nodeId) else {
            Issue.record("removeNodeWithUndo should return a valid token")
            return
        }
        #expect(await domNodeExists(withID: "target", in: webView) == false)

        let restored = await session.undoRemoveNode(undoToken: undoToken)
        #expect(restored == true)
        #expect(await domNodeExists(withID: "target", in: webView) == true)

        let removedAgain = await session.redoRemoveNode(undoToken: undoToken)
        #expect(removedAgain == true)
        #expect(await domNodeExists(withID: "target", in: webView) == false)
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
                let currentName = attributes[index]
                let currentValue = attributes[index + 1]
                if currentName == attributeName, currentValue == attributeValue {
                    return node["nodeId"] as? Int
                }
                index += 2
            }
        }

        if let children = node["children"] as? [[String: Any]] {
            for child in children {
                if let nodeId = findNodeId(inNode: child, attributeName: attributeName, attributeValue: attributeValue) {
                    return nodeId
                }
            }
        }
        return nil
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
