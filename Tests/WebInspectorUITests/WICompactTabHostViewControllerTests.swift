#if canImport(UIKit)
import Testing
import UIKit
import WebKit
@testable import WebInspectorEngine
@testable import WebInspectorRuntime
@testable import WebInspectorUI

@MainActor
struct WICompactTabHostViewControllerTests {
    @Test
    func syntheticElementTabPrewarmsDetailView() async throws {
        let controller = WIInspectorController()
        seedSelectedDocument(into: controller.dom)
        controller.setTabs([.dom(), .network()])
        let host = WICompactTabHostViewController(
            model: controller,
            renderCache: WIUIKitTabRenderCache()
        )

        host.loadViewIfNeeded()

        #expect(host.displayedTabIdentifiersForTesting == [WITab.domTabID, WITab.elementTabID, WITab.networkTabID])
        let elementViewController = try #require(
            host.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) as? WIDOMDetailViewController
        )
        #expect(elementViewController.isViewLoaded)
        let prewarmed = await waitUntil {
            elementViewController.snapshotApplyCountForTesting > 0
                && elementViewController.collectionView?.numberOfSections == 3
        }
        #expect(prewarmed)
    }

    @Test
    func explicitElementTabPrewarmsDetailView() async throws {
        let controller = WIInspectorController()
        seedSelectedDocument(into: controller.dom)
        controller.setTabs([.dom(), .element(), .network()])
        let host = WICompactTabHostViewController(
            model: controller,
            renderCache: WIUIKitTabRenderCache()
        )

        host.loadViewIfNeeded()

        #expect(host.displayedTabIdentifiersForTesting == [WITab.domTabID, WITab.elementTabID, WITab.networkTabID])
        let elementViewController = try #require(
            host.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) as? WIDOMDetailViewController
        )
        #expect(elementViewController.isViewLoaded)
        let prewarmed = await waitUntil {
            elementViewController.snapshotApplyCountForTesting > 0
                && elementViewController.collectionView?.numberOfSections == 3
        }
        #expect(prewarmed)
    }

    @Test
    func offscreenElementDetailTracksSelectionChangesBeforeTabOpens() async throws {
        let controller = WIInspectorController()
        seedDocumentWithSelectableNodes(into: controller.dom)
        controller.setTabs([.dom(), .network()])
        let host = WICompactTabHostViewController(
            model: controller,
            renderCache: WIUIKitTabRenderCache()
        )

        host.loadViewIfNeeded()

        let elementViewController = try #require(
            host.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) as? WIDOMDetailViewController
        )
        let initialReady = await waitUntil {
            elementViewController.snapshotApplyCountForTesting > 0
                && elementViewController.collectionView?.numberOfItems(inSection: 2) == 1
        }
        #expect(initialReady)

        let initialSnapshotCount = elementViewController.snapshotApplyCountForTesting
        controller.dom.document.applySelectionSnapshot(
            .init(
                localID: 99,
                attributes: [
                    DOMAttribute(nodeId: 99, name: "id", value: "secondary"),
                    DOMAttribute(nodeId: 99, name: "class", value: "updated"),
                    DOMAttribute(nodeId: 99, name: "data-role", value: "hero")
                ],
                path: ["html", "body", "section"],
                selectorPath: "#secondary",
                styleRevision: 0
            )
        )

        let updatedOffscreen = await waitUntil {
            elementViewController.snapshotApplyCountForTesting > initialSnapshotCount
                && elementViewController.collectionView?.numberOfItems(inSection: 2) == 3
                && elementViewController.renderedSelectorTextForTesting() == "#secondary"
                && Set(elementViewController.renderedAttributeNamesForTesting()) == Set(["id", "class", "data-role"])
        }
        #expect(updatedOffscreen)
        let selectedNodeID = try #require(controller.dom.document.selectedNode?.id)
        #expect(elementViewController.renderedAttributeValueForTesting(nodeID: selectedNodeID, name: "class") == "updated")
        #expect(elementViewController.isShowingEmptyStateForTesting == false)
    }

    @Test
    func switchingToElementTabUsesLatestOffscreenSelectionState() async throws {
        let controller = WIInspectorController()
        seedDocumentWithSelectableNodes(into: controller.dom)
        controller.setTabs([.dom(), .network()])
        let host = WICompactTabHostViewController(
            model: controller,
            renderCache: WIUIKitTabRenderCache()
        )

        host.loadViewIfNeeded()

        let elementViewController = try #require(
            host.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) as? WIDOMDetailViewController
        )
        let initialReady = await waitUntil {
            elementViewController.snapshotApplyCountForTesting > 0
                && elementViewController.renderedSelectorTextForTesting() == "#selected"
        }
        #expect(initialReady)

        controller.dom.document.applySelectionSnapshot(
            .init(
                localID: 99,
                attributes: [
                    DOMAttribute(nodeId: 99, name: "id", value: "secondary"),
                    DOMAttribute(nodeId: 99, name: "class", value: "updated"),
                    DOMAttribute(nodeId: 99, name: "data-role", value: "hero")
                ],
                path: ["html", "body", "section"],
                selectorPath: "#secondary",
                styleRevision: 0
            )
        )

        let offscreenUpdated = await waitUntil {
            elementViewController.renderedSelectorTextForTesting() == "#secondary"
                && Set(elementViewController.renderedAttributeNamesForTesting()) == Set(["id", "class", "data-role"])
        }
        #expect(offscreenUpdated)

        let domTab = try selectTab(withIdentifier: WITab.domTabID, in: host)
        let elementTab = try selectTab(withIdentifier: WITab.elementTabID, in: host)
        #expect(host.tabBarController(host, shouldSelectTab: elementTab))
        host.selectedTab = elementTab
        host.tabBarController(host, didSelectTab: elementTab, previousTab: domTab)
        await controller.waitForRuntimeApplyForTesting()

        let selectedNodeID = try #require(controller.dom.document.selectedNode?.id)
        #expect(controller.selectedTab?.identifier == WITab.elementTabID)
        #expect(selectedNodeID.localID == 99)
        #expect(elementViewController.renderedSelectorTextForTesting() == "#secondary")
        #expect(elementViewController.renderedAttributeValueForTesting(nodeID: selectedNodeID, name: "class") == "updated")
        #expect(elementViewController.isShowingEmptyStateForTesting == false)
    }

    @Test
    func containerAppearanceKeepsLifecycleActiveUntilContainerCloses() async {
        let controller = WIInspectorController()
        let webView = makeTestWebView()

        await controller.applyHostState(pageWebView: webView, visibility: .visible)

        var container: WITabViewController? = WITabViewController(
            controller,
            webView: webView,
            tabs: [.dom(), .network()]
        )
        container?.horizontalSizeClassOverrideForTesting = .compact
        container?.loadViewIfNeeded()

        await controller.applyHostState(pageWebView: webView, visibility: .hidden)
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.lifecycle == .active)

        container = nil
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.lifecycle == .suspended)
    }

    @Test
    func domElementDomSwitchKeepsSyntheticElementControllerAndDocumentIdentity() async throws {
        let controller = WIInspectorController()
        let webView = makeTestWebView()

        await controller.applyHostState(pageWebView: webView, visibility: .visible)

        let container = WITabViewController(
            controller,
            webView: webView,
            tabs: [.dom(), .network()]
        )
        container.horizontalSizeClassOverrideForTesting = .compact
        container.loadViewIfNeeded()
        container.beginAppearanceTransition(true, animated: false)
        await controller.applyHostState(pageWebView: webView, visibility: .hidden)
        container.endAppearanceTransition()
        await controller.waitForRuntimeApplyForTesting()

        guard let host = container.activeHostViewControllerForTesting as? WICompactTabHostViewController else {
            Issue.record("Expected compact host")
            return
        }

        seedSelectedDocument(into: controller.dom)
        let initialDocumentIdentity = controller.dom.document.documentIdentity
        let initialSelectedNodeID = try #require(controller.dom.document.selectedNode?.id)
        let elementViewController = try #require(
            host.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) as? WIDOMDetailViewController
        )
        #expect(elementViewController.isViewLoaded)
        let initialRenderReady = await waitUntil {
            elementViewController.snapshotApplyCountForTesting > 0
                && elementViewController.renderedSelectorTextForTesting() == "#selected"
                && elementViewController.renderedAttributeValueForTesting(
                    nodeID: initialSelectedNodeID,
                    name: "id"
                ) == "selected"
        }
        #expect(initialRenderReady)

        let domTab = try selectTab(withIdentifier: WITab.domTabID, in: host)
        let elementTab = try selectTab(withIdentifier: WITab.elementTabID, in: host)

        #expect(host.tabBarController(host, shouldSelectTab: elementTab))
        host.selectedTab = elementTab
        host.tabBarController(host, didSelectTab: elementTab, previousTab: domTab)
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.selectedTab?.identifier == WITab.elementTabID)
        #expect(host.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) === elementViewController)
        #expect(controller.dom.document.documentIdentity == initialDocumentIdentity)
        #expect(controller.dom.document.selectedNode?.id == initialSelectedNodeID)
        #expect(elementViewController.renderedSelectorTextForTesting() == "#selected")
        #expect(elementViewController.renderedAttributeValueForTesting(nodeID: initialSelectedNodeID, name: "id") == "selected")

        #expect(host.tabBarController(host, shouldSelectTab: domTab))
        host.selectedTab = domTab
        host.tabBarController(host, didSelectTab: domTab, previousTab: elementTab)
        await controller.waitForRuntimeApplyForTesting()

        #expect(controller.selectedTab?.identifier == WITab.domTabID)
        #expect(host.rootViewControllerForTesting(tabIdentifier: WITab.elementTabID) === elementViewController)
        #expect(controller.dom.document.documentIdentity == initialDocumentIdentity)
        #expect(controller.dom.document.selectedNode?.id == initialSelectedNodeID)
        #expect(elementViewController.renderedSelectorTextForTesting() == "#selected")
        #expect(elementViewController.renderedAttributeValueForTesting(nodeID: initialSelectedNodeID, name: "id") == "selected")

        container.beginAppearanceTransition(false, animated: false)
        container.endAppearanceTransition()
        await controller.waitForRuntimeApplyForTesting()
    }

    private func makeTestWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func selectTab(
        withIdentifier identifier: String,
        in host: WICompactTabHostViewController
    ) throws -> UITab {
        try #require(host.currentUITabsForTesting.first(where: { $0.identifier == identifier }))
    }

    private func seedSelectedDocument(into inspector: WIDOMInspector) {
        let selectedLocalID: UInt64 = 42
        let attributes = [DOMAttribute(nodeId: Int(selectedLocalID), name: "id", value: "selected")]

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
                            backendNodeID: Int(selectedLocalID),
                            nodeType: 1,
                            nodeName: "DIV",
                            localName: "div",
                            nodeValue: "",
                            attributes: attributes,
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        )
                    ]
                )
            )
        )
        inspector.document.applySelectionSnapshot(
            .init(
                localID: selectedLocalID,
                attributes: attributes,
                path: ["html", "body", "div"],
                selectorPath: "#selected",
                styleRevision: 0
            )
        )
    }

    private func seedDocumentWithSelectableNodes(into inspector: WIDOMInspector) {
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
                    childCount: 2,
                    layoutFlags: [],
                    isRendered: true,
                    children: [
                        DOMGraphNodeDescriptor(
                            localID: 42,
                            backendNodeID: 42,
                            nodeType: 1,
                            nodeName: "DIV",
                            localName: "div",
                            nodeValue: "",
                            attributes: [
                                DOMAttribute(nodeId: 42, name: "id", value: "selected")
                            ],
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        ),
                        DOMGraphNodeDescriptor(
                            localID: 99,
                            backendNodeID: 99,
                            nodeType: 1,
                            nodeName: "SECTION",
                            localName: "section",
                            nodeValue: "",
                            attributes: [
                                DOMAttribute(nodeId: 99, name: "id", value: "secondary"),
                                DOMAttribute(nodeId: 99, name: "class", value: "updated"),
                                DOMAttribute(nodeId: 99, name: "data-role", value: "hero")
                            ],
                            childCount: 0,
                            layoutFlags: [],
                            isRendered: true,
                            children: []
                        )
                    ]
                )
            )
        )
        inspector.document.applySelectionSnapshot(
            .init(
                localID: 42,
                attributes: [
                    DOMAttribute(nodeId: 42, name: "id", value: "selected")
                ],
                path: ["html", "body", "div"],
                selectorPath: "#selected",
                styleRevision: 0
            )
        )
    }

    private func waitUntil(
        attempts: Int = 40,
        intervalNanoseconds: UInt64 = 10_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return false
    }
}
#endif
