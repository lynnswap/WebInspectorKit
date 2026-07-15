#if canImport(UIKit)
import ObservationBridge
import Testing
import UIKit
@testable import WebInspectorDataKit
import WebInspectorDataKitTesting
import WebInspectorProxyKit
import WebInspectorProxyKitTesting
import WebInspectorTestSupport
@testable import WebInspectorUIDOM
@testable import WebInspectorUIBase

@MainActor
@Suite(.serialized)
struct DOMContainerTests {
    @Test
    func elementViewStartsEmptyWithoutAContextSelection() async throws {
        let fixture = try await DOMContainerFixture()
        let viewController = DOMElementViewController(model: fixture.model)

        viewController.loadViewIfNeeded()

        #expect(viewController.collectionView.numberOfSections == 0)
        #expect(fixture.model.selectedNodeID == nil)
        await fixture.close()
    }

    @Test
    func elementViewKeepsPlaceholderForASelectedNodeWithoutLoadedStyles()
        async throws
    {
        let fixture = try await DOMContainerFixture()
        let viewController = DOMElementViewController(model: fixture.model)
        viewController.loadViewIfNeeded()

        fixture.model.selectNode(
            try fixture.nodeID(named: "body"),
            reveal: .selectOnly
        )

        #expect(await waitUntil {
            viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.numberOfSections == 0
        })
        await fixture.close()
    }

    @Test
    func removingTheSelectedNodeClearsTheSharedPanelSelection()
        async throws
    {
        let fixture = try await DOMContainerFixture()
        let viewController = DOMElementViewController(model: fixture.model)
        viewController.loadViewIfNeeded()
        let bodyID = try fixture.nodeID(named: "body")
        fixture.model.selectNode(bodyID, reveal: .selectOnly)
        #expect(fixture.model.selectedNodeID == bodyID)

        try await fixture.runtime.emitDOMChildNodeRemoved(
            parentID: "document",
            nodeID: "body"
        )

        #expect(await waitUntil {
            fixture.model.selectedNodeID == nil
                && viewController.contentUnavailableConfiguration != nil
                && viewController.collectionView.numberOfSections == 0
        })
        await fixture.close()
    }

    @Test
    func panelElementPickerActivatesAndCancelsThroughTheProductionFeed()
        async throws
    {
        let fixture = try await DOMContainerFixture()
        let observation = withPortableContinuousObservation { _ in
            _ = fixture.model.isPickingElement
        }
        let pickerStates = await observation.values {
            fixture.model.isPickingElement
        }
        defer {
            pickerStates.cancel()
            observation.cancel()
        }

        fixture.model.toggleElementPicker()
        #expect(await pickerStates.waitUntil { $0 } != nil)

        fixture.model.cancelElementPicker()
        #expect(await pickerStates.waitUntil { !$0 } != nil)
        await fixture.close()
    }

    @Test
    func pickerSelectionRevealsTheTreeAndRestoresTheBackendHighlight()
        async throws
    {
        let fixture = try await DOMPickerSelectionFixture.start()
        let viewController = DOMTreeViewController(model: fixture.model)
        viewController.loadViewIfNeeded()
        let treeView = viewController.displayedDOMTreeTextViewForTesting
        treeView.frame = CGRect(x: 0, y: 0, width: 360, height: 480)
        treeView.setRenderingActive(true)
        let initialTreeRevision = try #require(
            fixture.model.nodes.revision
        ).rawValue
        #expect(
            await treeView.waitForRowDocumentAppliedTreeRevisionForTesting(
                initialTreeRevision,
                timeout: .seconds(5)
            )
        )
        let baselineRowDocumentRevision = treeView.rowDocumentRevisionForTesting
        let selectedNodeID = try fixture.nodeID(rawValue: "42")
        let selectionDelivery = try #require(
            treeView.selectionObservationDeliveryForTesting
        )

        fixture.model.toggleElementPicker()
        _ = await fixture.wire.observations.waitForCompletedCommands(
            method: "DOM.setInspectModeEnabled",
            count: 1
        )
        try await fixture.wire.emitTargetEvent(
            targetID: "page-main",
            method: "DOM.inspect",
            parameters: try webInspectorTestJSONObject(#"{"nodeId":42}"#)
        )

        #expect(await waitForObservedCondition(
            deliveries: { [selectionDelivery] },
            sample: {
                fixture.model.selectedNodeID == selectedNodeID
                    && treeView.routedSelectedNodeIDForTesting == selectedNodeID
            }
        ))
        #expect(await treeView.waitForRowDocumentForTesting())
        #expect(
            treeView.rowDocumentRevisionForTesting
                == baselineRowDocumentRevision + 1
        )
        #expect(treeView.documentTextForTesting.contains("<span></span>"))
        #expect(treeView.selectedRowRectsForTesting().count == 1)

        await treeView.waitForPageHighlightTaskForTesting()
        let highlightCommands = fixture.wire.observations.commands.filter {
            $0.method == "DOM.highlightNode"
        }
        #expect(highlightCommands.count == 1)
        #expect(
            try highlightCommands.first?.parameters.decode(
                DOMNodeCommandParameters.self
            ).nodeId == 42
        )

        try await fixture.wire.emitTargetEvent(
            targetID: "page-main",
            method: "DOM.childNodeRemoved",
            parameters: try webInspectorTestJSONObject(
                #"{"parentNodeId":3,"nodeId":42}"#
            )
        )
        #expect(await waitForObservedCondition(
            deliveries: { [selectionDelivery] },
            sample: {
                fixture.model.selectedNodeID == nil
                    && treeView.routedSelectedNodeIDForTesting == nil
            }
        ))
        await treeView.waitForPageHighlightTaskForTesting()
        #expect(
            fixture.wire.observations.commands.filter {
                $0.method == "DOM.hideHighlight"
            }.count == 1
        )
        await fixture.close()
    }

    @Test
    func elementViewCanDisableBackgroundDrawing() async throws {
        guard #available(iOS 26.0, *) else {
            return
        }
        let fixture = try await DOMContainerFixture()
        let viewController = DOMElementViewController(model: fixture.model)
        viewController.traitOverrides.webInspectorDrawsBackground = false

        viewController.loadViewIfNeeded()

        #expect(viewController.view.backgroundColor == .clear)
        #expect(viewController.collectionView.backgroundColor == .clear)
        await fixture.close()
    }

    @Test
    func elementStyleSectionHeaderTextFormatsRuleOriginText() {
        let location = DOMElementStyleSectionHeaderText.SourceLocation(
            sourceURL: "https://styles.example/assets/result-card.css",
            line: 27,
            column: 22_164
        )
        #expect(
            DOMElementStyleSectionHeaderText.displayText(for: location)
                == "result-card.css:28:22165"
        )
        #expect(
            DOMElementStyleSectionHeaderText.fullDisplayText(for: location)
                == "https://styles.example/assets/result-card.css:28:22165"
        )
        #expect(DOMElementStyleSectionHeaderText.displayText(
            for: .init(sourceURL: "styles.css", line: 1)
        ) == "styles.css:2")
        #expect(DOMElementStyleSectionHeaderText.displayText(
            for: .init(sourceURL: "styles.css", line: 0, column: 80)
        ) == "styles.css:1")
        #expect(DOMElementStyleSectionHeaderText.displayText(
            for: .init(sourceURL: "styles.css", line: 0, column: 81)
        ) == "styles.css:1:82")
    }

    @Test
    func elementStylePropertyViewSendsToggleActionWithImmediateFeedback()
        async
    {
        let propertyID = CSSStyleProperty.ID("test-style:0")
        let property = CSSStyleProperty(
            id: propertyID,
            name: "margin",
            value: "0",
            text: "margin: 0;",
            status: .active,
            isEditable: true
        )
        let propertyView = DOMElementStylePropertyView()
        var requestedPropertyID: CSSStyleProperty.ID?
        var requestedEnabled: Bool?
        let acceptedRequest = WebInspectorTestGate()
        propertyView.bind(property: property) { property, enabled in
            requestedPropertyID = property.id
            requestedEnabled = enabled
            acceptedRequest.open()
            return true
        }
        let window = showViewInWindow(propertyView)
        defer { window.isHidden = true }

        propertyView.tapToggleForTesting()

        #expect(propertyView.isToggleOnForTesting == false)
        await acceptedRequest.waiter.wait()
        #expect(requestedPropertyID == propertyID)
        #expect(requestedEnabled == false)

        let rejectedRequest = WebInspectorTestGate()
        propertyView.bind(property: property) { _, _ in
            rejectedRequest.open()
            return false
        }
        propertyView.tapToggleForTesting()
        await rejectedRequest.waiter.wait()
        await Task.yield()
        #expect(propertyView.isToggleOnForTesting)
    }

    @Test
    func elementStylePropertyViewIgnoresNonEditableProperties() {
        let property = CSSStyleProperty(
            id: CSSStyleProperty.ID("test-style:0"),
            name: "margin",
            value: "0",
            text: "margin: 0;",
            status: .active,
            isEditable: false
        )
        let propertyView = DOMElementStylePropertyView()
        var requestCount = 0
        propertyView.bind(property: property) { _, _ in
            requestCount += 1
            return true
        }
        let window = showViewInWindow(propertyView)
        defer { window.isHidden = true }

        #expect(propertyView.isToggleEnabledForTesting == false)
        propertyView.tapToggleForTesting()
        #expect(requestCount == 0)
    }

    @Test
    func elementStylePropertyViewNormalizesMultilinePropertyText() {
        let property = CSSStyleProperty(
            id: CSSStyleProperty.ID("test-style:0"),
            name: "background",
            value: "red",
            text: "background:\n    red;",
            status: .active,
            isEditable: true
        )
        let propertyView = DOMElementStylePropertyView()
        propertyView.bind(property: property) { _, _ in true }
        let window = showViewInWindow(propertyView)
        defer { window.isHidden = true }

        #expect(propertyView.declarationTextForTesting == "background: red;")
        #expect(propertyView.declarationTextForTesting.contains("\n") == false)
    }

    @Test
    func compactContainerInstallsNavigationActionsOnTheSharedPanelModel()
        async throws
    {
        let fixture = try await DOMContainerFixture()
        let treeViewController = DOMTreeViewController(model: fixture.model)
        let navigationController = DOMCompactNavigationController(
            rootViewController: treeViewController,
            model: fixture.model
        )

        navigationController.loadViewIfNeeded()

        #expect(navigationController.viewControllers == [treeViewController])
        #expect(navigationController.domNavigationItemsForTesting != nil)
        #expect(navigationController.keyCommands?.isEmpty == false)
        await fixture.close()
    }

    @Test
    func splitContainerInstallsTreeAndElementColumnsFromOnePanelModel()
        async throws
    {
        let fixture = try await DOMContainerFixture()
        let treeViewController = DOMTreeViewController(model: fixture.model)
        let elementViewController = DOMElementViewController(model: fixture.model)
        let splitViewController = DOMSplitViewController(
            treeViewController: treeViewController,
            elementViewController: elementViewController,
            model: fixture.model
        )

        splitViewController.loadViewIfNeeded()

        #expect(splitViewController.domNavigationItemsForTesting != nil)
        #expect(splitViewController.keyCommands?.isEmpty == false)
        #expect(treeViewController.parent != nil)
        #expect(elementViewController.parent != nil)
        await fixture.close()
    }
}

@MainActor
private final class DOMContainerFixture {
    let runtime: WebInspectorDataKitTestRuntime
    let model: DOMPanelModel

    init() async throws {
        let runtime = try await WebInspectorDataKitTestRuntime.start(
            scenario: .init(
                configuration: .init(enabledFeatures: [.dom]),
                document: .init(children: [
                    .element(id: "body", name: "body")
                ])
            )
        )
        self.runtime = runtime
        model = try await DOMPanelModel.make(
            context: runtime.container.mainContext
        )
    }

    func close() async {
        await model.retire()
        await runtime.close()
    }

    func nodeID(named localName: String) throws -> DOMNode.ID {
        try #require(model.nodes.snapshot?.itemIDs.first { id in
            runtime.container.mainContext.model(for: id)?.localName == localName
        })
    }
}

@MainActor
private final class DOMPickerSelectionFixture {
    enum FixtureError: Error {
        case domFeatureUnavailable
        case domFeatureUpdatesEnded
    }

    let runtime: WebInspectorProxyTestRuntime
    let wire: WebInspectorRawWireDriver
    let container: WebInspectorModelContainer
    let model: DOMPanelModel

    private init(
        runtime: WebInspectorProxyTestRuntime,
        wire: WebInspectorRawWireDriver,
        container: WebInspectorModelContainer,
        model: DOMPanelModel
    ) {
        self.runtime = runtime
        self.wire = wire
        self.container = container
        self.model = model
    }

    static func start() async throws -> DOMPickerSelectionFixture {
        let runtime = try await WebInspectorProxyTestRuntime.start()
        let wire = WebInspectorRawWireDriver(peer: runtime.peer)
        let container = WebInspectorModelContainer(
            configuration: .init(enabledFeatures: [.dom])
        )
        do {
            try await configure(wire)
            await wire.start()
            try await container.attach(owning: runtime.proxy)
            try await waitForDOMReady(in: container)
            let model = try await DOMPanelModel.make(
                context: container.mainContext
            )
            return DOMPickerSelectionFixture(
                runtime: runtime,
                wire: wire,
                container: container,
                model: model
            )
        } catch {
            await container.close()
            await runtime.close()
            await wire.stop()
            throw error
        }
    }

    func close() async {
        await model.retire()
        await container.close()
        await runtime.close()
        await wire.stop()
    }

    func nodeID(rawValue: String) throws -> DOMNode.ID {
        try #require(model.nodes.snapshot?.itemIDs.first {
            $0.canonicalStorage.rawNodeID.rawValue == rawValue
        })
    }

    private static func configure(
        _ wire: WebInspectorRawWireDriver
    ) async throws {
        await wire.respond(to: "Page.enable")
        await wire.respond(to: "Inspector.enable")
        await wire.respond(to: "Inspector.initialized")
        await wire.respond(to: "CSS.enable")
        await wire.respond(
            to: "DOM.getDocument",
            with: try webInspectorDOMDocumentResult(document())
        )
        await wire.respond(to: "DOM.setInspectModeEnabled")
        await wire.respond(to: "DOM.highlightNode")
        await wire.respond(to: "DOM.hideHighlight")
        await wire.respond(to: "CSS.disable")
        await wire.respond(to: "Inspector.disable")
        await wire.respond(to: "Page.disable")
    }

    private static func waitForDOMReady(
        in container: WebInspectorModelContainer
    ) async throws {
        if case .ready = container.dom.state {
            return
        }
        var updates = container.dom.stateUpdates.makeAsyncIterator()
        while let state = await updates.next() {
            switch state {
            case .ready:
                return
            case .unavailable:
                throw FixtureError.domFeatureUnavailable
            case .disabled, .synchronizing, .recovering:
                continue
            }
        }
        throw FixtureError.domFeatureUpdatesEnded
    }

    private static func document() -> DOM.Node {
        DOM.Node(
            id: DOM.Node.ID("1"),
            nodeType: 9,
            nodeName: "#document",
            frameID: FrameID("main-frame"),
            childNodeCount: 1,
            children: [
                DOM.Node(
                    id: DOM.Node.ID("2"),
                    nodeType: 1,
                    nodeName: "BODY",
                    localName: "body",
                    childNodeCount: 1,
                    children: [
                        DOM.Node(
                            id: DOM.Node.ID("3"),
                            nodeType: 1,
                            nodeName: "ARTICLE",
                            localName: "article",
                            childNodeCount: 1,
                            children: [
                                DOM.Node(
                                    id: DOM.Node.ID("42"),
                                    nodeType: 1,
                                    nodeName: "SPAN",
                                    localName: "span",
                                    childNodeCount: 0,
                                    children: []
                                )
                            ]
                        )
                    ]
                )
            ]
        )
    }
}

private struct DOMNodeCommandParameters: Decodable {
    let nodeId: Int
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private func showViewInWindow(_ view: UIView) -> UIWindow {
    let viewController = UIViewController()
    view.translatesAutoresizingMaskIntoConstraints = false
    viewController.view.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: viewController.view.topAnchor),
        view.leadingAnchor.constraint(equalTo: viewController.view.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: viewController.view.trailingAnchor),
        view.bottomAnchor.constraint(equalTo: viewController.view.bottomAnchor),
    ])
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    window.rootViewController = viewController
    window.makeKeyAndVisible()
    window.layoutIfNeeded()
    return window
}
#endif
